import Foundation
import Testing
@testable import SwiftPreviewCore

let e2eEnabled = ProcessInfo.processInfo.environment["SWIFTPREVIEW_E2E"] == "1"

/// The package folder (tools/swiftpreview) and the repository root.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repoRoot = packageDir.deletingLastPathComponent().deletingLastPathComponent()

/// A copy of a fixture workspace at a stable path, refreshed for each test
/// (rsync keeps unchanged files' times, so Bazel's cache stays valid).
func workspace(_ fixture: String, as name: String) throws -> String {
  let dest = (SimulatorReaper.cacheDir as NSString).appendingPathComponent("e2e/\(name)")
  try FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
  let src = packageDir.appendingPathComponent("Tests/Fixtures/\(fixture)").path
  let sync = try Shell.run([
    "rsync", "-a", "--checksum", "--delete", "--exclude", "bazel-*", "--exclude", "MODULE.bazel.lock",
    "--exclude", ".swiftpreview", src + "/", dest + "/",
  ])
  guard sync.status == 0 else { throw ToolError("rsync failed: \(sync.stderr)") }
  let module = dest + "/MODULE.bazel"
  let text = try String(contentsOfFile: module, encoding: .utf8)
    .replacingOccurrences(of: "@SWIFT_AGENT_TOOLS@", with: repoRoot.path)
  if text != (try? String(contentsOfFile: module, encoding: .utf8)) { try text.write(toFile: module, atomically: true, encoding: .utf8) }
  return dest
}

/// A running `swiftpreview serve`, read event by event.
final class Serve: @unchecked Sendable {
  let process = Process()
  let stdin = Pipe()
  private let lock = NSLock()
  private var events: [Event] = []
  private var buffer = Data()
  /// Events before `mark` belong to earlier steps; `taken` ones were matched.
  private var mark = 0
  private var taken = Set<Int>()

