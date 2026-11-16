import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SwiftPreviewCore

/// Writes a plain 402×874 pt screen at 3x, the iPhone 18 Pro's size.
func writeScreen(to path: String, color: CGColor) {
  let ctx = CGContext(
    data: nil, width: 1206, height: 2622, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.setFillColor(color)
  ctx.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

/// RGBA of one pixel, (0, 0) at the top left.
func pixel(_ path: String, _ x: Int, _ y: Int) -> [UInt8] {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
  let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  var out = [UInt8](repeating: 0, count: 4)
  let ctx = CGContext(
    data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
  return out
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: "/Library/Developer/DeviceKit/Chrome/phone11.devicechrome")))
func framesAnIPhoneScreenInItsBezel() throws {
  let chrome = try #require(DeviceChrome.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"))
  let dir = NSTemporaryDirectory() + "device-frame-\(getpid())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let screen = dir + "/screen.png", framed = dir + "/framed.png"
  writeScreen(to: screen, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))

  let size = try #require(chrome.frame(png: screen, pointWidth: 402, pointHeight: 874, scale: 2, output: framed))
  // The bezel (18 pt a side) and the side buttons widen it; the height is the bezel's.
  #expect(size.width > 402 + 36)
  #expect(size.height >= 874 + 36)

  let w = Int(size.width * 2), h = Int(size.height * 2)
  // Middle of the screen: the capture.
  let middle = pixel(framed, w / 2, h / 2)
  #expect(middle[0] > 200 && middle[1] < 80 && middle[2] < 80)
  // Inside the bezel's corner, outside the screen's rounded corner: not the capture.
  let corner = pixel(framed, (w - 402 * 2) / 2 + 4, (h - 874 * 2) / 2 + 4)
  #expect(corner[0] < 100)
  // The Dynamic Island, centered 29 pt below the top of the screen: black.
  #expect(pixel(framed, w / 2, (h - 874 * 2) / 2 + 58)[0...2] == [0, 0, 0])
  // Outside the phone: transparent.
  #expect(pixel(framed, 0, 0)[3] == 0)
  // The screen rect's own corner lies outside the bezel's rounded corner: nothing drawn there.
  #expect(pixel(framed, (w - 402 * 2) / 2 + 1, (h - 874 * 2) / 2 + 1)[3] == 0)

  // A size-to-fit preview isn't the full screen: no device around it.
  #expect(chrome.frame(png: screen, pointWidth: 402, pointHeight: 300, scale: 2, output: dir + "/compact.png") == nil)
  #expect(chrome.fillsScreen(width: 402, height: 874))
}

@Test func unknownDeviceTypesHaveNoChrome() {
  #expect(DeviceChrome.load(deviceType: "com.example.NoSuchDevice") == nil)
}

