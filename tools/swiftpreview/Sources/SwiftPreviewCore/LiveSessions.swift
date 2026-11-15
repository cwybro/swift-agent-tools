import Foundation

/// A running `swiftpreview serve`, as other clients (the MCP server, another
/// agent) find it: one file per process in a per-user registry.
///
/// Other clients drive it through `<session>/inbox/*.json` (one command per
/// file, applied in name order) and follow it through `<session>/events.jsonl`
/// (every event `serve` prints, one per line).
public struct LiveSession: Codable, Sendable {
  public var pid: Int32
  public var workspace: String
  public var host: String
  public var sessionDir: String
  /// The file being previewed now.
  public var file: String
  public var platform: String
  /// This process's ancestors, parent first: which agent (if any) started it.
  public var ancestors: [Int32]?

  public var eventsPath: String { (sessionDir as NSString).appendingPathComponent("events.jsonl") }
  public var inboxDir: String { (sessionDir as NSString).appendingPathComponent("inbox") }

  public var isAlive: Bool { kill(pid, 0) == 0 }

  /// `~/Library/Caches/swiftpreview/sessions`.
  public static var registryDir: String {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
    return (caches as NSString).appendingPathComponent("swiftpreview/sessions")
  }

  var registryPath: String { (Self.registryDir as NSString).appendingPathComponent("\(pid).json") }

  public func save() {
    try? FileManager.default.createDirectory(atPath: Self.registryDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(self) {
      FileManager.default.createFile(atPath: registryPath, contents: data)
    }
  }

  public func remove() { try? FileManager.default.removeItem(atPath: registryPath) }

  /// Live sessions; files left by processes that died are removed.
  public static func all() -> [LiveSession] {
    let dir = registryDir
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    var out: [LiveSession] = []
    for name in names where name.hasSuffix(".json") {
      let path = (dir as NSString).appendingPathComponent(name)
      guard let data = FileManager.default.contents(atPath: path),
            let s = try? JSONDecoder().decode(LiveSession.self, from: data) else { continue }
      if s.isAlive { out.append(s) } else { try? FileManager.default.removeItem(atPath: path) }
    }
    return out
  }

  /// The live session for this workspace that a client may drive, if any.
  ///
  /// `owner` is the agent process the client serves (see `MCPClient`). A
  /// session started under that agent (its pane) comes first; else one that
  /// no running agent started, such as a person's `swiftpreview serve` in a
  /// terminal. Another agent's session is never picked, so two chats in one
  /// workspace each render in their own pane. The newest wins a tie.
  public static func find(workspace: String, host: String? = nil, owner: Int32? = nil) -> LiveSession? {
    let root = (workspace as NSString).standardizingPath
    let here = all().filter { ($0.workspace as NSString).standardizingPath == root && (host == nil || $0.host == host) }
    if let owner, let mine = here.filter({ $0.ancestors?.contains(owner) == true }).max(by: { $0.pid < $1.pid }) {
      return mine
    }
    let agents = Set(MCPClient.all().map(\.owner))
    return here
      .filter { !($0.ancestors ?? []).contains(where: agents.contains) }
      .max { $0.pid < $1.pid }
  }

  /// Queues a command for the session.
  public func send(_ c: Command) throws {
    try FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true)
    let name = String(format: "%.6f-%d.json", Date().timeIntervalSince1970, Int.random(in: 0..<1_000_000))
    let data = try JSONEncoder().encode(c)
    // Write, then rename: the session never reads half a command.
    let tmp = (inboxDir as NSString).appendingPathComponent("." + name)
    FileManager.default.createFile(atPath: tmp, contents: data)
    try FileManager.default.moveItem(atPath: tmp, toPath: (inboxDir as NSString).appendingPathComponent(name))
  }

  /// Bytes in the event log now: read events after this offset.
  public func eventOffset() -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: eventsPath))?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  /// Events written after `offset`.
  public func events(after offset: UInt64) -> [Event] {
    guard let h = FileHandle(forReadingAtPath: eventsPath) else { return [] }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    let data = (try? h.readToEnd()) ?? Data()
    let decoder = JSONDecoder()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
      try? decoder.decode(Event.self, from: Data($0.utf8))
    }
  }
}

/// Appends events to `<session>/events.jsonl`.
final class EventLog: @unchecked Sendable {
  let path: String
  let lock = NSLock()
  let encoder = JSONEncoder()

  init(sessionDir: String) {
    path = (sessionDir as NSString).appendingPathComponent("events.jsonl")
    encoder.outputFormatting = [.sortedKeys]
    FileManager.default.createFile(atPath: path, contents: Data())
  }

  func append(_ e: Event) {
    guard let data = try? encoder.encode(e) else { return }
    lock.lock(); defer { lock.unlock() }
    guard let h = FileHandle(forWritingAtPath: path) else { return }
    defer { try? h.close() }
    _ = try? h.seekToEnd()
    try? h.write(contentsOf: data + Data("\n".utf8))
  }
}

/// A running `swiftpreview mcp` and the agent it serves, so `LiveSession.find`
/// can tell one agent's preview sessions from another's. One file per
/// process in `~/Library/Caches/swiftpreview/clients`.
public struct MCPClient: Codable, Sendable {
  public var pid: Int32
  /// The agent process: the nearest ancestor that isn't a shell.
  public var owner: Int32

  public static var registryDir: String {
    ((LiveSession.registryDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("clients")
  }

  var path: String { (Self.registryDir as NSString).appendingPathComponent("\(pid).json") }

  /// Registers this process.
  public static func register() -> MCPClient {
    let me = MCPClient(pid: getpid(), owner: Processes.agent(of: getpid()))
    try? FileManager.default.createDirectory(atPath: registryDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(me) { FileManager.default.createFile(atPath: me.path, contents: data) }
    return me
  }

  public func remove() { try? FileManager.default.removeItem(atPath: path) }

  /// Running clients; files left by processes that died are removed.
  public static func all() -> [MCPClient] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: registryDir)) ?? []
    var out: [MCPClient] = []
    for name in names where name.hasSuffix(".json") {
      let path = (registryDir as NSString).appendingPathComponent(name)
      guard let data = FileManager.default.contents(atPath: path),
            let c = try? JSONDecoder().decode(MCPClient.self, from: data) else { continue }
      if kill(c.pid, 0) == 0 { out.append(c) } else { try? FileManager.default.removeItem(atPath: path) }
    }
    return out
  }
}

/// Process ancestry, from the kernel's process table.
public enum Processes {
  /// The parent and short name of `pid`.
  public static func info(_ pid: Int32) -> (parent: Int32, name: String)? {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return (kp.kp_eproc.e_ppid, name)
  }

  /// `pid`'s ancestors, parent first, up to (not including) launchd.
  public static func ancestors(of pid: Int32) -> [Int32] {
    var out: [Int32] = []
    var p = pid
    while let i = info(p), i.parent > 1, out.count < 64 {
      out.append(i.parent)
      p = i.parent
    }
    return out
  }

  static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "nohup", "login"]

  /// The process that started `pid`, skipping shells that only exec'd it.
  public static func agent(of pid: Int32) -> Int32 {
    for p in ancestors(of: pid) where !shells.contains(info(p)?.name ?? "") { return p }
    return getppid()
  }
}
