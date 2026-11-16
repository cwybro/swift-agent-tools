import Foundation

/// `swiftpreview mcp`: a Model Context Protocol server on stdio, so any agent
/// can render previews. A render goes through a running `swiftpreview serve`
/// for the same workspace when there is one (the hot-reloading session a
/// person is watching), else through a one-off `swiftpreview snapshot`.
public final class MCPServer {
  let executable: String
  let encoder = JSONEncoder()

  /// `executable`: this binary, run for snapshots.
  public init(executable: String) {
    self.executable = executable
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  }

  /// This server's registration: which agent it serves.
  var client: MCPClient?
  /// Snapshot folders this server made.
  var snapshotDirs: Set<String> = []

  public func run() {
    client = MCPClient.register()
    defer {
      client?.remove()
      for d in snapshotDirs { try? FileManager.default.removeItem(atPath: d) }
    }
    while let line = readLine() {
      guard let data = line.data(using: .utf8),
            let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = msg["method"] as? String else { continue }
      let id = msg["id"]
      let params = msg["params"] as? [String: Any] ?? [:]
      // Notifications (no id) need no answer.
      guard let id else { continue }
      do {
        reply(id: id, result: try handle(method: method, params: params))
      } catch let e as RPCError {
        reply(id: id, error: ["code": e.code, "message": e.message])
      } catch {
        reply(id: id, error: ["code": -32603, "message": "\(error)"])
      }
    }
  }

  struct RPCError: Error { var code: Int; var message: String }

  func handle(method: String, params: [String: Any]) throws -> [String: Any] {
    switch method {
    case "initialize":
      return [
        "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
        "capabilities": ["tools": [String: Any]()],
        "serverInfo": ["name": "swiftpreview", "version": "0.2.0"],
        "instructions":
          "SwiftUI previews for Bazel (rules_swift / rules_apple) projects. swiftui_preview renders a #Preview " +
          "and returns the image; when a person has a preview open (swiftpreview serve), it renders there, " +
          "hot reloading in about a second.",
      ]
    case "ping":
      return [:]
    case "tools/list":
      return ["tools": Self.tools]
    case "tools/call":
      guard let name = params["name"] as? String else { throw RPCError(code: -32602, message: "missing tool name") }
      let args = params["arguments"] as? [String: Any] ?? [:]
      do {
        return try call(name, args)
      } catch {
        return ["content": [["type": "text", "text": "\(error)"]], "isError": true]
      }
    default:
      throw RPCError(code: -32601, message: "method not found: \(method)")
    }
  }

  func reply(id: Any, result: [String: Any]? = nil, error: [String: Any]? = nil) {
    var msg: [String: Any] = ["jsonrpc": "2.0", "id": id]
    if let result { msg["result"] = result }
    if let error { msg["error"] = error }
    guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
  }

  // MARK: Tools

  static let tools: [[String: Any]] = [
    [
      "name": "swiftui_preview",
      "description":
        "Render a SwiftUI #Preview (or PreviewProvider) from a Bazel iOS/macOS project and return the image and the " +
        "PNG's path. Uses a running preview session for the workspace when there is one (hot reload, about 1s), else " +
        "builds the swiftui_preview_host with Bazel first. Compile errors come back as diagnostics at the file and line.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "file": ["type": "string", "description": "Swift file containing the preview (absolute, or relative to the server's directory)."],
          "preview": ["type": "number", "description": "Index of the preview in the file (0-based). Default 0."],
          "colorScheme": ["type": "string", "enum": ["light", "dark"], "description": "Render in this color scheme."],
          "host": [
            "type": "string",
            "description": "Bazel label of the swiftui_preview_host, only needed when several hosts include the file (the error lists them).",
          ],
          "device": [
            "type": "string",
            "description": "iOS hosts: simulator name (e.g. \"iPad Air 11-inch (M4)\") or UDID. See swiftui_preview_devices.",
          ],
          "renderer": [
            "type": "string", "enum": ["auto", "swiftui", "window"],
            "description":
              "macOS hosts: how to draw the frame. auto (default) uses SwiftUI's ImageRenderer unless the view has AppKit " +
              "controls; swiftui forces it; window snapshots the host window (draws every control).",
          ],
        ],
        "required": ["file"],
      ],
    ],
    [
      "name": "swiftui_preview_list",
      "description": "List the #Preview / PreviewProvider entries in a Swift file (index, name, line). No build needed.",
      "inputSchema": [
        "type": "object",
        "properties": ["file": ["type": "string", "description": "Swift file."]],
        "required": ["file"],
      ],
    ],
    [
      "name": "swiftui_preview_discover",
      "description":
        "List every SwiftUI preview a Bazel workspace can render: each Swift file with #Preview / PreviewProvider " +
        "entries that a swiftui_preview_host builds, with the previews' indexes, names and lines. Bazel queries only, " +
        "no build (about a second).",
      "inputSchema": [
        "type": "object",
        "properties": [
          "directory": ["type": "string", "description": "A folder: its Bazel workspace and any workspaces nested below it are searched. Default: the server's directory."],
        ],
      ],
    ],
    [
      "name": "swiftui_preview_devices",
      "description": "List the iOS simulators on this machine, the default pick first.",
      "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
  ]

