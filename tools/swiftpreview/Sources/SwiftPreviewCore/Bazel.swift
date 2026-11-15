import Foundation

/// How one Swift module was compiled by Bazel, recovered from `bazel aquery`
/// and stripped down to the flags a thunk compile can reuse.
public struct ModuleCompile: Codable, Sendable {
  public var moduleName: String
  /// `swiftc` (or a path to it), placeholders resolved.
  public var swiftc: String
  /// Reusable flags: target, SDK, search paths, module maps, defines, features.
  public var flags: [String]
  /// Sources, relative to the execution root (== workspace-relative for main
  /// repo files).
  public var sources: [String]
  /// Directory holding the built `.swiftmodule`, relative to the execroot.
  public var moduleDir: String?
  public var target: String
  public var environment: [String: String]
  public var configuration: String
}

public enum ArgumentCleaner {
  /// Flags dropped on their own.
  static let dropFlags: Set<String> = [
    "-emit-object", "-c", "-emit-module", "-enable-batch-mode", "-incremental",
    "-whole-module-optimization", "-wmo", "-no-whole-module-optimization", "-emit-dependencies",
    "-serialize-diagnostics", "-emit-objc-header", "-index-ignore-system-modules",
    "-avoid-emit-module-source-info", "-no-verify-emitted-module-interface",
    "-verify-emitted-module-interface", "-emit-module-interface", "-static",
    "-disable-implicit-swift-modules", "-enable-library-evolution", "-emit-tbd",
    "-parse-as-library", "-index-include-locals", "-explicit-module-build",
  ]
  /// Flags dropped with the value that follows them.
  static let dropFlagsWithValue: Set<String> = [
    "-output-file-map", "-emit-module-path", "-emit-const-values-path", "-module-name",
    "-index-store-path", "-emit-objc-header-path", "-num-threads", "-o",
    "-emit-module-interface-path", "-emit-private-module-interface-path",
    "-emit-module-source-info-path", "-explicit-swift-module-map-file", "-emit-tbd-path",
    "-emit-package-module-interface-path", "-package-name",
  ]
  /// `-Xfrontend` flags dropped on their own.
  static let dropFrontend: Set<String> = [
    "-internalize-at-link", "-color-diagnostics", "-disable-implicit-swift-modules",
    "-emit-module-semantic-info",
  ]
  /// `-Xfrontend` flags dropped with their (also `-Xfrontend`-prefixed) value.
  static let dropFrontendWithValue: Set<String> = [
    "-const-gather-protocols-file", "-explicit-swift-module-map-file",
  ]
  static let dropClang: Set<String> = ["-fno-implicit-modules", "-fno-implicit-module-maps"]

  public struct Result: Equatable {
    public var swiftc: String
    public var flags: [String]
    public var sources: [String]
    public var moduleName: String?
    public var moduleDir: String?
    public var target: String?
  }