  init(file: String, session: String, watch: String) throws {
    let binary = ProcessInfo.processInfo.environment["SWIFTPREVIEW_BIN"]
      ?? packageDir.appendingPathComponent(".build/debug/swiftpreview").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      throw ToolError("no swiftpreview at \(binary): run `swift build` first, or set SWIFTPREVIEW_BIN")
    }
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["serve", file, "--session", session, "--watch", watch, "--poll-interval", "100"]
    process.standardInput = stdin
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    out.fileHandleForReading.readabilityHandler = { [weak self] h in
      let data = h.availableData
      guard let self, !data.isEmpty else { return }
      self.lock.lock()
      self.buffer.append(data)
      while let nl = self.buffer.firstIndex(of: 0x0A) {
        let line = self.buffer[self.buffer.startIndex..<nl]
        self.buffer = Data(self.buffer[(nl + 1)...])
        if let e = try? JSONDecoder().decode(Event.self, from: line) { self.events.append(e) }
      }
      self.lock.unlock()
    }
    try process.run()
  }

  /// Starts a step: later lookups see only events from here on.
  func step() {
    lock.lock(); defer { lock.unlock() }
    mark = events.count
    taken = []
  }

  /// The first event of this step, not matched before, that `match` accepts.
  /// Frames are cut into strips off the watch loop, so a status can arrive
  /// before the frame it follows: order within a step is not assumed. An
  /// error fails at once.
  func next(_ what: String, timeout: TimeInterval = 240, _ match: (Event) -> Bool) async throws -> Event {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      lock.lock()
      for i in mark..<events.count where !taken.contains(i) {
        let e = events[i]
        if match(e) { taken.insert(i); lock.unlock(); return e }
        if e.event == "error" { lock.unlock(); throw ToolError("waiting for \(what), got error (\(e.phase ?? "")): \(e.message ?? "")") }
      }
      lock.unlock()
      if !process.isRunning { throw ToolError("serve exited while waiting for \(what)") }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw ToolError("timed out waiting for \(what)")
  }

  /// The next frame, and the PNG it points at.
  func frame(_ what: String, reload: String? = nil) async throws -> (Event, Data) {
    let e = try await next(what) { $0.event == "frame" && (reload == nil || $0.reload == reload) }
    let png = try #require(e.png.flatMap { FileManager.default.contents(atPath: $0) }, "frame PNG for \(what)")
    return (e, png)
  }

  /// No frame or compile for `seconds`: the change was not watched.
  func expectQuiet(_ what: String, seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    lock.lock(); defer { lock.unlock() }
    let late = events[mark...].filter { $0.event == "frame" || $0.phase == "compiling" || $0.phase == "rebuilding" }
    #expect(late.isEmpty, "\(what) caused \(late.map { $0.phase ?? $0.event })")
  }

  func stop() {
    stdin.fileHandleForWriting.write(Data(#"{"cmd":"quit"}"#.utf8 + [0x0A]))
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < deadline { usleep(100_000) }
    if process.isRunning { process.terminate() }
  }
}

/// Saves `text` the way editors do (a temporary file renamed over it).
func save(_ path: String, _ text: String) throws {
  try text.write(toFile: path, atomically: true, encoding: .utf8)
}

func edit(_ path: String, _ from: String, _ to: String) throws {
  let text = try String(contentsOfFile: path, encoding: .utf8)
  #expect(text.contains(from), "\(from) in \((path as NSString).lastPathComponent)")
  try save(path, text.replacingOccurrences(of: from, with: to))
}

func watching(_ e: Event) -> Bool { e.event == "status" && e.phase == "watching" && (e.message ?? "").hasPrefix("watching ") }

@Suite("layered workspace, end to end", .serialized, .enabled(if: e2eEnabled, "set SWIFTPREVIEW_E2E=1"))
struct LayeredGraphTests {
  @Test("edits at every layer reload the preview; unwatched modules do not; structure changes rebuild",
        arguments: ["poll", "events"])
  func layers(watch: String) async throws {
    let ws = try workspace("layered", as: "layered-\(watch)")
    let core = ws + "/Core", ui = ws + "/UI", profile = ws + "/Features/Profile"
    let session = ws + "/.swiftpreview/e2e"
    try? FileManager.default.removeItem(atPath: session)
    let serve = try Serve(file: profile + "/ProfileView.swift", session: session, watch: watch)
    defer { serve.stop() }

    // Only the preview's module and what it imports: Profile, UI, Core
    // (4 files); not Sibling, though the host links it.
    var (_, png) = try await serve.frame("the first frame", reload: "initial")
    let start = try await serve.next("watching") { watching($0) }
    #expect(start.message == "watching 4 source files in 3 module(s)")

    // A body in each layer: hot reload, and the picture changes.
    for (file, from, to) in [
      (profile + "/ProfileView.swift", "Text(person.name).font(.title)", "Text(person.name.uppercased()).font(.title)"),
      (ui + "/Badge.swift", ".padding(8)", ".padding(20)"),
      (core + "/Greeting.swift", "\"Hello, \\(name)\"", "\"Welcome back, \\(name)\""),
    ] {
      let what = "a hot reload after editing \((file as NSString).lastPathComponent)"
      serve.step()
      try edit(file, from, to)
      let (e, next) = try await serve.frame(what)
      #expect(e.reload == "hot", "\(what): \(e.reload ?? "")")
      #expect(next != png, "\(what): the picture changed")
      png = next
    }

    // Linked into the host, but nothing the preview imports uses it.
    serve.step()
    try edit(ws + "/Sibling/Unrelated.swift", "\"sibling\"", "\"cousin\"")
    try await serve.expectQuiet("editing Sibling", seconds: 2)

    // A stored property: not hot reloadable; Bazel rebuilds, then it renders.
    serve.step()
    try edit(core + "/Person.swift", "public var name: String", "public var name: String\n  public var age = 36")
    _ = try await serve.next("a rebuild for the stored property") { $0.phase == "rebuilding" }
    (_, png) = try await serve.frame("the frame after the rebuild", reload: "rebuild")

    // A new source in a watched package (its BUILD globs): the modules
    // change, so it queries and builds again, and watches the new file.
    let added = ui + "/Avatar.swift"
    serve.step()
    try save(added, "import SwiftUI\n\npublic struct Avatar: View {\n  public init() {}\n  public var body: some View { Circle().frame(width: 24, height: 24) }\n}\n")
    let adding = try await serve.next("a rebuild for the added file") { $0.phase == "rebuilding" }
    #expect(adding.message == "Avatar.swift was added")
    _ = try await serve.frame("the frame after adding a file", reload: "rebuild")
    #expect(try await serve.next("watching") { watching($0) }.message == "watching 5 source files in 3 module(s)")

    // Using it from the preview: the new file is part of UI now.
    serve.step()
    try edit(profile + "/ProfileView.swift", "Badge(person: person)", "HStack { Avatar(); Badge(person: person) }")
    let (used, withAvatar) = try await serve.frame("a hot reload using the added view")
    #expect(used.reload == "hot")
    #expect(withAvatar != png)

    // Taking it away again (and its use).
    serve.step()
    try edit(profile + "/ProfileView.swift", "HStack { Avatar(); Badge(person: person) }", "Badge(person: person)")
    _ = try await serve.frame("a hot reload without the added view")
    serve.step()
    try FileManager.default.removeItem(atPath: added)
    let removing = try await serve.next("a rebuild for the removed file") { $0.phase == "rebuilding" }
    #expect(removing.message == "Avatar.swift was removed")
    _ = try await serve.frame("the frame after removing a file", reload: "rebuild")
    #expect(try await serve.next("watching") { watching($0) }.message == "watching 4 source files in 3 module(s)")

    // A BUILD file in a watched package.
    serve.step()
    try edit(ui + "/BUILD.bazel", "module_name = \"UI\",", "module_name = \"UI\",\n    # touched by the e2e test")
    let build = try await serve.next("a rebuild for the BUILD edit") { $0.phase == "rebuilding" }
    #expect(build.message?.hasPrefix("BUILD.bazel changed") == true, "\(build.message ?? "")")
    _ = try await serve.frame("the frame after the BUILD edit", reload: "rebuild")

    // A BUILD file outside them: nothing.
    serve.step()
    try edit(ws + "/Sibling/BUILD.bazel", "module_name = \"Sibling\",", "module_name = \"Sibling\",\n    # touched")
    try await serve.expectQuiet("editing Sibling's BUILD file", seconds: 2)
  }
}
