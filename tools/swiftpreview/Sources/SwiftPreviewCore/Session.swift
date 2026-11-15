import Foundation

/// One line of `swiftpreview serve` output (JSON Lines on stdout).
public struct Event: Codable, Sendable {
  public var event: String  // status | frame | error | host | exit
  public var phase: String?
  public var message: String?
  public var file: String?
  public var previews: [RenderResponse.Preview]?
  public var selected: Int?
  public var png: String?
  public var jpeg: String?
  public var width: Double?
  public var height: Double?
  /// `hot` (thunk only) or `rebuild` (Bazel build + relaunch).
  public var reload: String?
  public var timings: [String: Double]?
  public var seq: Int?
  /// Which renderer drew the frame, what was asked for, and why.
  public var renderer: String?
  public var rendererMode: String?
  public var rendererReason: String?
  /// `host` events: the host's platform, and for iOS the simulators on this
  /// machine and the UDID of the one in use.
  public var platform: String?
  public var devices: [SimDevice]?
  public var device: String?
  /// `frame` events: the frame at 2x (the pane's resolution) in slices small
  /// enough for the pane's image element, top to bottom.
  public var strips: [FrameStrip]?
  /// The strips' width in points, when it differs from `width`: iOS frames
  /// are cut from a picture of the device (bezel and all), not the bare screen.
  public var stripWidth: Double?
  /// `error` events with phase `host`: the preview hosts that include the
  /// file, when there are several to pick from.
  public var hosts: [String]?

  public init(event: String, phase: String? = nil, message: String? = nil) {
    self.event = event
    self.phase = phase
    self.message = message
  }
}

public struct SessionOptions: Sendable {
  public var workspace: BazelWorkspace
  public var host: String
  /// `ios` or `macos`: read from the build on every full build (the host's
  /// manifest, else its compile commands' `-target` triples).
  public var platform: String = ""
  public var file: String
  public var preview: Int = 0
  public var colorScheme: String?
  public var simulator: String?
  public var sessionDir: String
  public var width: Double?
  public var height: Double?
  /// `auto` | `swiftui` | `window`.
  public var renderer: String = "auto"
  /// iOS: draw the strips inside the simulator's device bezel.
  public var deviceFrame = true

  public init(workspace: BazelWorkspace, host: String, file: String, sessionDir: String) {
    self.workspace = workspace
    self.host = host
    self.file = file
    self.sessionDir = sessionDir
  }
}

/// A command from the client: stdin lines or `<session>/control.json`.
public struct Command: Codable, Sendable {
  public var cmd: String  // select | open | scheme | renderer | device | devices | rebuild | refresh | size | quit
  public var preview: Int?
  public var file: String?
  public var value: String?
  public var width: Double?
  public var height: Double?
  public var id: Int?

  public init(cmd: String, preview: Int? = nil, file: String? = nil, value: String? = nil) {
    self.cmd = cmd
    self.preview = preview
    self.file = file
    self.value = value
  }
}

public final class PreviewSession: @unchecked Sendable {
  public var options: SessionOptions
  let sink: @Sendable (Event) -> Void
  /// `serve` only: every event, for clients that are not this process's parent.
  var eventLog: EventLog?
  var live: LiveSession?

  var compiles: [ModuleCompile] = []
  var moduleBySource: [String: ModuleCompile] = [:]
  var baseline: [String: String] = [:]
  var mtimes: [String: Date] = [:]
  var host: PreviewHost?
  var execRoot = ""
  var outputBase = ""
  var compiler: ThunkCompiler?
  var serial = 0
  var seq = 0
  var lastControlID: Int?
  /// Identity of each built `.swiftmodule` (and the host binary) at the last
  /// full build. Another Bazel build (a second session, a manual `bazel
  /// build`) replaces them, and thunks compiled against the new ones would
  /// not match the running host.
  var outputFingerprint: [String: String] = [:]
  /// The host target's outputs (executable, .app) at the last full build.
  var hostOutputs: [String] = []

