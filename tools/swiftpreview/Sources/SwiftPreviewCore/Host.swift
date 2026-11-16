import Foundation

// MARK: - File protocol shared with SwiftPreviewRuntime (runtime/Protocol.swift)

public struct RenderRequest: Codable, Sendable {
  /// This swiftpreview run: a host kept warm from an earlier run sees `seq`
  /// start again.
  public var run: String?
  public var seq: Int
  /// Dylibs to load, in order, before rendering. Already-loaded ones are skipped.
  public var dylibs: [String]
  /// Registry key of the file whose previews to show.
  public var file: String
  public var preview: Int
  public var colorScheme: String?
  /// Points; nil uses the host window size (device) or the fitting size.
  public var width: Double?
  public var height: Double?
  /// `auto`, `swiftui` (SwiftUI's ImageRenderer) or `window` (snapshot of the
  /// host window). nil means `auto`.
  public var renderer: String?
  /// Where the host writes frames.
  public var outputDir: String
}

public struct RenderResponse: Codable, Sendable {
  public struct Preview: Codable, Sendable { public var name: String; public var line: Int }
  public var run: String?
  public var seq: Int
  public var ok: Bool
  public var error: String?
  public var previews: [Preview]
  public var selected: Int
  public var png: String?
  public var jpeg: String?
  public var width: Double?
  public var height: Double?
  public var loadMs: Double?
  public var renderMs: Double?
  /// The renderer that drew this frame (`swiftui` or `window`) and why.
  public var renderer: String?
  public var rendererReason: String?
}

// MARK: - Hosts

public protocol PreviewHost: AnyObject {
  /// Installs (if needed) and (re)starts the host app with the session dir.
  func launch(sessionDir: String) throws
  func terminate()
  var isRunning: Bool { get }
  var description: String { get }
}

/// A macOS executable started directly.
public final class MacHost: PreviewHost {
  let executable: String
  var process: Process?
  public init(executable: String) { self.executable = executable }

  public func launch(sessionDir: String) throws {
    terminate()
    process = try Shell.spawn(
      [executable], env: ["SWIFTPREVIEW_SESSION": sessionDir],
      logPath: (sessionDir as NSString).appendingPathComponent("host.log"))
  }

  public func terminate() {
    if let p = process, p.isRunning { p.terminate(); p.waitUntilExit() }
    process = nil
  }

  public var isRunning: Bool { process?.isRunning ?? false }
  public var description: String { "macOS host \((executable as NSString).lastPathComponent)" }
}

/// An iOS (or other simulator platform) app installed with `simctl`.
public final class SimulatorHost: PreviewHost {
  let bundlePath: String
  let deviceName: String?
  public private(set) var device: String = "booted"
  public private(set) var deviceLabel: String = ""
  /// The simulator device type, for drawing its bezel.
  public private(set) var deviceType: String?
  var bundleID: String = ""
  var launched = false
  var launchedAt = Date.distantPast
  var sessionDir = ""
  /// Whether the host has written `host.alive` since launch: hosts built
  /// before it existed never do, and are then trusted to be running.
  var sawAlive = false
  /// Set when `launch` found the last run's host still up and kept it.
  public private(set) var reused = false

  public init(bundlePath: String, deviceName: String?) {
    self.bundlePath = bundlePath
    self.deviceName = deviceName
  }

  /// `.app` directory, or an `.ipa` (unzipped into the session dir).
  func appPath(sessionDir: String) throws -> String {
    if bundlePath.hasSuffix(".app") {
      // Bazel's outputs are read-only (dr-xr-xr-x), and simctl's install
      // staging fails to copy a read-only bundle (EACCES): install a
      // writable copy instead.
      let dest = (sessionDir as NSString).appendingPathComponent("app/" + (bundlePath as NSString).lastPathComponent)
      if FileManager.default.fileExists(atPath: dest) {
        _ = try? Shell.run(["chmod", "-R", "u+w", dest])
        try? FileManager.default.removeItem(atPath: dest)
      }
      let copy = try Shell.run(["ditto", bundlePath, dest])
      guard copy.status == 0 else { throw ToolError("copying \(bundlePath) failed: \(copy.stderr)") }
      _ = try Shell.run(["chmod", "-R", "u+w", dest])
      return dest
    }
    if bundlePath.hasSuffix(".ipa") {
      let dest = (sessionDir as NSString).appendingPathComponent("ipa")
      try? FileManager.default.removeItem(atPath: dest)
      let r = try Shell.run(["ditto", "-x", "-k", bundlePath, dest])
      guard r.status == 0 else { throw ToolError("unzipping \(bundlePath) failed: \(r.stderr)") }
      let payload = (dest as NSString).appendingPathComponent("Payload")
      if let app = try FileManager.default.contentsOfDirectory(atPath: payload).first(where: { $0.hasSuffix(".app") }) {
        return (payload as NSString).appendingPathComponent(app)
      }
    }
    throw ToolError("no .app or .ipa at \(bundlePath)")
  }

