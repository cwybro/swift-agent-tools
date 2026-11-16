import Foundation
import Testing
@testable import SwiftPreviewCore

func compile(_ name: String, dir: String, searches: [String] = [], sources: [String] = []) -> ModuleCompile {
  ModuleCompile(
    moduleName: name, swiftc: "swiftc", flags: searches.flatMap { ["-I", $0] }, sources: sources,
    moduleDir: dir, target: "arm64-apple-ios17.0-simulator", environment: [:], configuration: "ios-fastbuild")
}

@Test("the module graph comes from search paths; a closure is a module and what it imports")
func moduleGraphFromSearchPaths() {
  let out = "bazel-out/ios-fastbuild/bin"
  let compiles = [
    compile("App", dir: "\(out)/App", searches: ["\(out)/Profile", "\(out)/Feed", "\(out)/Core"]),
    compile("Profile", dir: "\(out)/Features/Profile", searches: ["\(out)/Core/", "\(out)/UI"]),
    compile("Feed", dir: "\(out)/Feed", searches: ["\(out)/Core"]),
    compile("Core", dir: "\(out)/Core"),
    compile("UI", dir: "\(out)/UI", searches: ["\(out)/Core"]),
  ]
  // Profile's own folder differs from the one App searches: App's link is lost,
  // which only matters for App's closure.
  let graph = ModuleGraph(compiles, execRoot: "/exec")
  #expect(graph.closure(of: "Profile") == ["Profile", "Core", "UI"])
  #expect(graph.closure(of: "Feed") == ["Feed", "Core"])
  #expect(graph.closure(of: "Core") == ["Core"])
  #expect(graph.closure(of: "App").isSuperset(of: ["App", "Feed", "Core"]))
}

