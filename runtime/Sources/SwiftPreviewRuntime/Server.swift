import Foundation
import ImageIO
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Mirrors RenderRequest / RenderResponse in tools/swiftpreview (Host.swift).
struct RenderRequest: Codable {
  /// Which swiftpreview run sent it: a host kept warm between runs sees
  /// numbering start again.
  var run: String?
  var seq: Int
  var dylibs: [String]
  var file: String
  var preview: Int
  var colorScheme: String?
  var width: Double?
  var height: Double?
  var renderer: String?
  var outputDir: String
}

struct RenderResponse: Codable {
  struct Preview: Codable { var name: String; var line: Int }
  var run: String?
  var seq: Int
  var ok: Bool
  var error: String?
  var previews: [Preview] = []
  var selected: Int = 0
  var png: String?
  var jpeg: String?
  var width: Double?
  var height: Double?
  var loadMs: Double?
  var renderMs: Double?
  var renderer: String?
  var rendererReason: String?
}

/// A captured frame and how it was drawn.
struct Capture {
  var png: Data
  var jpeg: Data
  var size: CGSize
  /// `swiftui` (ImageRenderer) or `window` (snapshot of the host window).
  var renderer: String
  /// Why this renderer, when it was not simply the one asked for.
  var reason: String?
}

/// Polls `<session>/request.json`, loads thunk dylibs, shows the requested
/// preview and writes `<session>/response.json` with the rendered frame.
@MainActor
public final class PreviewServer {
  public static let shared = PreviewServer()

  let sessionDir: String?
  var lastRequest = ""
  var lastLifeCheck = Date.distantPast
  var loaded: [String: UnsafeMutableRawPointer] = [:]
  var timer: Timer?
  /// The display: set by the platform host.
  var present: ((AnyView, PreviewLayout, CGSize?, ColorScheme?) -> Void)?
  /// Captures the current display. Takes the requested renderer
  /// (`auto`, `swiftui` or `window`).
  var capture: ((String) -> Capture?)?

  init() {
    sessionDir = ProcessInfo.processInfo.environment["SWIFTPREVIEW_SESSION"]
  }

  public func start() {
    guard sessionDir != nil, timer == nil else {
      if sessionDir == nil { print("swiftpreview: SWIFTPREVIEW_SESSION is not set; idle") }
      return
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
      MainActor.assumeIsolated { PreviewServer.shared.poll() }
    }
  }

  func poll() {
    #if os(macOS)
    // swiftpreview started this process; when it goes, so does the host.
    if getppid() == 1 { exit(0) }
    #endif
    if Date().timeIntervalSince(lastLifeCheck) >= 1 {
      lastLifeCheck = Date()
      checkLife()
    }
    guard let dir = sessionDir,
          let data = FileManager.default.contents(atPath: dir + "/request.json"),
          let request = try? JSONDecoder().decode(RenderRequest.self, from: data),
          "\(request.run ?? ""):\(request.seq)" != lastRequest
    else { return }
    lastRequest = "\(request.run ?? ""):\(request.seq)"
    handle(request)
  }

  /// Says this host is up (`host.alive`), and exits once nothing wants it:
  /// no swiftpreview heartbeat (`serve.alive`) for 10 s and no `keep-until`
  /// deadline ahead. A host whose serve stopped stays warm until that
  /// deadline, so the next run in the same folder skips the launch.
  func checkLife() {
    guard let dir = sessionDir else { return }
    let fm = FileManager.default
    fm.createFile(atPath: dir + "/host.alive", contents: Data("\(getpid())".utf8))
    func age(_ name: String) -> TimeInterval? {
      (try? fm.attributesOfItem(atPath: dir + "/" + name)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
    }
    // Older swiftpreview runs write no heartbeat: then never exit on our own.
    guard let served = age("serve.alive") else { return }
    if served < 10 { return }
    if let text = fm.contents(atPath: dir + "/keep-until").flatMap({ String(data: $0, encoding: .utf8) }),
       let until = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
       Date().timeIntervalSince1970 < until { return }
    try? fm.removeItem(atPath: dir + "/host.alive")
    exit(0)
  }

  func handle(_ request: RenderRequest) {
    var response = RenderResponse(run: request.run, seq: request.seq, ok: false)
    let loadStart = Date()
    for path in request.dylibs where loaded[path] == nil {
      guard let handle = dlopen(path, RTLD_NOW) else {
        response.error = "dlopen failed: " + String(cString: dlerror())
        write(response)
        return
      }
      loaded[path] = handle
      if let sym = dlsym(handle, "swiftpreview_register") {
        typealias Register = @convention(c) () -> Void
        unsafeBitCast(sym, to: Register.self)()
      }
    }
    response.loadMs = Date().timeIntervalSince(loadStart) * 1000

    let entries = PreviewRegistry.files[request.file] ?? []
    response.previews = entries.map { .init(name: $0.name, line: $0.line) }
    guard !entries.isEmpty else {
      response.error = "no previews registered for \(request.file)"
      write(response)
      return
    }
    let index = min(max(request.preview, 0), entries.count - 1)
    response.selected = index
    let entry = entries[index]
    let renderStart = Date()
    let size = request.width.flatMap { w in request.height.map { CGSize(width: w, height: $0) } }
    let scheme: ColorScheme? = request.colorScheme == "dark" ? .dark : request.colorScheme == "light" ? .light : nil
    present?(entry.make(), entry.layout, size, scheme)

    // Let SwiftUI lay out and draw (and run onAppear) before capturing.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
      MainActor.assumeIsolated {
        guard let shot = self.capture?(request.renderer ?? "auto") else {
          response.error = "capture failed"
          self.write(response)
          return
        }
        try? FileManager.default.createDirectory(atPath: request.outputDir, withIntermediateDirectories: true)
        let png = request.outputDir + "/frame-\(request.seq).png"
        let jpeg = request.outputDir + "/frame-\(request.seq).jpg"
        do {
          try shot.png.write(to: URL(fileURLWithPath: png))
          try shot.jpeg.write(to: URL(fileURLWithPath: jpeg))
        } catch {
          response.error = "writing frame: \(error)"
          self.write(response)
          return
        }
        response.ok = true
        response.png = png
        response.jpeg = jpeg
        response.width = shot.size.width
        response.height = shot.size.height
        response.renderer = shot.renderer
        response.rendererReason = shot.reason
        response.renderMs = Date().timeIntervalSince(renderStart) * 1000
        self.write(response)
      }
    }
  }

  func write(_ response: RenderResponse) {
    guard let dir = sessionDir, let data = try? JSONEncoder().encode(response) else { return }
    try? data.write(to: URL(fileURLWithPath: dir + "/response.json"), options: .atomic)
  }
}

/// Reduces a frame to a JPEG small enough for a pane (< ~90 KB).
func thumbnailJPEG(_ image: CGImage) -> Data {
  let maxSide = 720.0
  let scale = min(1, maxSide / Double(max(image.width, image.height)))
  let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
  guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.interpolationQuality = .high
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  guard let small = ctx.makeImage() else { return Data() }
  var quality = 0.75
  while true {
    let data = encode(small, type: "public.jpeg", quality: quality)
    if data.count < 90_000 || quality < 0.25 { return data }
    quality -= 0.15
  }
}

func encode(_ image: CGImage, type: String, quality: Double? = nil) -> Data {
  let data = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return Data() }
  var props: [CFString: Any] = [:]
  if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
  CGImageDestinationAddImage(dest, image, props as CFDictionary)
  CGImageDestinationFinalize(dest)
  return data as Data
}
