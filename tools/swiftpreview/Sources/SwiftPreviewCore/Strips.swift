import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One horizontal slice of a frame, small enough for a pane's image element.
public struct FrameStrip: Codable, Sendable, Equatable {
  public var path: String
  /// `png` or `jpeg`.
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

  public static func make(
    png: String, pointWidth: Double, pointHeight: Double, scale: Double = 2,
    outputDir: String, name: String
  ) -> [FrameStrip] {
    guard pointWidth > 0, pointHeight > 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
          let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
    // Never upscale: a 1x capture stays 1x.
    let s = min(scale, Double(full.width) / pointWidth)
    let w = max(1, Int((pointWidth * s).rounded())), h = max(1, Int((pointHeight * s).rounded()))
    guard let image = resized(full, width: w, height: h) else { return [] }

    var strips: [FrameStrip] = []
    var y = 0
    var index = 0
    let rows = 512
    while y < h {
      let height = min(rows, h - y)
      emit(image, y: y, height: height, scale: s, outputDir: outputDir, name: name, index: &index, into: &strips)
      y += height
    }
    return strips
  }

  static func emit(
    _ image: CGImage, y: Int, height: Int, scale: Double, outputDir: String, name: String,
    index: inout Int, into strips: inout [FrameStrip]
  ) {
    guard let part = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) else { return }
    var chosen: (data: Data, format: String)?
    let png = encode(part, type: .png)
    if png.count <= budget {
      chosen = (png, "png")
    } else {
      for q in [0.92, 0.85, 0.78, 0.7] {
        let jpeg = encode(part, type: .jpeg, quality: q)
        if jpeg.count <= budget { chosen = (jpeg, "jpeg"); break }
      }
    }
    if chosen == nil, height >= 32 {
      // Keep halves on even rows so 2x strips stay whole points.
      let top = (height / 2) & ~1
      emit(image, y: y, height: top, scale: scale, outputDir: outputDir, name: name, index: &index, into: &strips)
      emit(image, y: y + top, height: height - top, scale: scale, outputDir: outputDir, name: name, index: &index, into: &strips)
      return
    }
    let (data, format) = chosen ?? (encode(part, type: .jpeg, quality: 0.5), "jpeg")
    let path = (outputDir as NSString).appendingPathComponent("\(name)-s\(index).\(format == "png" ? "png" : "jpg")")
    index += 1
    guard (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return }
    strips.append(FrameStrip(
      path: path, format: format, pixelWidth: part.width, pixelHeight: height, height: Double(height) / scale))
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