  public init(options: SessionOptions, emit: @escaping @Sendable (Event) -> Void) {
    self.options = options
    self.sink = emit
  }

  func emit(_ e: Event) {
    sink(e)
    eventLog?.append(e)
  }

  /// Publishes this session in the registry (with the current file and platform).
  func publish() {
    guard var l = live else { return }
    l.file = options.file
    l.platform = options.platform
    live = l
    l.save()
  }

  var fileKey: String { options.workspace.relative(options.file) }

  // MARK: Build

  func status(_ phase: String, _ message: String? = nil) {
    emit(Event(event: "status", phase: phase, message: message))
  }

  /// The manifest `swiftui_preview_host` writes next to the app.
  struct HostManifest: Decodable {
    var platform: String?
    var simulator: String?
  }

  /// Re-detects Xcode in Bazel when its cached detection no longer matches
  /// the selected Xcode. Returns true if it refreshed.
  @discardableResult
  func refreshXcodeIfStale(force: Bool = false) throws -> Bool {
    let ws = options.workspace
    if outputBase.isEmpty { outputBase = try ws.info("output_base") }
    guard let cached = XcodeCheck.cached(outputBase: outputBase) else { return false }
    let active = XcodeCheck.activeBuild(developerDir: ThunkCompiler.activeDeveloperDir())
    let reason = XcodeCheck.staleReason(cached: cached, active: active)
      ?? (force ? "the build failed the way a stale Xcode detection does" : nil)
    guard let reason else { return false }
    status("xcode", "\(reason): refreshing Bazel's Xcode detection (keeps the build cache)")
    try ws.refreshXcode(repo: cached.repo)
    return true
  }

  func bazelBuild() throws {
    try options.workspace.build([options.host]) { [emit] line in
      if line.hasPrefix("[") || line.hasPrefix("INFO:") || line.hasPrefix("ERROR:") {
        emit(Event(event: "status", phase: "building", message: line))
      }
    }
  }