  /// `arguments` is the full action command line: the worker, `swiftc`, flags.
  public static func clean(_ arguments: [String], paramFiles: [String: [String]] = [:]) -> Result {
    // Expand @params files.
    var args: [String] = []
    for a in arguments {
      if a.hasPrefix("@"), let expanded = paramFiles[String(a.dropFirst())] {
        args.append(contentsOf: expanded)
      } else {
        args.append(a)
      }
    }
    // Everything before swiftc is the worker wrapper.
    var swiftc = "swiftc"
    if let i = args.firstIndex(where: { ($0 as NSString).lastPathComponent == "swiftc" }) {
      swiftc = args[i]
      args = Array(args[(i + 1)...])
    } else if let first = args.first, !first.hasPrefix("-") {
      args = Array(args.dropFirst())
    }

    var flags: [String] = []
    var sources: [String] = []
    var moduleName: String?
    var moduleDir: String?
    var target: String?
    var i = 0
    func value(_ at: Int) -> String? { at < args.count ? args[at] : nil }
    while i < args.count {
      let a = args[i]
      if a.hasPrefix("-Xwrapped-swift=") { i += 1; continue }
      if a == "-module-name" { moduleName = value(i + 1); i += 2; continue }
      if a == "-emit-module-path", let v = value(i + 1) {
        moduleDir = (v as NSString).deletingLastPathComponent
        i += 2; continue
      }
      if a == "-target", let v = value(i + 1) { target = v }
      if dropFlags.contains(a) { i += 1; continue }
      if dropFlagsWithValue.contains(a) { i += 2; continue }
      if a == "-Xfrontend", let f = value(i + 1) {
        if dropFrontend.contains(f) { i += 2; continue }
        if dropFrontendWithValue.contains(f) {
          i += (value(i + 2) == "-Xfrontend") ? 4 : 3
          continue
        }
        flags.append(contentsOf: [a, f]); i += 2; continue
      }
      if a == "-Xcc", let f = value(i + 1) {
        if dropClang.contains(f) { i += 2; continue }
        flags.append(contentsOf: [a, f]); i += 2; continue
      }
      if !a.hasPrefix("-"), a.hasSuffix(".swift") {
        sources.append(a); i += 1; continue
      }
      flags.append(a)
      i += 1
    }
    return Result(swiftc: swiftc, flags: flags, sources: sources, moduleName: moduleName, moduleDir: moduleDir, target: target)
  }
}

// MARK: - aquery parsing

public enum AQuery {
  struct Output: Decodable {
    struct Action: Decodable {
      var mnemonic: String
      var configurationId: Int?
      var arguments: [String]?
      var environmentVariables: [KV]?
      var paramFiles: [ParamFile]?
    }
    struct KV: Decodable { var key: String; var value: String? }
    struct ParamFile: Decodable { var execPath: String; var arguments: [String]? }
    struct Configuration: Decodable { var id: Int; var mnemonic: String; var isTool: Bool? }
    var actions: [Action]?
    var configuration: [Configuration]?
  }

  /// Parses `bazel aquery --output=jsonproto --include_param_files` output into
  /// one compile per module, preferring target (non-exec) configurations.
  public static func parse(_ data: Data, platformHint: String?) throws -> [ModuleCompile] {
    let out = try JSONDecoder().decode(Output.self, from: data)
    let configs = Dictionary(uniqueKeysWithValues: (out.configuration ?? []).map { ($0.id, $0) })
    var byModule: [String: (score: Int, compile: ModuleCompile)] = [:]
    for action in out.actions ?? [] where action.mnemonic == "SwiftCompile" {
      guard let arguments = action.arguments else { continue }
      var params: [String: [String]] = [:]
      for p in action.paramFiles ?? [] { params[p.execPath] = p.arguments ?? [] }
      let cleaned = ArgumentCleaner.clean(arguments, paramFiles: params)
      guard let name = cleaned.moduleName else { continue }
      let config = action.configurationId.flatMap { configs[$0] }
      let configName = config?.mnemonic ?? ""
      var score = 0
      if config?.isTool == true || configName.contains("-exec") { score -= 10 }
      if let hint = platformHint, let target = cleaned.target {
        if target.contains(hint) { score += 5 }
      }
      var env: [String: String] = [:]
      for kv in action.environmentVariables ?? [] { env[kv.key] = kv.value ?? "" }
      let compile = ModuleCompile(
        moduleName: name, swiftc: cleaned.swiftc, flags: cleaned.flags, sources: cleaned.sources,
        moduleDir: cleaned.moduleDir, target: cleaned.target ?? "", environment: env, configuration: configName)
      if let existing = byModule[name], existing.score >= score { continue }
      byModule[name] = (score, compile)
    }
    return byModule.values.map(\.compile).sorted { $0.moduleName < $1.moduleName }
  }
}

extension AQuery {
  /// The OS in a target triple: `arm64-apple-ios17.0-simulator` → `ios`,
  /// `arm64-apple-macos14.0` (or `…-macosx14.0`) → `macos`.
  public static func platform(ofTriple triple: String) -> String? {
    let parts = triple.split(separator: "-")
    guard parts.count >= 3 else { return nil }
    let os = parts[2].prefix { $0.isLetter }.lowercased()
    switch os {
    case "": return nil
    case "macosx", "darwin": return "macos"
    default: return os
    }
  }

