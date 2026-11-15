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
