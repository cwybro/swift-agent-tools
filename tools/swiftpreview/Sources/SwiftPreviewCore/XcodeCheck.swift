import Foundation

/// Bazel detects Xcode once, in the `local_config_xcode` repository, and keeps
/// the answer across Xcode installs, upgrades and `xcode-select` switches.
/// A stale answer fails analysis (for example `configurable attribute "actual"
/// in …system_sdk//:implicit_modules doesn't match this configuration`) or
/// quietly builds with the old Xcode. Re-fetching that one repository fixes it
/// in a couple of seconds and keeps the build cache; no `clean --expunge`.
public enum XcodeCheck {
  /// What Bazel cached: the default Xcode's build version (e.g. `27B52`), or
  /// `nil` when it found no Xcode.
  public struct Cached: Equatable {
    public var repo: String
    public var defaultBuild: String?
    public var locatorFailed: Bool
  }

  /// Reads `<output_base>/external/*local_config_xcode/BUILD`; nil before the
  /// first build.
  public static func cached(outputBase: String) -> Cached? {
    let external = (outputBase as NSString).appendingPathComponent("external")
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: external),
          let repo = names.first(where: { $0.hasSuffix("local_config_xcode") }),
          let text = try? String(contentsOfFile: "\(external)/\(repo)/BUILD", encoding: .utf8)
    else { return nil }
    return parse(text, repo: repo)
  }

  static func parse(_ text: String, repo: String) -> Cached {
    // `default = ':version27_2_0_27B52'`: the build version is the last part.
    var build: String?
    if let r = text.range(of: #"default = ':version[^']*'"#, options: .regularExpression) {
      let label = text[r].dropFirst("default = ':".count).dropLast()
      build = label.split(separator: "_").last.map(String.init)
    }
    return Cached(repo: repo, defaultBuild: build, locatorFailed: text.contains("xcode-locator failed"))
  }

  /// The selected Xcode's build version, from `<Xcode.app>/Contents/version.plist`;
  /// nil when only the Command Line Tools are selected.
  public static func activeBuild(developerDir: String) -> (name: String, build: String)? {
    guard let r = developerDir.range(of: ".app/Contents/Developer") else { return nil }
    let contents = String(developerDir[..<r.lowerBound]) + ".app/Contents"
    guard let data = FileManager.default.contents(atPath: contents + "/version.plist"),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let build = plist["ProductBuildVersion"] as? String
    else { return nil }
    let version = plist["CFBundleShortVersionString"] as? String ?? ""
    return ("Xcode \(version)", build)
  }

  /// Why the cached detection no longer matches the selected Xcode, or nil.
  public static func staleReason(cached: Cached, active: (name: String, build: String)?) -> String? {
    guard let active else { return nil }  // Command Line Tools: nothing to compare.
    if cached.locatorFailed || cached.defaultBuild == nil {
      return "Bazel detected no Xcode (it ran before \(active.name) was installed or selected)"
    }
    if cached.defaultBuild != active.build {
      return "Bazel cached Xcode build \(cached.defaultBuild!), but \(active.name) (\(active.build)) is selected"
    }
    return nil
  }

  /// Build errors that a stale Xcode detection causes.
  public static func isStaleXcodeError(_ text: String) -> Bool {
    (text.contains("implicit_modules") && text.contains("doesn't match this configuration"))
      || text.contains("xcode-locator")
      || text.contains("Xcode version must be specified")
  }
}

extension BazelWorkspace {
  /// Makes Bazel detect Xcode again (`bazel fetch --force --repo=@@<repo>`).
  public func refreshXcode(repo: String) throws {
    let r = try Shell.run(command("fetch", ["--force", "--repo=@@\(repo)"]), cwd: root)
    guard r.status == 0 else {
      throw ToolError(
        "refreshing Bazel's Xcode detection failed:\n\(lastLines(r.stderr, 15))\n" +
        "Running `bazel clean --expunge` in \(root) also fixes it (it discards the build cache).")
    }
  }
}
