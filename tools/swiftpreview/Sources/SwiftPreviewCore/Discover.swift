import Foundation

/// Every preview a workspace can render: the `swiftui_preview_host` targets,
/// the workspace Swift files they build, and the previews in each file.
/// Bazel queries only (no build), then a syntax-only read of each file.
public struct Discovery: Codable, Sendable {
  public struct File: Codable, Sendable {
    public var file: String
    /// The Bazel workspace the file and its hosts are in.
    public var workspace: String
    /// Hosts that build the file (a preview needs one of them).
    public var hosts: [String]
    public var previews: [Preview]
  }
  public struct Preview: Codable, Sendable {
    public var index: Int
    public var name: String
    public var line: Int
  }

  /// The workspace searched, or the folder when several were.
  public var workspace: String
  /// Every workspace searched: the one holding the folder, and those below it.
  public var workspaces: [String] = []
  /// Host labels; prefixed with the workspace's path when there are several.
  public var hosts: [String]
  /// Files with at least one preview, by path.
  public var files: [File]
  /// Workspaces whose queries failed, with why.
  public var failures: [String: String]? = nil

  static let skipped: Set<String> = [".build", ".git", "node_modules", ".swiftpreview", "DerivedData", ".swiftpm"]

  /// The Bazel workspaces at or below `dir`: the one holding it, and nested
  /// ones (an examples folder, a monorepo's modules). `bazel-*` output links
  /// and build folders are skipped.
  public static func workspaces(from dir: String, maxDepth: Int = 6) -> [String] {
    var found: [String] = []
    if let root = BazelWorkspace.findRoot(from: dir) { found.append(root) }
    let fm = FileManager.default
    let base = URL(fileURLWithPath: dir).standardizedFileURL
    let baseDepth = base.pathComponents.count
    guard let walk = fm.enumerator(
      at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return found }
    for case let url as URL in walk {
      let name = url.lastPathComponent
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values?.isSymbolicLink == true || name.hasPrefix("bazel-") || skipped.contains(name)
        || url.pathComponents.count - baseDepth > maxDepth {
        walk.skipDescendants()
        continue
      }
      guard values?.isDirectory == true else { continue }
      if ["MODULE.bazel", "WORKSPACE", "WORKSPACE.bazel"].contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0).path) }) {
        found.append(url.path)
      }
    }
    var seen = Set<String>()
    return found.filter { seen.insert($0).inserted }
  }

  /// Every preview at or below `dir`, across nested workspaces.
  public static func find(from dir: String, bazel: String) -> Discovery {
    let roots = workspaces(from: dir)
    var all = Discovery(workspace: roots.count == 1 ? roots[0] : dir, workspaces: roots, hosts: [], files: [])
    var failures: [String: String] = [:]
    for root in roots {
      do {
        let d = try BazelWorkspace(root: root, bazel: bazel).discover()
        let prefix = roots.count > 1 ? (root == dir ? "" : relative(root, to: dir)) : ""
        all.hosts += d.hosts.map { prefix + $0 }
        all.files += d.files
      } catch {
        failures[root] = "\(error)"
      }
    }
    all.files.sort { $0.file < $1.file }
    if !failures.isEmpty { all.failures = failures }
    return all
  }

  static func relative(_ path: String, to dir: String) -> String {
    let d = dir.hasSuffix("/") ? dir : dir + "/"
    return path.hasPrefix(d) ? String(path.dropFirst(d.count)) : path
  }
}

extension BazelWorkspace {
  /// bazelisk when installed, else bazel.
  public static func preferredBazel() -> String {
    let r = try? Shell.run(["which", "bazelisk"])
    return r?.status == 0 ? "bazelisk" : "bazel"
  }

  /// The preview hosts in the workspace.
  public func previewHosts() throws -> [String] {
    let r = try Shell.run(command("query", ["kind(\"swiftui_preview_host\", //...)", "--output=label"]), cwd: root)
    guard r.status == 0 else { throw ToolError("bazel query for preview hosts failed:\n\(lastLines(r.stderr, 20))") }
    return r.stdout.split(separator: "\n").map(String.init).filter { $0.hasPrefix("//") }
  }

  /// The workspace's own Swift files that `host` builds, as absolute paths.
  public func swiftSources(of host: String) throws -> [String] {
    let q = "filter(\"\\.swift$\", kind(\"source file\", deps(\(host))))"
    let r = try Shell.run(command("query", [q, "--output=label"]), cwd: root)
    guard r.status == 0 else { throw ToolError("bazel query for \(host)'s sources failed:\n\(lastLines(r.stderr, 20))") }
    return r.stdout.split(separator: "\n").compactMap { path(ofLabel: String($0)) }
  }

  /// `//pkg/dir:Sub/File.swift` → `<root>/pkg/dir/Sub/File.swift`; nil for external labels.
  func path(ofLabel label: String) -> String? {
    guard label.hasPrefix("//") else { return nil }
    let body = label.dropFirst(2)
    let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    let pkg = parts.first.map(String.init) ?? ""
    let name = parts.count > 1 ? String(parts[1]) : (pkg as NSString).lastPathComponent
    return ([root, pkg, name].filter { !$0.isEmpty } as NSArray).componentsJoined(by: "/")
  }

  /// Every renderable preview in the workspace.
  public func discover() throws -> Discovery {
    let hosts = try previewHosts()
    var hostsByFile: [String: [String]] = [:]
    for host in hosts {
      for file in try swiftSources(of: host) { hostsByFile[file, default: []].append(host) }
    }
    var files: [Discovery.File] = []
    for (file, fileHosts) in hostsByFile.sorted(by: { $0.key < $1.key }) {
      guard let a = try? SourceAnalyzer.analyze(path: file), !a.previews.isEmpty else { continue }
      files.append(Discovery.File(
        file: file, workspace: root, hosts: fileHosts,
        previews: a.previews.map { Discovery.Preview(index: $0.index, name: $0.displayName, line: $0.line) }))
    }
    return Discovery(workspace: root, workspaces: [root], hosts: hosts, files: files)
  }
}