@Test("explicit module builds: dependencies come from the module map file")
func moduleGraphFromExplicitMap() throws {
  let exec = NSTemporaryDirectory() + "exec-\(getpid())"
  try FileManager.default.createDirectory(atPath: exec + "/maps", withIntermediateDirectories: true)
  try Data(#"[{"moduleName":"Core","modulePath":"bazel-out/bin/Core/Core.swiftmodule"},{"moduleName":"Swift","modulePath":"/sdk/Swift.swiftmodule"}]"#.utf8)
    .write(to: URL(fileURLWithPath: exec + "/maps/Profile.json"))
  var profile = compile("Profile", dir: "bazel-out/bin/Profile")
  profile.moduleMapFile = "maps/Profile.json"
  let graph = ModuleGraph([profile, compile("Core", dir: "bazel-out/bin/Core")], execRoot: exec)
  #expect(graph.closure(of: "Profile") == ["Profile", "Core"])
}

/// A tiny workspace: two packages, each with a BUILD file and sources.
func makeWorkspace() throws -> (root: String, a: String, b: String, scope: WatchScope) {
  let root = standardized(NSTemporaryDirectory() + "ws-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
  for pkg in ["Features/Profile", "Core"] {
    try FileManager.default.createDirectory(atPath: "\(root)/\(pkg)", withIntermediateDirectories: true)
    try "swift_library(name = \"x\", srcs = glob([\"*.swift\"]))".write(toFile: "\(root)/\(pkg)/BUILD.bazel", atomically: true, encoding: .utf8)
  }
  let a = "\(root)/Features/Profile/ProfileView.swift", b = "\(root)/Core/Model.swift"
  try "struct ProfileView {}".write(toFile: a, atomically: true, encoding: .utf8)
  try "struct Model {}".write(toFile: b, atomically: true, encoding: .utf8)
  try FileManager.default.createDirectory(atPath: "\(root)/Unrelated", withIntermediateDirectories: true)
  let scope = WatchScope(modules: ["Profile", "Core"], sources: [a, b], root: root)
  return (root, a, b, scope)
}

@Test("a change is an edit, or a change of the modules: a source added or removed, or a BUILD file")
func classifiesChanges() throws {
  let (root, a, b, scope) = try makeWorkspace()
  #expect(scope.packages == ["\(root)/Features/Profile", "\(root)/Core"])
  #expect(scope.classify([a]) == .sources)
  #expect(scope.classify([]) == .none)
  // Outside the preview's packages: nothing to do.
  try "struct X {}".write(toFile: "\(root)/Unrelated/X.swift", atomically: true, encoding: .utf8)
  #expect(scope.classify(["\(root)/Unrelated/X.swift"]) == .none)
  // A new file in a watched package.
  try "struct New {}".write(toFile: "\(root)/Core/New.swift", atomically: true, encoding: .utf8)
  guard case .structure = scope.classify(["\(root)/Core/New.swift"]) else { Issue.record("added"); return }
  guard case .structure = scope.classify(["\(root)/Core/BUILD.bazel"]) else { Issue.record("BUILD"); return }
  try FileManager.default.removeItem(atPath: b)
  guard case .structure = scope.classify([b]) else { Issue.record("removed"); return }
}

@Test("polling notices edits, added files and BUILD changes")
func pollWatcherNotices() async throws {
  let (root, a, _, scope) = try makeWorkspace()
  let watcher = PollWatcher(scope: scope, built: [:])
  #expect(watcher.takeChanges().isEmpty)
  try await Task.sleep(nanoseconds: 1_100_000_000)  // file times are to the second on some volumes
  try "struct ProfileView { var x = 1 }".write(toFile: a, atomically: true, encoding: .utf8)
  #expect(scope.classify(watcher.takeChanges()) == .sources)
  try "struct New {}".write(toFile: "\(root)/Features/Profile/New.swift", atomically: true, encoding: .utf8)
  let added = watcher.takeChanges()
  #expect(added.contains("\(root)/Features/Profile/New.swift"))
  guard case .structure = scope.classify(added) else { Issue.record("added"); return }
  try await Task.sleep(nanoseconds: 1_100_000_000)
  try "swift_library(name = \"y\")".write(toFile: "\(root)/Core/BUILD.bazel", atomically: true, encoding: .utf8)
  guard case .structure = scope.classify(watcher.takeChanges()) else { Issue.record("BUILD"); return }
}

@Test("FSEvents notices a save to a watched source, and a file added to a package")
func eventWatcherNotices() async throws {
  let (root, a, _, scope) = try makeWorkspace()
  let watcher = try #require(SourceWatcher(scope: scope))
  try await Task.sleep(nanoseconds: 300_000_000)
  _ = watcher.takeChanges()

  func wait(for check: (Set<String>) -> Bool) async throws -> Bool {
    var seen = Set<String>()
    for _ in 0..<40 {
      try await Task.sleep(nanoseconds: 50_000_000)
      seen.formUnion(watcher.takeChanges())
      if check(seen) { return true }
    }
    return false
  }
  try "struct X { var x = 1 }".write(toFile: "\(root)/Unrelated/X.swift", atomically: true, encoding: .utf8)
  // Saved the way editors do: a temporary file renamed over the original.
  try "struct ProfileView { var x = 1 }".write(toFile: a, atomically: true, encoding: .utf8)
  var last = Set<String>()
  #expect(try await wait { last = $0; return scope.classify($0) == .sources })
  #expect(!last.contains("\(root)/Unrelated/X.swift"), "outside the watched packages")
  try "struct New {}".write(toFile: "\(root)/Core/New.swift", atomically: true, encoding: .utf8)
  #expect(try await wait { if case .structure = scope.classify($0) { return true }; return false })
}

@Test("a host app's fingerprint changes with its files, not otherwise")
func appFingerprintFollowsTheBuild() throws {
  let app = NSTemporaryDirectory() + "fp-\(getpid()).app"
  try? FileManager.default.removeItem(atPath: app)
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try Data("one".utf8).write(to: URL(fileURLWithPath: app + "/Host"))
  let a = SimulatorHost.fingerprint(app)
  #expect(SimulatorHost.fingerprint(app) == a)
  try Data("two!".utf8).write(to: URL(fileURLWithPath: app + "/Host"))
  #expect(SimulatorHost.fingerprint(app) != a)
}

@Test("a watcher started after an edit still reports it: it starts from when the scope was taken")
func watchersStartFromTheScope() async throws {
  let (root, a, _, scope) = try makeWorkspace()
  let built = [a: try #require(PollWatcher.mtime(a))]
  try await Task.sleep(nanoseconds: 1_100_000_000)
  // Edited, and a file added, after the scope but before any watcher exists.
  try "struct ProfileView { var y = 2 }".write(toFile: a, atomically: true, encoding: .utf8)
  try "struct Late {}".write(toFile: "\(root)/Core/Late.swift", atomically: true, encoding: .utf8)
  let polled = PollWatcher(scope: scope, built: built).takeChanges()
  #expect(polled.contains(a))
  #expect(polled.contains("\(root)/Core/Late.swift"))
  let events = try #require(SourceWatcher(scope: scope))
  var seen = Set<String>()
  for _ in 0..<40 where !seen.contains(a) {
    try await Task.sleep(nanoseconds: 50_000_000)
    seen.formUnion(events.takeChanges())
  }
  #expect(seen.contains(a), "replayed from the scope's event id")
}
