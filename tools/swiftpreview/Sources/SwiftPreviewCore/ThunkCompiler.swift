import Foundation

/// Compiles thunk files for one module into a dylib the host can `dlopen`.
public struct ThunkCompiler: Sendable {
  public var execRoot: String
  public var developerDir: String
  /// Every module directory in the host, so any import resolves.
  public var moduleDirs: [String]

  public init(execRoot: String, developerDir: String, moduleDirs: [String]) {
    self.execRoot = execRoot
    self.developerDir = developerDir
    self.moduleDirs = moduleDirs
  }

  public static func activeDeveloperDir() -> String {
    if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !d.isEmpty { return d }
    let r = try? Shell.run(["xcode-select", "-p"])
    return r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/Applications/Xcode.app/Contents/Developer"
  }

  static func sdkName(for target: String) -> String {
    if target.contains("ios") { return target.hasSuffix("simulator") ? "iphonesimulator" : "iphoneos" }
    if target.contains("tvos") { return target.hasSuffix("simulator") ? "appletvsimulator" : "appletvos" }
    if target.contains("watchos") { return target.hasSuffix("simulator") ? "watchsimulator" : "watchos" }
    if target.contains("xros") || target.contains("visionos") { return target.hasSuffix("simulator") ? "xrsimulator" : "xros" }
    return "macosx"
  }

  func sdkPath(for target: String) -> String {
    let r = try? Shell.run(["xcrun", "--sdk", Self.sdkName(for: target), "--show-sdk-path"], env: ["DEVELOPER_DIR": developerDir])
    return r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func resolve(_ s: String, sdk: () -> String) -> String {
    var s = s
    if s.contains("__BAZEL_XCODE_SDKROOT__") { s = s.replacingOccurrences(of: "__BAZEL_XCODE_SDKROOT__", with: sdk()) }
    if s.contains("__BAZEL_XCODE_DEVELOPER_DIR__") { s = s.replacingOccurrences(of: "__BAZEL_XCODE_DEVELOPER_DIR__", with: developerDir) }
    return s
  }

  public struct Output: Sendable {
    public var dylib: String
    public var seconds: Double
  }

  /// `thunks` are absolute paths. Throws `CompileError` with the compiler's
  /// diagnostics on failure.
  public func compile(module: ModuleCompile, thunks: [String], outputDir: String, serial: Int) throws -> Output {
    let start = Date()
    var sdkCache: String?
    let sdk = { () -> String in
      if let s = sdkCache { return s }
      let s = sdkPath(for: module.target); sdkCache = s; return s
    }
    let thunkModule = "\(module.moduleName)_Preview\(serial)"
    let dylib = (outputDir as NSString).appendingPathComponent("lib\(thunkModule).dylib")
    var swiftc = resolve(module.swiftc, sdk: sdk)
    if !swiftc.hasPrefix("/") { swiftc = "swiftc" }
    var argv: [String] = swiftc == "swiftc" ? ["xcrun", "swiftc"] : [swiftc]
    argv += module.flags.map { resolve($0, sdk: sdk) }
    for dir in moduleDirs { argv += ["-I", dir] }
    argv += [
      "-emit-library", "-parse-as-library",
      "-module-name", thunkModule,
      "-o", dylib,
      "-Onone",
      "-Xfrontend", "-enable-private-imports",
      "-Xfrontend", "-enable-dynamic-replacement-chaining",
      "-Xfrontend", "-disable-previous-implementation-calls-in-dynamic-replacements",
      "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
      "-Xlinker", "-no_deduplicate",
    ]
    argv += thunks
    var env = module.environment.mapValues { resolve($0, sdk: sdk) }
    env["DEVELOPER_DIR"] = env["DEVELOPER_DIR"] ?? developerDir
    let r = try Shell.run(argv, cwd: execRoot, env: env)
    guard r.status == 0 else {
      throw CompileError(module: module.moduleName, diagnostics: r.stderr + r.stdout, command: argv)
    }
    return Output(dylib: dylib, seconds: Date().timeIntervalSince(start))
  }
}

public struct CompileError: Error, CustomStringConvertible {
  public var module: String
  public var diagnostics: String
  public var command: [String]
  public var description: String { "Thunk compile for \(module) failed:\n\(diagnostics)" }
  /// Only the `error:` lines and the line after each, for compact display.
  public var summary: String {
    let lines = diagnostics.split(separator: "\n", omittingEmptySubsequences: false)
    var out: [String] = []
    for (i, l) in lines.enumerated() where l.contains("error:") {
      out.append(String(l))
      if out.count > 12 { break }
      _ = i
    }
    return out.isEmpty ? lastLines(diagnostics, 15) : out.joined(separator: "\n")
  }
}
