import Foundation
import SwiftPreviewCore

let usage = """
  swiftpreview: SwiftUI previews and hot reload for Bazel workspaces.

  USAGE
    swiftpreview list <file.swift>
        Print the #Preview / PreviewProvider entries in a file as JSON.
    swiftpreview devices
        Print the available iOS simulators as JSON, default pick first.
    swiftpreview thunk <file.swift> --module <Name> [--baseline <old.swift>]
        Print the hot-reload thunk for a file (debugging).
    swiftpreview serve <file.swift> [options]
        Build the preview host, render, and hot reload on every save.
        Writes JSON Lines events to stdout; reads JSON commands on stdin
        ({"cmd":"select","preview":1}, {"cmd":"open","file":"..."},
        {"cmd":"scheme","value":"dark"}, {"cmd":"renderer","value":"window"},
        {"cmd":"device","value":"iPhone 18 Pro"}, {"cmd":"devices"},
        {"cmd":"rebuild"}, {"cmd":"quit"}).
    swiftpreview snapshot <file.swift> [options] [--out <file.png>]
        Build, render once, print the frame event and exit.
    swiftpreview mcp
        Run a Model Context Protocol server on stdio (tools swiftui_preview,
        swiftui_preview_list, swiftui_preview_devices). Renders go through a
        running `serve` for the same workspace when there is one.

  OPTIONS
    --host <label>        swiftui_preview_host target (default: the one that
                          depends on the file, found with bazel query)
    --preview <n>         Which preview in the file (0-based, default 0)
    --scheme light|dark   Color scheme override
    --renderer auto|swiftui|window
                          How the host draws frames (macOS). auto (default) uses
                          the SwiftUI renderer unless the view has AppKit
                          controls, which only a window snapshot can draw.
    --simulator <name>    Simulator name or UDID (iOS)
    --frame device|none   iOS: draw the pane's strips inside the simulator's
                          bezel, from Xcode's device artwork (default device).
                          The frame PNG itself is always the bare screen.
    --workspace <dir>     Bazel workspace root (default: found from the file)
    --session <dir>       Session directory (default <workspace>/.swiftpreview/session)
    --bazel <path>        Bazel binary (default: bazelisk, else bazel)
    --width/--height <pt> Render size override

  CONFIGURATION
    None. The host is found from the file, the platform and a default
    simulator come from the host's build (swiftui_preview_host writes a
    manifest), and Bazel flags come from .bazelrc. The options above are for
    one-off choices.
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { print(usage); exit(0) }
args.removeFirst()
if verb == "-h" || verb == "--help" || verb == "help" { print(usage); exit(0) }

var positional: [String] = []
var flags: [String: String] = [:]
var i = 0
while i < args.count {
  let a = args[i]
  if a.hasPrefix("--") {
    let key = String(a.dropFirst(2))
    if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
      flags[key] = args[i + 1]; i += 2
    } else {
      flags[key] = "true"; i += 1
    }
  } else {
    positional.append(a); i += 1
  }
}

func absolute(_ p: String) -> String {
  p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let stdoutLock = NSLock()
func emitLine(_ e: Event) {
  guard let data = try? encoder.encode(e) else { return }
  stdoutLock.lock()
  FileHandle.standardOutput.write(data + Data("\n".utf8))
  stdoutLock.unlock()
}

switch verb {
case "mcp":
  let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
  MCPServer(executable: me).run()
case "devices":
  do {
    let all = try SimDevice.available()
    var ordered = all
    if let pick = SimDevice.preferred(all), let i = ordered.firstIndex(of: pick) { ordered.insert(ordered.remove(at: i), at: 0) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try enc.encode(ordered), as: UTF8.self))
  } catch { fail("\(error)") }
case "list":
  guard let file = positional.first else { fail("list needs a file") }
  do {
    let a = try SourceAnalyzer.analyze(path: absolute(file))
    let out = a.previews.map { ["index": "\($0.index)", "name": $0.displayName, "line": "\($0.line)", "kind": $0.kind.rawValue] }
    let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  } catch { fail("\(error)") }

case "thunk":
  guard let file = positional.first, let module = flags["module"] else { fail("thunk needs a file and --module") }
  do {
    let path = absolute(file)
    let current = try SourceAnalyzer.analyze(path: path)
    let baseSource = try flags["baseline"].map { try String(contentsOfFile: absolute($0), encoding: .utf8) }
    let baseline = baseSource.map { SourceAnalyzer.analyze(source: $0, path: path) } ?? current
    switch ThunkGenerator.plan(current: current, baseline: baseline, options: ThunkOptions(moduleName: module, registerPreviews: true, fileKey: file)) {
    case .thunk(let s): print(s)
    case .needsRebuild(let why): fail("needs rebuild: \(why)")
    }
  } catch { fail("\(error)") }

case "serve", "snapshot":
  guard let fileArg = positional.first else { fail("\(verb) needs a file") }
  let file = absolute(fileArg)
  guard let root = flags["workspace"].map(absolute) ?? BazelWorkspace.findRoot(from: file) else {
    fail("no Bazel workspace (MODULE.bazel / WORKSPACE) above \(file)")
  }
  let bazel = flags["bazel"] ?? {
    let r = try? Shell.run(["which", "bazelisk"])
    return r?.status == 0 ? "bazelisk" : "bazel"
  }()
  let workspace = BazelWorkspace(root: root, bazel: bazel)
  var host = flags["host"]
  if host == nil {
    let found = (try? workspace.hostsFor(file: file)) ?? []
    if found.count == 1 {
      host = found[0]
    } else {
      let message = found.isEmpty
        ? "no swiftui_preview_host depends on \(fileArg). Add its library to a host's deps, or pass --host."
        : "several preview hosts depend on \(fileArg): \(found.joined(separator: ", ")). Pick one with --host."
      // `serve` clients get the choices as data, to offer them.
      if verb == "serve" {
        var e = Event(event: "error", phase: "host", message: message)
        e.hosts = found
        emitLine(e)
      }
      fail(message)
    }
  }
  var options = SessionOptions(
    workspace: workspace, host: host!,
    file: file, sessionDir: flags["session"].map(absolute) ?? root + "/.swiftpreview/session")
  options.preview = Int(flags["preview"] ?? "0") ?? 0
  options.colorScheme = flags["scheme"]
  options.renderer = flags["renderer"] ?? "auto"
  options.simulator = flags["simulator"]
  options.deviceFrame = flags["frame"] != "none"
  options.width = flags["width"].flatMap(Double.init)
  options.height = flags["height"].flatMap(Double.init)

  if verb == "snapshot" {
    let session = PreviewSession(options: options) { e in
      if e.event == "status" { FileHandle.standardError.write(Data("[\(e.phase ?? "")] \(e.message ?? "")\n".utf8)) }
      else { emitLine(e) }
    }
    do {
      try FileManager.default.createDirectory(atPath: options.sessionDir, withIntermediateDirectories: true)
      try session.fullBuild()
    } catch { fail("\(error)") }
    let ok = session.render(reason: "snapshot")
    if session.options.platform == "macos" { session.shutdown() }
    exit(ok ? 0 : 1)
  }

  let queue = CommandQueue()
  let session = PreviewSession(options: options) { emitLine($0) }
  Thread.detachNewThread {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if let c = try? JSONDecoder().decode(Command.self, from: Data(trimmed.utf8)) {
        queue.push(c)
      } else if let n = Int(trimmed) {
        queue.push(Command(cmd: "select", preview: n))
      } else {
        queue.push(Command(cmd: trimmed))
      }
    }
  }
  signal(SIGTERM) { _ in exit(0) }
  session.serve(commands: queue)

default:
  fail("unknown command \(verb)\n\n\(usage)")
}
