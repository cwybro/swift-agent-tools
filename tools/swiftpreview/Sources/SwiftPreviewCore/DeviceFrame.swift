import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Simulator's own device artwork, read from Xcode's install, to draw an
/// iOS frame inside a phone (or iPad) bezel the way Simulator shows it.
///
/// Each simulator device type names a chrome
/// (`/Library/Developer/DeviceKit/Chrome/<name>.devicechrome`): a nine-slice
/// bezel and the side buttons as PDFs, placed by its `chrome.json`, plus a
/// screen mask PDF for the rounded display corners. Nothing is copied into
/// this repository; a machine without the files gets an unframed picture.
public final class DeviceChrome: @unchecked Sendable {
  struct Input {
    var page: CGPDFPage
    var anchor: String  // left | right | top | bottom
    var align: String  // leading | trailing | center
    var x: Double
    var y: Double
    var onTop: Bool
  }

  /// Bezel pieces by role: topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left.
  let pieces: [String: CGPDFPage]
  /// Bezel thickness around the screen, in points.
  let left: Double, right: Double, top: Double, bottom: Double
  let inputs: [Input]
  /// The display's shape (rounded corners); square without one, as on home-button devices.
  let screenMask: CGPDFPage?
  /// Draw a Dynamic Island: iOS draws it, so a window snapshot lacks it.
  let island: Bool
  /// The display in points: only a frame this size is a full screen.
  let screen: CGSize?

  init(pieces: [String: CGPDFPage], insets: (Double, Double, Double, Double), inputs: [Input],
       screenMask: CGPDFPage?, island: Bool, screen: CGSize?) {
    self.pieces = pieces
    (left, right, top, bottom) = insets
    self.inputs = inputs
    self.screenMask = screenMask
    self.island = island
    self.screen = screen
  }

  static let chromeDir = "/Library/Developer/DeviceKit/Chrome"
  nonisolated(unsafe) static var cache: [String: DeviceChrome?] = [:]
  static let lock = NSLock()

  /// The chrome for a simulator device type identifier
  /// (`com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro`), or nil.
  public static func load(deviceType: String) -> DeviceChrome? {
    lock.lock(); defer { lock.unlock() }
    if let hit = cache[deviceType] { return hit }
    let chrome = read(deviceType: deviceType)
    cache[deviceType] = chrome
    return chrome
  }

  static func page(_ path: String) -> CGPDFPage? {
    CGPDFDocument(URL(fileURLWithPath: path) as CFURL)?.page(at: 1)
  }

  static func read(deviceType: String) -> DeviceChrome? {
    // Device type bundle → profile.plist → chrome name, mask, sensor bar.
    guard let r = try? Shell.run(["xcrun", "simctl", "list", "devicetypes", "-j"]), r.status == 0,
          let list = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
          let types = list["devicetypes"] as? [[String: Any]],
          let bundle = types.first(where: { $0["identifier"] as? String == deviceType })?["bundlePath"] as? String
    else { return nil }
    let resources = bundle + "/Contents/Resources"
    guard let profileData = FileManager.default.contents(atPath: resources + "/profile.plist"),
          let profile = try? PropertyListSerialization.propertyList(from: profileData, format: nil) as? [String: Any],
          let chromeID = profile["chromeIdentifier"] as? String
    else { return nil }
    let chromeRes = "\(chromeDir)/\(chromeID.split(separator: ".").last ?? "").devicechrome/Contents/Resources"
    guard let jsonData = FileManager.default.contents(atPath: chromeRes + "/chrome.json"),
          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
          let images = json["images"] as? [String: Any],
          let sizing = images["sizing"] as? [String: Double]
    else { return nil }

    var pieces: [String: CGPDFPage] = [:]
    for role in ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left"] {
      guard let name = images[role] as? String, let p = page("\(chromeRes)/\(name).pdf") else { return nil }
      pieces[role] = p
    }

    var inputs: [Input] = []
    for i in json["inputs"] as? [[String: Any]] ?? [] {
      guard let name = i["image"] as? String, let p = page("\(chromeRes)/\(name).pdf"),
            let normal = (i["offsets"] as? [String: Any])?["normal"] as? [String: Double] else { continue }
      inputs.append(Input(
        page: p, anchor: i["anchor"] as? String ?? "left", align: i["align"] as? String ?? "leading",
        x: normal["x"] ?? 0, y: normal["y"] ?? 0, onTop: i["onTop"] as? Bool ?? false))
    }