  /// Bazel build, aquery, (re)launch the host, and take a new baseline.
  public func fullBuild() throws {
    let ws = options.workspace
    try refreshXcodeIfStale()
    status("building", "bazel build \(options.host)")
    do {
      try bazelBuild()
    } catch let error as ToolError where XcodeCheck.isStaleXcodeError(error.description) {
      guard try refreshXcodeIfStale(force: true) else { throw error }
      status("building", "bazel build \(options.host) (after refreshing Xcode detection)")
      try bazelBuild()
    }
    status("querying", "reading compile commands")
    if execRoot.isEmpty { execRoot = try ws.info("execution_root") }
    compiles = try ws.swiftCompiles(host: options.host, platformHint: nil)
    let outputs = try ws.outputFiles(options.host).map { $0.hasPrefix("/") ? $0 : (execRoot as NSString).appendingPathComponent($0) }

    // The platform and default simulator come from the build: the host's
    // manifest, else the compile commands' target triples.
    let manifest = outputs.first(where: { $0.hasSuffix(".preview_manifest.json") })
      .flatMap { FileManager.default.contents(atPath: $0) }
      .flatMap { try? JSONDecoder().decode(HostManifest.self, from: $0) }
    guard let built = manifest?.platform ?? AQuery.hostPlatform(compiles) else {
      throw ToolError("\(options.host) compiles no Swift for a target platform; is it a swiftui_preview_host?")
    }
    guard built == "ios" || built == "macos" else {
      throw ToolError("\(options.host) builds for \(built); preview hosts run on ios (simulator) or macos")
    }
    options.platform = built
    if options.simulator == nil { options.simulator = manifest?.simulator }
    moduleBySource = [:]
    for c in compiles {
      for src in c.sources where !src.hasPrefix("external/") && !src.hasPrefix("bazel-out/") {
        moduleBySource[standardized((ws.root as NSString).appendingPathComponent(src))] = c
      }
    }
    guard moduleBySource[standardized(options.file)] != nil else {
      throw ToolError("\(fileKey) is not compiled by any Swift module in \(options.host). Is the library in the host's deps?")
    }
    compiler = ThunkCompiler(
      execRoot: execRoot, developerDir: ThunkCompiler.activeDeveloperDir(),
      moduleDirs: Array(Set(compiles.compactMap(\.moduleDir))).sorted())

    baseline = [:]
    mtimes = [:]
    for path in moduleBySource.keys {
      baseline[path] = try? String(contentsOfFile: path, encoding: .utf8)
      mtimes[path] = mtime(path)
    }

    status("launching", "starting the preview host")
    host?.terminate()
    if options.platform == "macos" {
      guard let exe = outputs.first(where: { !$0.hasSuffix(".dSYM") && FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw ToolError("no executable among \(options.host) outputs: \(outputs)")
      }
      host = MacHost(executable: exe)
    } else {
      guard let bundle = outputs.first(where: { $0.hasSuffix(".app") || $0.hasSuffix(".ipa") }) else {
        throw ToolError("no .app or .ipa among \(options.host) outputs: \(outputs)")
      }
      host = SimulatorHost(bundlePath: bundle, deviceName: options.simulator)
    }
    try? FileManager.default.removeItem(atPath: responsePath)
    try host!.launch(sessionDir: options.sessionDir)
    hostOutputs = outputs
    outputFingerprint = fingerprintOutputs()
    emitHost()
  }

  /// Tells the client the platform and, for iOS, which simulators it can pick.
  func emitHost() {
    var e = Event(event: "host")
    e.platform = options.platform
    if let sim = host as? SimulatorHost {
      e.devices = (try? SimDevice.available()) ?? []
      e.device = sim.device
      e.message = sim.deviceLabel
    }
    emit(e)
  }

  /// Moves the iOS host to another simulator: install and launch the built
  /// app there (no Bazel build), then render.
  func switchDevice(_ value: String) throws {
    guard let sim = host as? SimulatorHost else { throw ToolError("only iOS hosts run on a simulator") }
    let all = try SimDevice.available()
    guard let d = all.first(where: { $0.udid == value || $0.name == value }) else {
      throw ToolError("no simulator named \(value). Available: \(all.map(\.name).joined(separator: ", "))")
    }
    if d.udid == sim.device { return }
    status("launching", "installing on \(d.label)")
    options.simulator = d.udid
    sim.terminate()
    let next = SimulatorHost(bundlePath: sim.bundlePath, deviceName: d.udid)
    host = next
    try? FileManager.default.removeItem(atPath: responsePath)
    try next.launch(sessionDir: options.sessionDir)
    emitHost()
  }

  /// Files whose replacement means the running host is stale.
  func watchedOutputs() -> [String] {
    let modules = compiles.compactMap { c in
      c.moduleDir.map { ((execRoot as NSString).appendingPathComponent($0) as NSString).appendingPathComponent(c.moduleName + ".swiftmodule") }
    }
    return modules + hostOutputs
  }

  /// path → "inode:size:mtime", or "missing". Bazel keeps mtimes on rebuilt
  /// outputs, but writes them as new files, so the inode changes.
  func fingerprintOutputs() -> [String: String] {
    var result: [String: String] = [:]
    for path in watchedOutputs() {
      guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { result[path] = "missing"; continue }
      let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
      let time = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      result[path] = "\(inode):\(size):\(time)"
    }
    return result
  }

  /// A path whose output changed since the last full build, if any.
  func staleOutput() -> String? {
    guard !outputFingerprint.isEmpty else { return nil }
    let now = fingerprintOutputs()
    return now.keys.sorted().first { now[$0] != outputFingerprint[$0] }
  }

  /// Compiler errors that mean the build outputs moved under us, not that the
  /// user's code is wrong.
  static func isStaleBuildError(_ text: String) -> Bool {
    let markers = [
      "no such module", "could not find module", "error opening input file",
      "compiled module was created by", "module file was created by", "malformed compiled module",
      "missing required module", "could not build Objective-C module",
    ]
    return markers.contains { text.contains($0) }
  }

  // MARK: Render

  enum RenderOutcome { case ok, failed, rebuilt }

  /// Generates and compiles thunks for every file that differs from the
  /// baseline (plus the previewed file), then asks the host to render.
  @discardableResult
  public func render(reason: String, allowRebuild: Bool = true) -> Bool {
    do {
      let entry = standardized(options.file)
      var changed = Set(baseline.keys.filter { (try? String(contentsOfFile: $0, encoding: .utf8)) != baseline[$0] })
      changed.insert(entry)
      if moduleBySource[entry] == nil {
        throw ToolError("\(fileKey) is not part of \(options.host)")
      }

      if allowRebuild, let path = staleOutput() {
        status("rebuilding", "build outputs changed outside this session (\((path as NSString).lastPathComponent)); rebuilding")
        try fullBuild()
        return render(reason: "rebuild", allowRebuild: false)
      }

      serial += 1
      let thunkDir = (options.sessionDir as NSString).appendingPathComponent("thunks/\(serial)")
      try FileManager.default.createDirectory(atPath: thunkDir, withIntermediateDirectories: true)

      var byModule: [String: [String]] = [:]
      status("compiling", "generating thunks for \(changed.count) file(s)")
      for path in changed.sorted() {
        guard let module = moduleBySource[path] else { continue }
        let current = SourceAnalyzer.analyze(source: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "", path: path)
        let base = SourceAnalyzer.analyze(source: baseline[path] ?? "", path: path)
        let plan = ThunkGenerator.plan(
          current: current, baseline: base,
          options: ThunkOptions(moduleName: module.moduleName, registerPreviews: path == entry, fileKey: fileKey))
        switch plan {
        case .needsRebuild(let why):
          guard allowRebuild else { throw ToolError("still needs a rebuild after rebuilding: \(why)") }
          status("rebuilding", why)
          try fullBuild()
          return render(reason: "rebuild", allowRebuild: false)
        case .thunk(let source):
          let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + "+Preview.swift"
          let dir = (thunkDir as NSString).appendingPathComponent(module.moduleName)
          try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
          let out = (dir as NSString).appendingPathComponent(name)
          try source.write(toFile: out, atomically: true, encoding: .utf8)
          byModule[module.moduleName, default: []].append(out)
        }
      }

      // Dependencies first, the previewed module last.
      let entryModule = moduleBySource[entry]!.moduleName
      let order = byModule.keys.sorted { a, b in a == entryModule ? false : b == entryModule ? true : a < b }
      var dylibs: [String] = []
      var compileSeconds = 0.0
      for name in order {
        let module = compiles.first { $0.moduleName == name }!
        status("compiling", "compiling \(name) thunks")
        let out = try compiler!.compile(module: module, thunks: byModule[name]!, outputDir: thunkDir, serial: serial)
        dylibs.append(out.dylib)
        compileSeconds += out.seconds
      }

      if let host, !host.isRunning {
        status("launching", "the host exited; relaunching")
        try host.launch(sessionDir: options.sessionDir)
      }

      status("rendering", nil)
      seq += 1
      let request = RenderRequest(
        seq: seq, dylibs: dylibs, file: fileKey, preview: options.preview,
        colorScheme: options.colorScheme, width: options.width, height: options.height,
        renderer: options.renderer,
        outputDir: (options.sessionDir as NSString).appendingPathComponent("frames"))
      try FileManager.default.createDirectory(atPath: request.outputDir, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(request)
      try data.write(to: URL(fileURLWithPath: requestPath), options: .atomic)

      let response = try waitForResponse(seq: seq, timeout: 30)
      guard response.ok else {
        emit(Event(event: "error", phase: "rendering", message: response.error ?? "render failed"))
        return false
      }
      var e = Event(event: "frame")
      e.file = fileKey
      e.previews = response.previews
      e.selected = response.selected
      e.png = response.png
      e.jpeg = response.jpeg
      e.width = response.width
      e.height = response.height
      e.reload = reason
      e.seq = seq
      e.renderer = response.renderer
      e.rendererMode = options.renderer
      e.rendererReason = response.rendererReason
      let stripStart = Date()
      if let png = response.png, let w = response.width, let h = response.height {
        let dir = (png as NSString).deletingLastPathComponent
        var source = (png: png, width: w, height: h)
        // The bezel goes on the pane's strips only: `png`, which agents read,
        // stays the bare screen.
        if options.deviceFrame, let type = (host as? SimulatorHost)?.deviceType,
           let chrome = DeviceChrome.load(deviceType: type) {
          let framed = (dir as NSString).appendingPathComponent("frame-\(seq)-device.png")
          if let size = chrome.frame(png: png, pointWidth: w, pointHeight: h, scale: 2, output: framed) {
            source = (framed, size.width, size.height)
            e.stripWidth = size.width
          }
        }
        e.strips = FrameStrips.make(
          png: source.png, pointWidth: source.width, pointHeight: source.height,
          outputDir: dir, name: "frame-\(seq)")
      }
      e.timings = ["compile": compileSeconds, "load": (response.loadMs ?? 0) / 1000, "render": (response.renderMs ?? 0) / 1000,
                  "strips": Date().timeIntervalSince(stripStart)]
      emit(e)
      return true
    } catch let error as CompileError {
      if allowRebuild, Self.isStaleBuildError(error.summary) {
        status("rebuilding", "the compiler could not use the last build's modules; rebuilding")
        do {
          try fullBuild()
          return render(reason: "rebuild", allowRebuild: false)
        } catch {
          emit(Event(event: "error", phase: "building", message: "\(error)"))
          return false
        }
      }
      var e = Event(event: "error", phase: "compiling", message: error.summary)
      e.file = fileKey
      emit(e)
    } catch {
      emit(Event(event: "error", phase: "session", message: "\(error)"))
    }
    return false
  }

  var requestPath: String { (options.sessionDir as NSString).appendingPathComponent("request.json") }
  var responsePath: String { (options.sessionDir as NSString).appendingPathComponent("response.json") }
  var controlPath: String { (options.sessionDir as NSString).appendingPathComponent("control.json") }

  func waitForResponse(seq: Int, timeout: TimeInterval) throws -> RenderResponse {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let data = FileManager.default.contents(atPath: responsePath),
         let r = try? JSONDecoder().decode(RenderResponse.self, from: data), r.seq == seq {
        return r
      }
      if let host, !host.isRunning {
        let log = (try? String(contentsOfFile: (options.sessionDir as NSString).appendingPathComponent("host.log"), encoding: .utf8)) ?? ""
        throw ToolError("the preview host exited:\n" + lastLines(log, 20))
      }
      usleep(30_000)
    }
    throw ToolError("the preview host did not answer within \(Int(timeout))s (see \(options.sessionDir)/host.log)")
  }

  // MARK: Watch loop

  /// Builds, renders, then hot reloads on every save until `quit`.
  public func serve(commands: CommandQueue) {
    // A command left in control.json was for an earlier process (often the
    // `quit` that stopped it): never replay it, or every restart quits at once.
    try? FileManager.default.removeItem(atPath: controlPath)
    try? FileManager.default.removeItem(atPath: inboxDir)
    try? FileManager.default.createDirectory(atPath: options.sessionDir, withIntermediateDirectories: true)
    eventLog = EventLog(sessionDir: options.sessionDir)
    live = LiveSession(
      pid: getpid(), workspace: options.workspace.root, host: options.host,
      sessionDir: options.sessionDir, file: options.file, platform: options.platform,
      ancestors: Processes.ancestors(of: getpid()))
    publish()
    defer { live?.remove() }
    do {
      try fullBuild()
    } catch {
      emit(Event(event: "error", phase: "building", message: "\(error)"))
    }
    publish()
    if compiler != nil { render(reason: "initial") }
    status("watching", "watching \(moduleBySource.count) source files")

    var pendingSince: Date?
    while true {
      for command in commands.drain() + readControlFile() + readInbox() {
        if handle(command) { return }
      }
      if compiler == nil { usleep(250_000); continue }
      var dirty = false
      for path in moduleBySource.keys {
        let m = mtime(path)
        if m != mtimes[path] { mtimes[path] = m; dirty = true }
      }
      if dirty { pendingSince = Date() }
      if let since = pendingSince, Date().timeIntervalSince(since) > 0.12 {
        pendingSince = nil
        render(reason: "hot")
        status("watching", nil)
      }
      usleep(120_000)
    }
  }

  /// Returns true to quit.
  func handle(_ c: Command) -> Bool {
    switch c.cmd {
    case "quit":
      try? FileManager.default.removeItem(atPath: controlPath)
      host?.terminate()
      emit(Event(event: "exit"))
      return true
    case "select":
      options.preview = c.preview ?? 0
      render(reason: "select")
    case "open":
      if let f = c.file {
        options.file = standardized(f)
        options.preview = c.preview ?? 0
        if moduleBySource[options.file] == nil {
          do { try fullBuild() } catch { emit(Event(event: "error", phase: "building", message: "\(error)")); return false }
        }
        publish()
        render(reason: "open")
      }
    case "scheme":
      options.colorScheme = c.value
      render(reason: "scheme")
    case "renderer":
      guard let v = c.value, ["auto", "swiftui", "window"].contains(v) else {
        emit(Event(event: "error", phase: "command", message: "renderer must be auto, swiftui or window"))
        return false
      }
      options.renderer = v
      render(reason: "renderer")
    case "device":
      guard let v = c.value, !v.isEmpty else {
        emit(Event(event: "error", phase: "command", message: "device needs a simulator name or UDID"))
        return false
      }
      do {
        try switchDevice(v)
        render(reason: "device")
      } catch {
        emit(Event(event: "error", phase: "launching", message: "\(error)"))
      }
    case "devices":
      emitHost()
    case "size":
      options.width = c.width
      options.height = c.height
      render(reason: "size")
    case "rebuild":
      do { try fullBuild(); render(reason: "rebuild") } catch {
        emit(Event(event: "error", phase: "building", message: "\(error)"))
      }
    case "refresh":
      render(reason: "refresh")
    default:
      emit(Event(event: "error", phase: "command", message: "unknown command \(c.cmd)"))
    }
    status("watching", nil)
    return false
  }

  var inboxDir: String { (options.sessionDir as NSString).appendingPathComponent("inbox") }

  /// Commands other clients queued in `<session>/inbox`, oldest first.
  func readInbox() -> [Command] {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: inboxDir)) ?? [])
      .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
    var out: [Command] = []
    for name in names {
      let path = (inboxDir as NSString).appendingPathComponent(name)
      if let data = FileManager.default.contents(atPath: path), let c = try? JSONDecoder().decode(Command.self, from: data) {
        out.append(c)
      }
      try? FileManager.default.removeItem(atPath: path)
    }
    return out
  }

  func readControlFile() -> [Command] {
    guard let data = FileManager.default.contents(atPath: controlPath),
          let c = try? JSONDecoder().decode(Command.self, from: data) else { return [] }
    if let id = c.id {
      if id == lastControlID { return [] }
      lastControlID = id
    } else {
      try? FileManager.default.removeItem(atPath: controlPath)
    }
    return [c]
  }

  func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  public func shutdown() { host?.terminate() }
}

func standardized(_ path: String) -> String {
  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

public final class CommandQueue: @unchecked Sendable {
  private var items: [Command] = []
  private let lock = NSLock()
  public init() {}
  public func push(_ c: Command) { lock.lock(); items.append(c); lock.unlock() }
  func drain() -> [Command] { lock.lock(); defer { items = []; lock.unlock() }; return items }
}
