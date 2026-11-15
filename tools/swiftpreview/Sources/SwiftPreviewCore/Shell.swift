import Foundation

public enum Shell {
  public struct Result: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
  }

  /// Runs `argv` (looked up on PATH) and waits. `onStderrLine` sees stderr as
  /// it arrives, line by line.
  @discardableResult
  public static func run(
    _ argv: [String], cwd: String? = nil, env: [String: String] = [:],
    onStderrLine: (@Sendable (String) -> Void)? = nil
  ) throws -> Result {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = argv
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice

    let outBuf = LockedData(), errBuf = LockedData()
    let pending = LockedData()
    out.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      if !d.isEmpty { outBuf.append(d) }
    }
    err.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      guard !d.isEmpty else { return }
      errBuf.append(d)
      if let onStderrLine {
        pending.append(d)
        for line in pending.takeLines() { onStderrLine(line) }
      }
    }
    try p.run()
    p.waitUntilExit()
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
    errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
    return Result(status: p.terminationStatus, stdout: outBuf.string, stderr: errBuf.string)
  }

  /// Starts `argv` without waiting; output goes to `logPath`.
  public static func spawn(_ argv: [String], cwd: String? = nil, env: [String: String] = [:], logPath: String) throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0].hasPrefix("/") ? argv[0] : "/usr/bin/env")
    p.arguments = argv[0].hasPrefix("/") ? Array(argv.dropFirst()) : argv
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    var environment = ProcessInfo.processInfo.environment
    for (k, v) in env { environment[k] = v }
    p.environment = environment
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let log = FileHandle(forWritingAtPath: logPath)
    p.standardOutput = log
    p.standardError = log
    p.standardInput = FileHandle.nullDevice
    try p.run()
    return p
  }
}

final class LockedData: @unchecked Sendable {
  private var data = Data()
  private let lock = NSLock()
  func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
  var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
  /// Removes and returns complete lines.
  func takeLines() -> [String] {
    lock.lock(); defer { lock.unlock() }
    guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
    let chunk = data[data.startIndex...last]
    data = Data(data[(last + 1)...])
    return String(decoding: chunk, as: UTF8.self).split(separator: "\n").map(String.init)
  }
}