  func ensureDevice() throws {
    let all = try SimDevice.available()
    let d: SimDevice
    if let name = deviceName {
      guard let found = all.first(where: { $0.udid == name || $0.name == name }) else {
        throw ToolError("no simulator named \(name). Available: \(all.map(\.name).joined(separator: ", "))")
      }
      d = found
    } else {
      guard let found = SimDevice.preferred(all) else {
        throw ToolError("no iOS simulator available; install one with `xcodebuild -downloadPlatform iOS`")
      }
      d = found
    }
    device = d.udid
    deviceLabel = d.label
    deviceType = d.deviceType
    if d.state != "Booted" {
      let r = try Shell.run(["xcrun", "simctl", "boot", d.udid])
      // "Unable to boot device in current state: Booted" is fine.
      if r.status != 0 && !r.stderr.contains("Booted") { throw ToolError("simctl boot \(d.name) failed:\n\(r.stderr)") }
      // Ours to shut down once idle (see SimulatorReaper); one the person
      // booted is never shut down.
      if r.status == 0 { SimulatorReaper.markBooted(d.udid) }
    }
    SimulatorReaper.touch(d.udid)
  }

  /// The host's last launch from this session folder.
  struct LaunchState: Codable { var device: String; var bundleID: String; var fingerprint: String }

