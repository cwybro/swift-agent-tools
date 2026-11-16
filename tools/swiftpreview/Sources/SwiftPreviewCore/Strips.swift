import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One horizontal slice of a frame, small enough for a pane's image element.
public struct FrameStrip: Codable, Sendable, Equatable {
  public var path: String
  /// `png` or `jpeg`; `svg` for a device-framed strip: its slice of the vector
  /// bezel with the screen's slice embedded.
  public var format: String
  public var pixelWidth: Int
  public var pixelHeight: Int
  /// Height in points (the frame's width in points is the event's `width`).
  public var height: Double
}

/// Cuts a frame into strips for display at `scale` pixels per point.
///
/// Claude's desktop pane draws pictures through an SVG element capped at
/// 131,072 characters, so one base64 image can hold about 96 KB: too little
/// for a sharp phone-sized frame. Strips stacked without gaps can each stay
/// under that and together keep the full resolution. Each is a PNG when it
/// fits (crisp text), else the best-quality JPEG that fits; a strip that fits
/// in neither is split in two.
public enum FrameStrips {
  /// Bytes per strip: (131,072 − ~400 for the SVG wrapper) × 3/4 for base64.
  public static let budget = 96_000
  /// Characters of SVG for all of one frame's strips. The pane sends them in
  /// one update, and a frame of about 289K characters was never drawn (the
  /// pane stayed on the frame before) where one of 256K was. Every strip of a
  /// frame is a PNG when they all fit, else all JPEGs at one quality, else
  /// the frame is cut again at a lower scale, down to 1x.
  public static let frameBudget = 220_000

  public static func make(
    png: String, pointWidth: Double, pointHeight: Double, scale: Double = 2,
    outputDir: String, name: String, budget: Int = FrameStrips.budget, frameBudget: Int = FrameStrips.frameBudget
  ) -> [FrameStrip] {
    guard pointWidth > 0, pointHeight > 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    // Never upscale: a 1x capture stays 1x.
    let s = min(scale, Double(full.width) / pointWidth)
    let w = max(1, Int((pointWidth * s).rounded())), h = max(1, Int((pointHeight * s).rounded()))
    guard let image = resized(full, width: w, height: h) else { return [] }

    // About as many pixels per strip as a 512-row phone strip; even rows, so
    // 2x strips stay whole points.
    let rows = max(64, min(512, 512 * 804 / w)) & ~1
    var parts: [(image: CGImage, y: Int)] = []
    var y = 0
    while y < h {
      let height = min(rows, h - y)
      guard let part = image.cropping(to: CGRect(x: 0, y: y, width: w, height: height)) else { return [] }
      parts.append((part, y))
      y += height
    }
    let total = (frameBudget == .max ? Int.max : max(0, frameBudget - 400 * parts.count) * 3 / 4)
    guard let (datas, format) = encodeConsistently(parts.map(\.image), rooms: parts.map { _ in budget }, total: total) else {
      // Too busy even as JPEGs: fewer pixels, down to 1x; at 1x, the smallest JPEGs.
      if s > 1 {
        return make(png: png, pointWidth: pointWidth, pointHeight: pointHeight, scale: max(1, s * 0.75),
                    outputDir: outputDir, name: name, budget: budget, frameBudget: frameBudget)
      }
      return write(parts.map { (encode($0.image, type: .jpeg, quality: 0.5), $0.image.height) }, format: "jpeg",
                   scale: s, width: w, outputDir: outputDir, name: name)
    }
    return write(zip(datas, parts).map { ($0, $1.image.height) }, format: format, scale: s, width: w, outputDir: outputDir, name: name)
  }

  static func write(_ parts: [(Data, Int)], format: String, scale: Double, width: Int, outputDir: String, name: String) -> [FrameStrip] {
    var strips: [FrameStrip] = []
    for (k, (data, height)) in parts.enumerated() {
      let path = (outputDir as NSString).appendingPathComponent("\(name)-s\(k).\(format == "png" ? "png" : "jpg")")
      guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return [] }
      strips.append(FrameStrip(path: path, format: format, pixelWidth: width, pixelHeight: height, height: Double(height) / scale))
    }
    return strips
  }

  /// One format and quality for every part of a frame, so no strip looks
  /// different from its neighbours: PNGs when each fits its room and all fit
  /// `total` bytes, else JPEGs at the highest quality that does.
  static func encodeConsistently(_ parts: [CGImage], rooms: [Int], total: Int) -> (datas: [Data], format: String)? {
    func fits(_ datas: [Data]) -> Bool {
      zip(datas, rooms).allSatisfy { $0.count <= $1 } && datas.reduce(0) { $0 + $1.count } <= total
    }
    let pngs = parts.map { encode($0, type: .png) }
    if fits(pngs) { return (pngs, "png") }
    for q in [0.92, 0.85, 0.78, 0.7, 0.6, 0.5] {
      let jpegs = parts.map { encode($0, type: .jpeg, quality: q) }
      if fits(jpegs) { return (jpegs, "jpeg") }
    }
    return nil
  }

  static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    if image.width == width && image.height == height { return image }
    guard let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
  }

  static func encode(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return Data() }
    var props: [CFString: Any] = [:]
    if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
  }
}