  /// The platform the host builds for: the most common OS among the
  /// target-configuration (non-exec) compiles.
  public static func hostPlatform(_ compiles: [ModuleCompile]) -> String? {
    var counts: [String: Int] = [:]
    for c in compiles where !c.configuration.contains("-exec") {
      if let p = platform(ofTriple: c.target) { counts[p, default: 0] += 1 }
    }
    return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
  }
}

// MARK: - Bazel workspace

public struct BazelWorkspace: Sendable {
  public var root: String
  public var bazel: String
  public var startupFlags: [String]
  public var buildFlags: [String]

  public init(root: String, bazel: String, startupFlags: [String] = [], buildFlags: [String] = []) {
    self.root = root
    self.bazel = bazel
    self.startupFlags = startupFlags
    self.buildFlags = buildFlags
  }

  public static func findRoot(from path: String) -> String? {
    var dir = URL(fileURLWithPath: path).standardizedFileURL
    if !FileManager.default.fileExists(atPath: dir.path + "/.") || !isDirectory(dir.path) {
      dir.deleteLastPathComponent()
    }
    while dir.path != "/" {
      for marker in ["MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel", "REPO.bazel"] {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(marker).path) { return dir.path }
      }
      dir.deleteLastPathComponent()
    }
    return nil
  }

  static func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }

  func command(_ verb: String, _ args: [String]) -> [String] {
    [bazel] + startupFlags + [verb] + args
  }

  public func info(_ key: String) throws -> String {
    let r = try Shell.run(command("info", buildFlags + [key]), cwd: root)
    guard r.status == 0 else { throw ToolError("bazel info \(key) failed:\n\(r.stderr)") }
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Streams Bazel's progress to `log`.
  public func build(_ targets: [String], log: @escaping @Sendable (String) -> Void) throws {
    let r = try Shell.run(command("build", buildFlags + ["--color=no", "--curses=no"] + targets), cwd: root, onStderrLine: log)
    guard r.status == 0 else { throw ToolError("bazel build failed:\n" + lastLines(r.stderr, 40)) }
  }

  public func outputFiles(_ target: String) throws -> [String] {
    let r = try Shell.run(command("cquery", buildFlags + ["--output=files", target]), cwd: root)
    guard r.status == 0 else { throw ToolError("bazel cquery failed:\n" + lastLines(r.stderr, 20)) }
    return r.stdout.split(separator: "\n").map(String.init)
  }

  public func swiftCompiles(host: String, platformHint: String?) throws -> [ModuleCompile] {
    let r = try Shell.run(command("aquery", buildFlags + ["mnemonic(\"SwiftCompile\", deps(\(host)))", "--output=jsonproto", "--include_param_files"]), cwd: root)
    guard r.status == 0 else { throw ToolError("bazel aquery failed:\n" + lastLines(r.stderr, 20)) }
    return try AQuery.parse(Data(r.stdout.utf8), platformHint: platformHint)
  }

  /// Finds `swiftui_preview_host` targets that depend on `file`.
  public func hostsFor(file: String) throws -> [String] {
    let rel = relative(file)
    let r = try Shell.run(command("query", ["kind(\"swiftui_preview_host\", rdeps(//..., \(rel)))", "--output=label"]), cwd: root)
    guard r.status == 0 else { return [] }
    return r.stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") || $0.hasPrefix("@") }
  }

  public func relative(_ path: String) -> String {
    let abs = URL(fileURLWithPath: path).standardizedFileURL.path
    let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path + "/"
    return abs.hasPrefix(rootPath) ? String(abs.dropFirst(rootPath.count)) : abs
  }
}

func lastLines(_ s: String, _ n: Int) -> String {
  s.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
}

public struct ToolError: Error, CustomStringConvertible {
  public var description: String
  public init(_ d: String) { description = d }
}