  /// Identifies a build of the host app: every file's path, size and
  /// modification time (an .app), or the archive's (an .ipa).
  static func fingerprint(_ path: String) -> String {
    let fm = FileManager.default
    func stamp(_ p: String) -> String {
      let a = try? fm.attributesOfItem(atPath: p)
      let size = (a?[.size] as? Int) ?? 0
      let time = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      return "\(size):\(time)"
    }
    var parts = [path, stamp(path)]
    if let walk = fm.enumerator(atPath: path) {
      while let rel = walk.nextObject() as? String { parts.append(rel + "=" + stamp((path as NSString).appendingPathComponent(rel))) }
    }
    var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
    for byte in parts.joined(separator: "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(format: "%016llx", hash)
  }

  static func isFresh(_ path: String, within seconds: TimeInterval) -> Bool {
    guard let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(date) < seconds
  }

  /// Where each device's installed build is remembered, across sessions.
  static func installedPath(_ device: String) -> String {
    (SimulatorReaper.cacheDir as NSString).appendingPathComponent("installed/\(device).json")
  }

  public func launch(sessionDir: String) throws {
    try ensureDevice()
    self.sessionDir = sessionDir
    reused = false
    let fm = FileManager.default
    let statePath = (sessionDir as NSString).appendingPathComponent("host.json")
    let alivePath = (sessionDir as NSString).appendingPathComponent("host.alive")
    let fingerprint = Self.fingerprint(bundlePath)

    // The last run's host, kept warm (`keep-until`) and still up, on this
    // device with this build: keep it. It takes this run's requests.
    if let data = fm.contents(atPath: statePath),
       let last = try? JSONDecoder().decode(LaunchState.self, from: data),
       last.device == device, last.fingerprint == fingerprint, Self.isFresh(alivePath, within: 3) {
      bundleID = last.bundleID
      launched = true
      launchedAt = Date()
      sawAlive = true
      reused = true
      try? fm.removeItem(atPath: (sessionDir as NSString).appendingPathComponent("keep-until"))
      return
    }

    // Install only a build this device does not have yet.
    let installedPath = Self.installedPath(device)
    let installed = fm.contents(atPath: installedPath).flatMap { try? JSONDecoder().decode(LaunchState.self, from: $0) }
    if let installed, installed.fingerprint == fingerprint,
       (try? Shell.run(["xcrun", "simctl", "get_app_container", device, installed.bundleID]))?.status == 0 {
      bundleID = installed.bundleID
    } else {
      let app = try appPath(sessionDir: sessionDir)
      let plist = (app as NSString).appendingPathComponent("Info.plist")
      let id = try Shell.run(["plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist])
      bundleID = id.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      let install = try Shell.run(["xcrun", "simctl", "install", device, app])
      guard install.status == 0 else { throw ToolError("simctl install failed:\n\(install.stderr)") }
      try? fm.createDirectory(atPath: (installedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try? JSONEncoder().encode(LaunchState(device: device, bundleID: bundleID, fingerprint: fingerprint))
        .write(to: URL(fileURLWithPath: installedPath))
    }
    try? fm.removeItem(atPath: alivePath)
    let launch = try Shell.run(
      ["xcrun", "simctl", "launch", "--terminate-running-process", device, bundleID],
      env: ["SIMCTL_CHILD_SWIFTPREVIEW_SESSION": sessionDir])
    guard launch.status == 0 else { throw ToolError("simctl launch failed:\n\(launch.stderr)") }
    launched = true
    launchedAt = Date()
    sawAlive = false
    try? JSONEncoder().encode(LaunchState(device: device, bundleID: bundleID, fingerprint: fingerprint))
      .write(to: URL(fileURLWithPath: statePath))
  }

  public func terminate() {
    if launched, !bundleID.isEmpty { _ = try? Shell.run(["xcrun", "simctl", "terminate", device, bundleID]) }
    launched = false
    if !sessionDir.isEmpty {
      try? FileManager.default.removeItem(atPath: (sessionDir as NSString).appendingPathComponent("host.alive"))
    }
  }

  /// Leaves the host running for `seconds` after this run ends: it exits by
  /// itself after that unless another run in the folder takes it.
  public func keepWarm(seconds: Double) {
    guard launched, !sessionDir.isEmpty else { return }
    let until = Date().timeIntervalSince1970 + seconds
    try? Data(String(until).utf8).write(to: URL(fileURLWithPath: (sessionDir as NSString).appendingPathComponent("keep-until")))
  }

  /// Launched, and (once the host has said so) still answering: it writes
  /// `host.alive` every second.
  public var isRunning: Bool {
    guard launched else { return false }
    let alive = (sessionDir as NSString).appendingPathComponent("host.alive")
    if Self.isFresh(alive, within: 5) { sawAlive = true; return true }
    // Starting up, or a host from before `host.alive`.
    return !sawAlive && Date().timeIntervalSince(launchedAt) < 15 || !sawAlive && !FileManager.default.fileExists(atPath: alive)
  }
  public var description: String { "simulator \(deviceLabel.isEmpty ? device : deviceLabel) app \(bundleID)" }
}

/// An available iOS simulator, as `simctl list devices available -j` reports it.
public struct SimDevice: Codable, Sendable, Equatable {
  public var udid: String
  public var name: String
  /// e.g. "iOS 27.2".
  public var runtime: String
  public var state: String
  /// The runtime identifier, e.g. com.apple.CoreSimulator.SimRuntime.iOS-27-2.
  public var runtimeID: String
  /// e.g. com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro.
  public var deviceType: String?

  public var label: String { "\(name) (\(runtime))" }
  public var isBooted: Bool { state == "Booted" }
  /// Device-specific runtimes (`…iOS-27-2-iPhone19-4`) ship one unusual device.
  var isStandardRuntime: Bool { runtimeID.range(of: #"iOS-\d+-\d+$"#, options: .regularExpression) != nil }
  var version: [Int] {
    runtime.split(separator: " ").last.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
  }

  /// Every available iOS simulator: iPhones first, newest runtime first,
  /// standard runtimes before device-specific ones, then simctl's order.
  public static func available() throws -> [SimDevice] {
    struct List: Decodable {
      struct Device: Decodable { var udid: String; var name: String; var state: String; var deviceTypeIdentifier: String? }
      var devices: [String: [Device]]
    }
    let r = try Shell.run(["xcrun", "simctl", "list", "devices", "available", "-j"])
    guard r.status == 0 else { throw ToolError("simctl list failed (is Xcode installed and selected?):\n\(r.stderr)") }
    let list = try JSONDecoder().decode(List.self, from: Data(r.stdout.utf8))
    var out: [SimDevice] = []
    for (runtimeID, devices) in list.devices.sorted(by: { $0.key < $1.key }) where runtimeID.contains(".iOS-") {
      let tail = runtimeID.components(separatedBy: ".iOS-").last ?? ""
      let parts = tail.split(separator: "-").prefix { Int($0) != nil }
      let runtime = "iOS " + parts.joined(separator: ".")
      for d in devices {
        out.append(SimDevice(
          udid: d.udid, name: d.name, runtime: runtime, state: d.state, runtimeID: runtimeID,
          deviceType: d.deviceTypeIdentifier))
      }
    }
    return sort(out)
  }

  static func sort(_ devices: [SimDevice]) -> [SimDevice] {
    devices.enumerated().sorted { a, b in
      let x = a.element, y = b.element
      let xp = x.name.hasPrefix("iPhone"), yp = y.name.hasPrefix("iPhone")
      if xp != yp { return xp }
      if x.isStandardRuntime != y.isStandardRuntime { return x.isStandardRuntime }
      if x.version != y.version { return x.version.lexicographicallyPrecedes(y.version) == false }
      return a.offset < b.offset
    }.map(\.element)
  }

  /// The default: a booted iPhone, else the first iPhone in `sort` order.
  public static func preferred(_ devices: [SimDevice]) -> SimDevice? {
    devices.first { $0.isBooted && $0.name.hasPrefix("iPhone") && $0.isStandardRuntime }
      ?? devices.first { $0.isBooted }
      ?? devices.first
  }
}

/// Shuts down simulators swiftpreview booted once nothing has used them for a
/// while. Each booted one has a marker whose modification time is its last
/// use; a running `serve` touches it.
public enum SimulatorReaper {
  public static var cacheDir: String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/swiftpreview")
  }
  static func marker(_ udid: String) -> String {
    (cacheDir as NSString).appendingPathComponent("booted/\(udid)")
  }

  static func markBooted(_ udid: String) {
    let path = marker(udid)
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data())
  }

  /// Marks a use, for a simulator swiftpreview booted.
  public static func touch(_ udid: String) {
    let path = marker(udid)
    guard FileManager.default.fileExists(atPath: path) else { return }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
  }

  /// Shuts down each simulator swiftpreview booted and nothing used for
  /// `idle` seconds. Returns the UDIDs shut down.
  @discardableResult
  public static func reap(idle: TimeInterval) -> [String] {
    let dir = (cacheDir as NSString).appendingPathComponent("booted")
    let booted = Set(((try? SimDevice.available()) ?? []).filter { $0.state == "Booted" }.map(\.udid))
    var done: [String] = []
    for udid in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
      let path = (dir as NSString).appendingPathComponent(udid)
      guard booted.contains(udid) else { try? FileManager.default.removeItem(atPath: path); continue }
      guard let used = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date,
            Date().timeIntervalSince(used) >= idle else { continue }
      if (try? Shell.run(["xcrun", "simctl", "shutdown", udid]))?.status == 0 {
        try? FileManager.default.removeItem(atPath: path)
        done.append(udid)
      }
    }
    return done
  }

  /// Starts a detached `swiftpreview reap-simulators` that waits for `pid`
  /// to exit, then for `idle`, then shuts down what is still idle.
  public static func scheduleAfter(pid: Int32, idle: TimeInterval, executable: String) {
    guard idle > 0 else { return }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    defer { posix_spawnattr_destroy(&attr) }
    let argv = [executable, "reap-simulators", "--after-pid", String(pid), "--idle", String(Int(idle))]
    var cargs = argv.map { strdup($0) } + [nil]
    defer { for a in cargs { free(a) } }
    var child: pid_t = 0
    let devnull = "/dev/null"
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, devnull, fd == 0 ? O_RDONLY : O_WRONLY, 0) }
    _ = posix_spawn(&child, executable, &actions, &attr, &cargs, environ)
  }
}