@Test func discoveryMapsSourceLabelsToPaths() {
  let ws = BazelWorkspace(root: "/ws", bazel: "bazel")
  #expect(ws.path(ofLabel: "//Features/Profile:ProfileView.swift") == "/ws/Features/Profile/ProfileView.swift")
  #expect(ws.path(ofLabel: "//:App.swift") == "/ws/App.swift")
  #expect(ws.path(ofLabel: "//Views:Sub/Card.swift") == "/ws/Views/Sub/Card.swift")
  #expect(ws.path(ofLabel: "@rules_swift//x:y.swift") == nil)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: "/Library/Developer/DeviceKit/Chrome/phone11.devicechrome")))
func cutsAFramedScreenIntoVectorSVGStrips() throws {
  let chrome = try #require(DeviceChrome.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"))
  let dir = ProcessInfo.processInfo.environment["SWIFTPREVIEW_STRIPS_OUT"] ?? NSTemporaryDirectory() + "device-strips-\(getpid())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let screen = dir + "/screen.png"
  writeScreen(to: screen, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))

  let (strips, width) = try #require(chrome.strips(png: screen, pointWidth: 402, pointHeight: 874, scale: 2, outputDir: dir, name: "frame-1"))
  let v = chrome.vector(pointWidth: 402, pointHeight: 874)
  #expect(abs(width - Double(v.size.width)) < 0.001)
  #expect(width > 402 + 36)
  // The slices cover the whole device, top to bottom.
  #expect(abs(strips.reduce(0) { $0 + $1.height } - v.size.height) < 0.01)
  for s in strips {
    #expect(s.format == "svg")
    let svg = try String(contentsOfFile: s.path, encoding: .utf8)
    // Each fits the pane's SVG element.
    #expect(svg.count <= 131_072)
    #expect(svg.hasPrefix("<svg"))
    // The bezel is vector paths, and the screen's slice an embedded image.
    // (stretched pieces are their cross-section: rects).
    #expect(svg.contains("<path") || svg.contains("<rect"))
    #expect(svg.contains("<image"))
  }
  // Each screen image runs past its slice's inner edges, so no image edge falls
  // on a slice boundary (a hairline at fractional zoom).
  var top = 0.0
  for (k, s) in strips.enumerated() {
    let svg = try String(contentsOfFile: s.path, encoding: .utf8)
    let image = try #require(svg.range(of: "<image ").map { String(svg[$0.upperBound...].prefix(200)) })
    func attr(_ name: String) -> Double? {
      image.range(of: "\(name)=\"").flatMap { r in Double(image[r.upperBound...].prefix { $0 != "\"" }) }
    }
    let y = try #require(attr("y")), h = try #require(attr("height"))
    if k > 0 { #expect(y < top, "image starts above slice \(k)") }
    if k < strips.count - 1 { #expect(y + h > top + s.height, "image ends below slice \(k)") }
    top += s.height
  }
  // The masked screen fills its whole layer: opaque red toward every edge, not
  // just the bottom-left quarter.
  let masked = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: dir + "/frame-1-screen.png") as CFURL, nil)
    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
  #expect(masked.width == 804 && masked.height == 1748)
  let ctx = try #require(CGContext(
    data: nil, width: masked.width, height: masked.height, bitsPerComponent: 8, bytesPerRow: masked.width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  ctx.draw(masked, in: CGRect(x: 0, y: 0, width: masked.width, height: masked.height))
  let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
  for (fx, fy) in [(0.9, 0.1), (0.1, 0.9), (0.9, 0.9), (0.5, 0.5)] {
    let i = (Int(fy * Double(masked.height)) * masked.width + Int(fx * Double(masked.width))) * 4
    #expect(px[i] > 200 && px[i + 3] > 200, "screen pixel at \(fx),\(fy)")
  }
  // The whole frame stays well within the pane's frame budget, at 2x.
  let total = try strips.reduce(0) { $0 + (try String(contentsOfFile: $1.path, encoding: .utf8)).count }
  #expect(total < FrameStrips.frameBudget / 2, "\(total) characters")
  // The Dynamic Island is drawn over the screen, as a vector shape.
  #expect(v.over.contains { $0.svg.contains("<rect") })
  #expect(chrome.strips(png: screen, pointWidth: 402, pointHeight: 300, scale: 2, outputDir: dir, name: "compact") == nil)
}

@Test("a busy screen's framed strips together stay within the pane's frame budget")
func keepsABusyFrameWithinTheFrameBudget() throws {
  let chrome = try #require(DeviceChrome.load(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"))
  let dir = NSTemporaryDirectory() + "device-busy-\(getpid())"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  // Coloured 4 pt tiles: PNG compresses them poorly, as it does a busy UI.
  let ctx = try #require(CGContext(
    data: nil, width: 1206, height: 2622, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  var seed: UInt64 = 42
  for ty in stride(from: 0, to: 2622, by: 12) {
    for tx in stride(from: 0, to: 1206, by: 12) {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      let v = Double(seed >> 40 & 0xFF) / 255
      ctx.setFillColor(CGColor(red: v, green: 1 - v, blue: 0.5, alpha: 1))
      ctx.fill(CGRect(x: tx, y: ty, width: 12, height: 12))
    }
  }
  let screen = dir + "/busy.png"
  let dest = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: screen) as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
  #expect(CGImageDestinationFinalize(dest))

  let (strips, _) = try #require(chrome.strips(png: screen, pointWidth: 402, pointHeight: 874, scale: 2, outputDir: dir, name: "busy"))
  let svgs = try strips.map { try String(contentsOfFile: $0.path, encoding: .utf8) }
  let total = svgs.reduce(0) { $0 + $1.count }
  #expect(total <= FrameStrips.frameBudget, "\(total) characters")
  // One format for the whole frame: no strip looks different from the next.
  let formats = Set(svgs.compactMap { svg in svg.range(of: "data:image/").map { String(svg[$0.upperBound...].prefix { $0 != ";" }) } })
  #expect(formats.count == 1, "\(formats)")
  let raster = FrameStrips.make(png: screen, pointWidth: 402, pointHeight: 874, outputDir: dir, name: "flat")
  let rasterTotal = raster.reduce(0) { total, s in
    total + 400 + ((try? FileManager.default.attributesOfItem(atPath: s.path)[.size] as? Int) ?? 0) * 4 / 3
  }
  #expect(rasterTotal <= FrameStrips.frameBudget, "\(rasterTotal) characters")
  #expect(Set(raster.map(\.format)).count == 1)
}
