import CoreServices
import Foundation

/// Which Swift modules import which, from the compile commands alone: a
/// module depends on the modules whose output folders its compile searches
/// (`-I`), or that its explicit module map names. No Bazel query.
public struct ModuleGraph: Sendable {
  public let deps: [String: Set<String>]

  public init(_ compiles: [ModuleCompile], execRoot: String) {
    var byDir: [String: String] = [:]
    for c in compiles { if let dir = c.moduleDir { byDir[Self.clean(dir)] = c.moduleName } }
    var deps: [String: Set<String>] = [:]
    for c in compiles {
      var found = Set<String>()
      var i = 0
      while i < c.flags.count {
        let f = c.flags[i]
        var dir: String?
        if f == "-I", i + 1 < c.flags.count { dir = c.flags[i + 1]; i += 1 }
        else if f.hasPrefix("-I"), f.count > 2 { dir = String(f.dropFirst(2)) }
        if let dir, let m = byDir[Self.clean(dir)], m != c.moduleName { found.insert(m) }
        i += 1
      }
      if let map = c.moduleMapFile {
        let path = map.hasPrefix("/") ? map : (execRoot as NSString).appendingPathComponent(map)
        struct Entry: Decodable { var moduleName: String?; var modulePath: String? }
        if let data = FileManager.default.contents(atPath: path),
           let entries = try? JSONDecoder().decode([Entry].self, from: data) {
          for e in entries {
            if let name = e.moduleName, name != c.moduleName, compiles.contains(where: { $0.moduleName == name }) { found.insert(name) }
            if let p = e.modulePath, let m = byDir[Self.clean((p as NSString).deletingLastPathComponent)], m != c.moduleName { found.insert(m) }
          }
        }
      }
      deps[c.moduleName, default: []].formUnion(found)
    }
    self.deps = deps
  }

  init(deps: [String: Set<String>]) { self.deps = deps }

  static func clean(_ path: String) -> String {
    var p = path
    while p.hasSuffix("/") { p.removeLast() }
    if p.hasPrefix("./") { p.removeFirst(2) }
    return p
  }

  /// `module` and everything it imports, directly or not.
  public func closure(of module: String) -> Set<String> {
    var seen: Set<String> = [module]
    var stack = [module]
    while let m = stack.popLast() {
      for d in deps[m] ?? [] where seen.insert(d).inserted { stack.append(d) }
    }
    return seen
  }
}

/// What can change a preview: the sources of the previewed module and of the
/// modules it imports, and the Bazel packages they come from (whose BUILD
/// files and folders say which sources there are).
public struct WatchScope: Equatable, Sendable {
  public var modules: Set<String> = []
  public var sources: Set<String> = []
  /// Package folders: a BUILD file there, or a `.swift` file added or
  /// removed below, can change the modules.
  public var packages: Set<String> = []
  /// Each folder holding a watched source or a package, and the `.swift`
  /// files directly in it, to notice files added and removed.
  public var folders: [String: Set<String>] = [:]
  /// When it was taken: watchers report changes from then on, whenever they
  /// start (an edit made while the scope was being built is not lost).
  public var takenAt = Date()
  /// The FSEvents event id at that time, for an events watcher to replay from.
  public var eventID: UInt64 = 0

  public init() {}

  public init(modules: Set<String>, sources: Set<String>, root: String) {
    self.modules = modules
    self.sources = sources
    let fm = FileManager.default
    var packageOf: [String: String] = [:]
    func package(_ dir: String) -> String {
      if let hit = packageOf[dir] { return hit }
      var d = dir
      while d.count >= root.count {
        if fm.fileExists(atPath: d + "/BUILD.bazel") || fm.fileExists(atPath: d + "/BUILD") { break }
        let up = (d as NSString).deletingLastPathComponent
        if up == d { break }
        d = up
      }
      packageOf[dir] = d
      return d
    }
    for s in sources {
      let dir = (s as NSString).deletingLastPathComponent
      packages.insert(package(dir))
      folders[dir] = []
    }
    for p in packages { folders[p] = [] }
    eventID = FSEventsGetCurrentEventId()
    takenAt = Date()
    for dir in folders.keys { folders[dir] = Self.swiftFiles(in: dir) }
  }

  static func swiftFiles(in dir: String) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return Set(names.filter { $0.hasSuffix(".swift") }.map { (dir as NSString).appendingPathComponent($0) })
  }

  static func isBuildFile(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name == "BUILD" || name == "BUILD.bazel" || name.hasSuffix(".bzl")
  }

  /// Whether `path` lies in a watched package.
  func inPackage(_ path: String) -> Bool {
    packages.contains { path == $0 || path.hasPrefix($0 + "/") }
  }

  public enum Change: Equatable { case none, sources, structure(String) }

  /// What the changed paths mean, read against the disk now (after the
  /// debounce): a watched source edited, or the module layout changed (a
  /// BUILD file, or a `.swift` file added to or removed from a package).
  public func classify(_ paths: Set<String>) -> Change {
    let fm = FileManager.default
    var edited = false
    for raw in paths {
      let p = raw
      if sources.contains(p) {
        if fm.fileExists(atPath: p) { edited = true } else { return .structure("\((p as NSString).lastPathComponent) was removed") }
      } else if Self.isBuildFile(p), inPackage(p) {
        return .structure("\((p as NSString).lastPathComponent) changed in \((p as NSString).deletingLastPathComponent)")
      } else if p.hasSuffix(".swift"), inPackage(p), fm.fileExists(atPath: p) {
        return .structure("\((p as NSString).lastPathComponent) was added")
      }
    }
    return edited ? .sources : .none
  }
}

/// Reports the paths that may have changed since the last call.
protocol ChangeWatcher: AnyObject {
  var scope: WatchScope { get }
  func takeChanges() -> Set<String>
}

/// Checks modification times: each source, each package's BUILD files, and
/// each folder (whose time changes when a file is added, removed or saved
/// by renaming over it; its `.swift` files are then listed again).
final class PollWatcher: ChangeWatcher {
  let scope: WatchScope
  private var times: [String: Date?] = [:]
  private var listings: [String: Set<String>]

  /// `built`: the sources' modification times the last build saw. Sources
  /// differing from them, files modified since the scope was taken, and
  /// folders whose listing differs from the scope's count as changed on the
  /// first poll, so nothing between the scope and this watcher is missed.
  init(scope: WatchScope, built: [String: Date]) {
    self.scope = scope
    listings = scope.folders
    for p in watchedPaths {
      let m = Self.mtime(p)
      if scope.folders[p] != nil {
        times[p] = .some(nil)  // listed again on the first poll
      } else if scope.sources.contains(p) {
        let start: Date? = built[p] ?? m
        times[p] = .some(start)
      } else {
        // BUILD files: changed since the scope was taken counts.
        let changed = m.map { $0 > scope.takenAt } ?? false
        times[p] = .some(changed ? nil : m)
      }
    }
  }

  private var watchedPaths: [String] {
    Array(scope.sources) + Array(scope.folders.keys)
      + scope.packages.flatMap { [$0 + "/BUILD", $0 + "/BUILD.bazel"] }
  }

  static func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  func takeChanges() -> Set<String> {
    var changed = Set<String>()
    for p in watchedPaths {
      let m = Self.mtime(p)
      guard m != times[p] ?? nil else { continue }
      times[p] = m
      if let before = listings[p] {
        // A folder: which `.swift` files came or went.
        let now = WatchScope.swiftFiles(in: p)
        changed.formUnion(now.symmetricDifference(before))
        listings[p] = now
      } else {
        changed.insert(p)
      }
    }
    return changed
  }
}
