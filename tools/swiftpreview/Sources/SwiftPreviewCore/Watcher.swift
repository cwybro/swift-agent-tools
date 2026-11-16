import CoreServices
import Foundation

/// A value behind a lock.
final class Locked<T>: @unchecked Sendable {
  private var value: T
  private let lock = NSLock()
  init(_ value: T) { self.value = value }
  func withLock<R>(_ body: (inout T) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

/// Notices changes through FSEvents on the watched packages (recursively):
/// no polling, whatever the number of files.
final class SourceWatcher: ChangeWatcher, @unchecked Sendable {
  let scope: WatchScope
  private var stream: FSEventStreamRef?
  private let changed = Locked(Set<String>())
  private let queue = DispatchQueue(label: "swiftpreview.watcher")

  /// nil when FSEvents cannot watch the folders.
  init?(scope: WatchScope) {
    self.scope = scope
    // The package folders cover their sources; a source outside any package
    // (rare) has its own folder watched.
    var roots = Set(scope.packages)
    for dir in scope.folders.keys where !scope.inPackage(dir) { roots.insert(dir) }
    let dirs = Array(roots).sorted()
    guard !dirs.isEmpty else { return nil }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let me = Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
      // Keep what can matter: watched sources, BUILD files, other `.swift`
      // files (added or removed). Classified after the debounce.
      let relevant = list.map { standardized($0) }.filter {
        me.scope.sources.contains($0) || WatchScope.isBuildFile($0) || $0.hasSuffix(".swift")
      }
      if !relevant.isEmpty { me.changed.withLock { $0.formUnion(relevant) } }
    }
    guard let stream = FSEventStreamCreate(
      // From when the scope was taken: an edit made since is replayed.
      nil, callback, &context, dirs as CFArray,
      scope.eventID == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : FSEventStreamEventId(scope.eventID), 0.05,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return nil
    }
  }

  func takeChanges() -> Set<String> {
    changed.withLock { value in
      defer { value = [] }
      return value
    }
  }

  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }
}