    let mask = (profile["framebufferMask"] as? String).flatMap { page("\(resources)/\($0).pdf") }
    let l = sizing["leftWidth"] ?? 0
    // capabilities.plist → displays[0]: the main display in pixels and its scale.
    var screen: CGSize?
    if let data = FileManager.default.contents(atPath: resources + "/capabilities.plist"),
       let caps = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let display = ((caps["capabilities"] as? [String: Any])?["displays"] as? [[String: Any]])?.first,
       let w = display["width"] as? Double, let h = display["height"] as? Double,
       let scale = display["scale"] as? Double, scale > 0 {
      screen = CGSize(width: w / scale, height: h / scale)
    }
    // Sensor bar classes 04 and 05 are the Dynamic Island phones.
    let sensor = profile["sensorBarImage"] as? String ?? ""
    return DeviceChrome(
      pieces: pieces,
      insets: (l, sizing["rightWidth"] ?? 0, sizing["topHeight"] ?? 0, sizing["bottomHeight"] ?? 0),
      inputs: inputs, screenMask: mask,
      island: sensor.hasSuffix("_04") || sensor.hasSuffix("_05"), screen: screen)
  }

  static func size(_ p: CGPDFPage) -> CGSize { p.getBoxRect(.mediaBox).size }

  /// Where an input sits, with the screen at the origin and the bezel's
  /// outside edge at `outer` (points, y down). Offsets place the button's
  /// inner edge relative to the edge it is anchored to.
  func rect(_ i: Input, outer o: CGRect) -> CGRect {
    let s = Self.size(i.page)
    func along(_ lo: Double, _ hi: Double, _ length: Double, _ offset: Double) -> Double {
      switch i.align {
      case "trailing": return hi + offset - length
      case "center": return (lo + hi - length) / 2 + offset
      default: return lo + offset
      }
    }
    switch i.anchor {
    case "right": return CGRect(x: o.maxX + i.x, y: along(o.minY, o.maxY, s.height, i.y), width: s.width, height: s.height)
    case "top": return CGRect(x: along(o.minX, o.maxX, s.width, i.x), y: o.minY + i.y - s.height, width: s.width, height: s.height)
    case "bottom": return CGRect(x: along(o.minX, o.maxX, s.width, i.x), y: o.maxY + i.y, width: s.width, height: s.height)
    default: return CGRect(x: o.minX + i.x - s.width, y: along(o.minY, o.maxY, s.height, i.y), width: s.width, height: s.height)
    }
  }

  /// Whether a frame this size fills the display. Size-to-fit and fixed-size
  /// previews don't, and are shown without a device, as Xcode does.
  public func fillsScreen(width: Double, height: Double) -> Bool {
    guard let screen else { return false }
    return abs(screen.width - width) <= 1 && abs(screen.height - height) <= 1
  }

  /// Draws `png` (a full-screen capture, `pointWidth` × `pointHeight` points)
  /// inside the device at `scale` pixels per point and writes a PNG to
  /// `output`. Returns the framed size in points, or nil when the capture
  /// isn't the full screen.
  public func frame(png: String, pointWidth: Double, pointHeight: Double, scale: Double, output: String) -> CGSize? {
    guard fillsScreen(width: pointWidth, height: pointHeight) else { return nil }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
          let screen = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let screenRect = CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
    let outer = CGRect(x: -left, y: -top, width: pointWidth + left + right, height: pointHeight + top + bottom)
    var bounds = outer
    for i in inputs { bounds = bounds.union(rect(i, outer: outer)) }
    bounds = bounds.insetBy(dx: -2, dy: -2).integral

    let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
    guard let ctx = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // Points, y down, with the screen's top-left at the origin.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
    ctx.interpolationQuality = .high

    for i in inputs where !i.onTop { draw(i.page, in: rect(i, outer: outer), ctx) }
    // The bezel pieces are black inside, behind the screen's rounded corners.
    drawBezel(outer: outer, ctx)
    drawScreen(screen, in: screenRect, scale: scale, ctx)
    if island {
      ctx.setFillColor(CGColor(gray: 0, alpha: 1))
      let pill = CGRect(x: (pointWidth - 126) / 2, y: 11, width: 126, height: 37)
      ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 18.5, cornerHeight: 18.5, transform: nil))
      ctx.fillPath()
    }
    for i in inputs where i.onTop { draw(i.page, in: rect(i, outer: outer), ctx) }

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return CGSize(width: Double(w) / scale, height: Double(h) / scale)
  }

  /// The bezel's nine-slice rectangles, by piece, around `outer` (y down).
  func bezelRects(outer o: CGRect) -> [(CGPDFPage, CGRect)] {
    guard let tl = pieces["topLeft"], let tr = pieces["topRight"], let bl = pieces["bottomLeft"], let br = pieces["bottomRight"],
          let t = pieces["top"], let b = pieces["bottom"], let l = pieces["left"], let r = pieces["right"] else { return [] }
    let tls = Self.size(tl), trs = Self.size(tr), bls = Self.size(bl), brs = Self.size(br)
    return [
      (tl, CGRect(origin: CGPoint(x: o.minX, y: o.minY), size: tls)),
      (tr, CGRect(x: o.maxX - trs.width, y: o.minY, width: trs.width, height: trs.height)),
      (bl, CGRect(x: o.minX, y: o.maxY - bls.height, width: bls.width, height: bls.height)),
      (br, CGRect(x: o.maxX - brs.width, y: o.maxY - brs.height, width: brs.width, height: brs.height)),
      (t, CGRect(x: o.minX + tls.width, y: o.minY, width: o.width - tls.width - trs.width, height: Self.size(t).height)),
      (b, CGRect(x: o.minX + bls.width, y: o.maxY - Self.size(b).height, width: o.width - bls.width - brs.width, height: Self.size(b).height)),
      (l, CGRect(x: o.minX, y: o.minY + tls.height, width: Self.size(l).width, height: o.height - tls.height - bls.height)),
      (r, CGRect(x: o.maxX - Self.size(r).width, y: o.minY + trs.height, width: Self.size(r).width, height: o.height - trs.height - brs.height)),
    ]
  }

  /// The device as SVG pieces, in points with the frame's top-left at the
  /// origin: what goes under the screen (buttons, bezel) and over it (island,
  /// buttons drawn on top), each with the rectangle it covers, plus the
  /// frame's size and where the screen sits.
  public struct Vector {
    public struct Piece {
      public var rect: CGRect
      public var svg: String
    }
    public var under: [Piece]
    public var over: [Piece]
    public var size: CGSize
    public var screen: CGRect

    /// The pieces that reach into rows `top..<bottom`, as markup.
    public func markup(_ pieces: [Piece], top: Double, bottom: Double) -> String {
      pieces.filter { $0.rect.maxY > top && $0.rect.minY < bottom }.map(\.svg).joined()
    }

    /// Characters of vector markup in the heaviest window `height` tall.
    func heaviest(height: Double) -> Int {
      var most = 0
      var y = 0.0
      repeat {
        let size = markup(under, top: y, bottom: y + height).utf8.count + markup(over, top: y, bottom: y + height).utf8.count
        most = max(most, size)
        y += 16
      } while y + height < size.height + 16
      return most
    }
  }

  /// The bezel as SVG for a screen size, built once per size: every frame
  /// of a run shares it.
  public func vector(pointWidth: Double, pointHeight: Double) -> Vector {
    let key = "\(pointWidth)x\(pointHeight)"
    if let hit = vectors.withLock({ $0[key] }) { return hit }
    let v = makeVector(pointWidth: pointWidth, pointHeight: pointHeight)
    vectors.withLock { $0[key] = v }
    return v
  }
  let vectors = Locked<[String: Vector]>([:])

  func makeVector(pointWidth: Double, pointHeight: Double) -> Vector {
    let outer = CGRect(x: -left, y: -top, width: pointWidth + left + right, height: pointHeight + top + bottom)
    var bounds = outer
    for i in inputs { bounds = bounds.union(rect(i, outer: outer)) }
    bounds = bounds.insetBy(dx: -2, dy: -2).integral
    let ids = PDFVector.IDs(prefix: "c")
    // Frame coordinates: the bounds' top-left at the origin.
    func piece(_ page: CGPDFPage, _ r: CGRect) -> Vector.Piece {
      let moved = r.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
      return Vector.Piece(rect: moved, svg: PDFVector.placed(page, in: moved, ids: ids))
    }
    var under: [Vector.Piece] = []
    for i in inputs where !i.onTop { under.append(piece(i.page, rect(i, outer: outer))) }
    for (page, r) in bezelRects(outer: outer) { under.append(piece(page, r)) }
    var over: [Vector.Piece] = []
    if island {
      let pill = CGRect(x: (pointWidth - 126) / 2 - bounds.minX, y: 11 - bounds.minY, width: 126, height: 37)
      over.append(Vector.Piece(
        rect: pill,
        svg: "<rect x=\"\(PDFVector.n(pill.minX))\" y=\"\(PDFVector.n(pill.minY))\" width=\"126\" height=\"37\" rx=\"18.5\" fill=\"#000\"/>"))
    }
    for i in inputs where i.onTop { over.append(piece(i.page, rect(i, outer: outer))) }
    return Vector(
      under: under, over: over, size: bounds.size,
      screen: CGRect(x: -bounds.minX, y: -bounds.minY, width: pointWidth, height: pointHeight))
  }

  /// The pane's strips for a full-screen capture: SVG slices of the device,
  /// each with its vector bezel and its slice of the screen embedded, so the
  /// bezel stays sharp at any size. Returns the strips and the frame's width
  /// in points, or nil when the capture isn't the full screen.
  public func strips(png: String, pointWidth: Double, pointHeight: Double, scale: Double, outputDir: String, name: String)
    -> (strips: [FrameStrip], width: Double)? {
    guard fillsScreen(width: pointWidth, height: pointHeight),
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let v = vector(pointWidth: pointWidth, pointHeight: pointHeight)
    // The screen in the display's shape; the corners are transparent (black in a JPEG strip, on the black bezel).
    let w = Int((pointWidth * scale).rounded()), h = Int((pointHeight * scale).rounded())
    guard let layer = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // The layer is in pixels: fill all of it.
    drawScreen(image, in: CGRect(x: 0, y: 0, width: w, height: h), scale: 1, flipped: false, layer)
    let screenPNG = (outputDir as NSString).appendingPathComponent("\(name)-screen.png")
    guard let masked = layer.makeImage(),
          (try? FrameStrips.encode(masked, type: .png).write(to: URL(fileURLWithPath: screenPNG))) != nil else { return nil }

    // Each SVG carries the vector pieces reaching into it; what is left of the
    // element's limit holds the image. Slices are at most 512 rows of screen,
    // plus the bezel above or below it for the first and last.
    let window = 512 / scale + max(v.screen.minY, v.size.height - v.screen.maxY)
    // The bleed rows (below) cost about 1%: leave 3% spare.
    let budget = (131_072 - v.heaviest(height: window) - 600) * 3 / 4 * 97 / 100
    let bleed = 4  // pixel rows
    guard budget > 20_000 else { return nil }
    // Slices of 512 screen rows (the last shorter).
    var heights: [Double] = []
    var row = 0
    while row < masked.height {
      let n = min(512, masked.height - row)
      heights.append(Double(n) / scale)
      row += n
    }

    // Each slice's markup and screen crop; then the image budget left in the
    // frame's (see `FrameStrips.frameBudget`), shared by rows.
    struct Slice { var top, bottom: Double; var head, tail: String; var crop: CGImage; var y, h: Double; var data = Data(); var mime = "" }
    var slices: [Slice] = []
    var y = 0.0  // top of the screen part, in screen points
    let fw = PDFVector.n(v.size.width)
    for (k, height) in heights.enumerated() {
      // The first slice also takes the bezel above the screen; the last, below.
      let top = k == 0 ? 0 : v.screen.minY + y
      let bottom = k == heights.count - 1 ? v.size.height : v.screen.minY + y + height
      // The image bleeds a few rows past the slice on each inner side, so the
      // slice's own bounds cut it: an image edge at a slice boundary would be
      // antialiased at a fractional zoom and let the bezel beneath show through
      // as a hairline.
      let head = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(fw)\" height=\"\(PDFVector.n(bottom - top))\" "
        + "viewBox=\"0 \(PDFVector.n(top)) \(fw) \(PDFVector.n(bottom - top))\">"
        + v.markup(v.under, top: top, bottom: bottom)
      let tail = v.markup(v.over, top: top, bottom: bottom) + "</svg>"
      let row0 = Int((y * scale).rounded()), rows = Int((height * scale).rounded())
      let from = max(0, row0 - bleed), to = min(masked.height, row0 + rows + bleed)
      guard let crop = masked.cropping(to: CGRect(x: 0, y: from, width: masked.width, height: to - from)) else { return nil }
      slices.append(Slice(
        top: top, bottom: bottom, head: head, tail: tail, crop: crop,
        y: v.screen.minY + Double(from) / scale, h: Double(to - from) / scale))
      y += height
    }
    // One format and quality for every slice (see FrameStrips.encodeConsistently),
    // within each element's room and the frame's budget.
    let markup = slices.reduce(0) { $0 + $1.head.count + $1.tail.count + 400 }
    let rooms = slices.map { (131_072 - $0.head.count - $0.tail.count - 400) * 3 / 4 }
    let total = max(0, FrameStrips.frameBudget - markup) * 3 / 4
    guard let (datas, format) = FrameStrips.encodeConsistently(slices.map(\.crop), rooms: rooms, total: total) else {
      // A screen too busy even as JPEGs: fewer pixels, down to 1x.
      guard scale > 1 else { return nil }
      return strips(png: png, pointWidth: pointWidth, pointHeight: pointHeight, scale: max(1, scale * 0.75),
                    outputDir: outputDir, name: name)
    }
    for i in slices.indices {
      slices[i].data = datas[i]
      slices[i].mime = "image/\(format)"
    }

    var out: [FrameStrip] = []
    for (k, sl) in slices.enumerated() {
      let svg = sl.head
        + "<image x=\"\(PDFVector.n(v.screen.minX))\" y=\"\(PDFVector.n(sl.y))\" width=\"\(PDFVector.n(pointWidth))\" "
        + "height=\"\(PDFVector.n(sl.h))\" preserveAspectRatio=\"none\" href=\"data:\(sl.mime);base64,\(sl.data.base64EncodedString())\"/>"
        + sl.tail
      let path = (outputDir as NSString).appendingPathComponent("\(name)-s\(k).svg")
      guard (try? Data(svg.utf8).write(to: URL(fileURLWithPath: path))) != nil else { return nil }
      out.append(FrameStrip(
        path: path, format: "svg", pixelWidth: Int((v.size.width * scale).rounded()),
        pixelHeight: Int(((sl.bottom - sl.top) * scale).rounded()), height: sl.bottom - sl.top))
    }
    return (out, v.size.width)
  }

  func drawBezel(outer o: CGRect, _ ctx: CGContext) {
    guard let tl = pieces["topLeft"], let tr = pieces["topRight"], let bl = pieces["bottomLeft"], let br = pieces["bottomRight"],
          let t = pieces["top"], let b = pieces["bottom"], let l = pieces["left"], let r = pieces["right"] else { return }
    let tls = Self.size(tl), trs = Self.size(tr), bls = Self.size(bl), brs = Self.size(br)
    draw(tl, in: CGRect(origin: CGPoint(x: o.minX, y: o.minY), size: tls), ctx)
    draw(tr, in: CGRect(x: o.maxX - trs.width, y: o.minY, width: trs.width, height: trs.height), ctx)
    draw(bl, in: CGRect(x: o.minX, y: o.maxY - bls.height, width: bls.width, height: bls.height), ctx)
    draw(br, in: CGRect(x: o.maxX - brs.width, y: o.maxY - brs.height, width: brs.width, height: brs.height), ctx)
    draw(t, in: CGRect(x: o.minX + tls.width, y: o.minY, width: o.width - tls.width - trs.width, height: Self.size(t).height), ctx)
    draw(b, in: CGRect(x: o.minX + bls.width, y: o.maxY - Self.size(b).height, width: o.width - bls.width - brs.width, height: Self.size(b).height), ctx)
    draw(l, in: CGRect(x: o.minX, y: o.minY + tls.height, width: Self.size(l).width, height: o.height - tls.height - bls.height), ctx)
    draw(r, in: CGRect(x: o.maxX - Self.size(r).width, y: o.minY + trs.height, width: Self.size(r).width, height: o.height - trs.height - brs.height), ctx)
  }

  /// The capture, cut to the display's shape when there is a mask.
  func drawScreen(_ screen: CGImage, in rect: CGRect, scale: Double, flipped: Bool = true, _ ctx: CGContext) {
    let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
    guard let layer = CGContext(
      data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    layer.interpolationQuality = .high
    layer.draw(screen, in: full)
    if let mask = screenMask {
      // Keep the capture only where the mask is opaque.
      layer.setBlendMode(.destinationIn)
      let m = mask.getBoxRect(.mediaBox)
      layer.scaleBy(x: CGFloat(w) / m.width, y: CGFloat(h) / m.height)
      layer.translateBy(x: -m.minX, y: -m.minY)
      layer.drawPDFPage(mask)
    }
    guard let image = layer.makeImage() else { return }
    guard flipped else {
      ctx.draw(image, in: rect)
      return
    }
    // `ctx` is y down: flip the image back upright.
    ctx.saveGState()
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    ctx.restoreGState()
  }

  /// Draws a PDF page stretched to `rect` in the y-down context.
  func draw(_ page: CGPDFPage, in rect: CGRect, _ ctx: CGContext) {
    guard rect.width > 0, rect.height > 0 else { return }
    let m = page.getBoxRect(.mediaBox)
    ctx.saveGState()
    // The 1 pt edge pieces draw past their page; stretched, that would smear.
    ctx.clip(to: rect)
    ctx.translateBy(x: rect.minX, y: rect.maxY)
    ctx.scaleBy(x: rect.width / m.width, y: -rect.height / m.height)
    ctx.translateBy(x: -m.minX, y: -m.minY)
    ctx.drawPDFPage(page)
    ctx.restoreGState()
  }
}