  func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
    switch name {
    case "swiftui_preview": return try render(args)
    case "swiftui_preview_list":
      guard let file = args["file"] as? String else { throw ToolError("`file` is required") }
      let a = try SourceAnalyzer.analyze(path: absolute(file))
      let lines = a.previews.map { "\($0.index): \($0.displayName) (line \($0.line), \($0.kind.rawValue))" }
      return text(lines.isEmpty ? "No previews in \(file)." : lines.joined(separator: "\n"))
    case "swiftui_preview_discover":
      let dir = absolute(args["directory"] as? String ?? ".")
      let found = Discovery.find(from: dir, bazel: BazelWorkspace.preferredBazel())
      if found.workspaces.isEmpty { throw ToolError("no Bazel workspace at, above or below \(dir)") }
      let root = found.workspace
      if found.hosts.isEmpty {
        let why = found.failures.map { "\n" + $0.map { "\($0.key): \($0.value)" }.joined(separator: "\n") } ?? ""
        return text("No swiftui_preview_host targets in \(found.workspaces.joined(separator: ", ")).\(why)")
      }
      var lines = ["Preview hosts: \(found.hosts.joined(separator: ", "))"]
      for f in found.files {
        let rel = f.file.hasPrefix(root + "/") ? String(f.file.dropFirst(root.count + 1)) : f.file
        lines.append("\(rel) (\(f.hosts.joined(separator: ", ")))")
        for p in f.previews { lines.append("  \(p.index): \(p.name) (line \(p.line))") }
      }
      if found.files.isEmpty { lines.append("No previews in the files those hosts build.") }
      return text(lines.joined(separator: "\n"))
    case "swiftui_preview_devices":
      let all = try SimDevice.available()
      var ordered = all
      if let pick = SimDevice.preferred(all), let i = ordered.firstIndex(of: pick) { ordered.insert(ordered.remove(at: i), at: 0) }
      let lines = ordered.enumerated().map { i, d in "\(d.label)\(d.isBooted ? ", booted" : "")\(i == 0 ? "  (default)" : "") \(d.udid)" }
      return text(lines.isEmpty ? "No iOS simulators." : lines.joined(separator: "\n"))
    default:
      throw ToolError("unknown tool \(name)")
    }
  }

  func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }

  func absolute(_ p: String) -> String {
    let path = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
    return (path as NSString).standardizingPath
  }

  func render(_ args: [String: Any]) throws -> [String: Any] {
    guard let fileArg = args["file"] as? String else { throw ToolError("`file` is required") }
    let file = absolute(fileArg)
    guard FileManager.default.fileExists(atPath: file) else { throw ToolError("no file at \(file)") }
    guard let root = BazelWorkspace.findRoot(from: file) else {
      throw ToolError("no Bazel workspace (MODULE.bazel / WORKSPACE) above \(file)")
    }
    let preview = (args["preview"] as? NSNumber)?.intValue ?? 0
    let scheme = args["colorScheme"] as? String
    let renderer = args["renderer"] as? String
    let device = args["device"] as? String
    let host = args["host"] as? String

    if let live = LiveSession.find(workspace: root, host: host, owner: client?.owner, file: file) {
      var commands: [Command] = []
      if let device { commands.append(Command(cmd: "device", value: device)) }
      if let renderer { commands.append(Command(cmd: "renderer", value: renderer)) }
      if let scheme { commands.append(Command(cmd: "scheme", value: scheme)) }
      commands.append(live.file == file ? Command(cmd: "select", preview: preview) : Command(cmd: "open", preview: preview, file: file))
      let result = try drive(live, commands)
      return describe(result, file: file, via: "the running preview session")
    }

    // One folder per server, so concurrent agents' snapshots never share a
    // request or frames; removed when the server exits.
    let sessionDir = root + "/.swiftpreview/mcp-snapshot-\(getpid())"
    snapshotDirs.insert(sessionDir)
    var argv = [executable, "snapshot", file, "--preview", String(preview), "--session", sessionDir]
    if let scheme { argv += ["--scheme", scheme] }
    if let renderer { argv += ["--renderer", renderer] }
    if let device { argv += ["--simulator", device] }
    if let host { argv += ["--host", host] }
    let run = try Shell.run(argv, cwd: root)
    let events = run.stdout.split(separator: "\n").compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    guard let last = events.last(where: { $0.event == "frame" || $0.event == "error" }) else {
      throw ToolError("Preview failed:\n" + run.stderr.split(separator: "\n").suffix(30).joined(separator: "\n"))
    }
    return describe(last, file: file, via: "a one-off Bazel build")
  }

  /// Sends `commands` and waits until the session has handled them all.
  func drive(_ live: LiveSession, _ commands: [Command]) throws -> Event {
    let offset = live.eventOffset()
    for c in commands { try live.send(c) }
    // Each command ends with a `watching` status; a file outside the built
    // host means a Bazel build first, so allow minutes.
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
      let events = live.events(after: offset)
      let handled = events.filter { $0.event == "status" && $0.phase == "watching" }.count
      if handled >= commands.count || events.contains(where: { $0.event == "exit" }) {
        if let last = events.last(where: { $0.event == "frame" || $0.event == "error" }) { return last }
        throw ToolError("the preview session handled the request but drew no frame")
      }
      guard live.isAlive else { throw ToolError("the preview session exited") }
      usleep(100_000)
    }
    throw ToolError("the preview session did not answer within 10 minutes")
  }

  func describe(_ e: Event, file: String, via: String) -> [String: Any] {
    let name = (file as NSString).lastPathComponent
    if e.event == "error" {
      var msg = "Preview \(e.phase ?? "") failed:\n\(e.message ?? "")"
      if let hosts = e.hosts, !hosts.isEmpty { msg += "\nHosts: \(hosts.joined(separator: ", ")). Pass one as `host`." }
      return ["content": [["type": "text", "text": msg]], "isError": true]
    }
    let names = (e.previews ?? []).enumerated().map { "\($0.offset): \($0.element.name)" }.joined(separator: ", ")
    let total = (e.timings?["compile"] ?? 0) + (e.timings?["load"] ?? 0) + (e.timings?["render"] ?? 0)
    var lines = [
      "Rendered \(name) preview \(e.selected ?? 0) (\(Int(e.width ?? 0))x\(Int(e.height ?? 0))pt) through \(via)" +
        (total > 0 ? String(format: " in %.2fs", total) : "") + ": \(e.png ?? "")",
    ]
    if let r = e.renderer { lines.append("Drawn with: \(r)\(e.rendererReason.map { " (\($0))" } ?? "")") }
    lines.append("Previews in file: \(names)")
    var content: [[String: Any]] = [["type": "text", "text": lines.joined(separator: "\n")]]
    if let png = e.png, let data = FileManager.default.contents(atPath: png), data.count < 4_000_000 {
      content.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
    }
    return ["content": content]
  }
}
