import CoreGraphics
import Foundation

/// Converts a PDF page's vector drawing (paths, fills, strokes, clips, form
/// XObjects) into SVG markup, so device artwork stays sharp at any size.
/// Text, images and shadings are skipped: the Simulator's chrome uses none.
final class PDFVector {
  struct GState {
    var fill = "#000"
    var stroke = "none"
    var fillAlpha = 1.0
    var strokeAlpha = 1.0
    var lineWidth = 1.0
    var cap = 0
    var join = 0
    var miter = 10.0
    var dash: [Double] = []
    var fillComponents = 1
    var strokeComponents = 1
    /// `<g>` elements opened since the matching `q` (transforms and clips).
    var opened = 0
    /// User space to page space, for culling.
    var ctm = CGAffineTransform.identity
    /// Inside a clip that misses the culling box: nothing here can show.
    var hidden = false
  }

  private(set) var out = ""
  private var path = ""
  private var state = GState()
  private var stack: [GState] = []
  private var pendingClip: String?  // "nonzero" | "evenodd"
  private let ids: IDs
  /// Page-space box the drawing is seen through: paths wholly outside it are
  /// left out (a nine-slice piece shows a sliver of the whole bezel).
  private let cull: CGRect?
  /// The path so far, in user space, and its current point.
  private var bounds = CGRect.null
  private var current = CGPoint.zero

  /// Unique clip ids across one SVG document.
  final class IDs {
    var next = 0
    let prefix: String
    init(prefix: String) { self.prefix = prefix }
    func make() -> String {
      next += 1
      return "\(prefix)\(next)"
    }
  }

  init(ids: IDs, cull: CGRect? = nil) {
    self.ids = ids
    self.cull = cull
  }

  /// The page's drawing in its own PDF user space (y up); with `cull`, only
  /// what can show through that page-space box.
  static func markup(of page: CGPDFPage, ids: IDs, cull: CGRect? = nil) -> String {
    let v = PDFVector(ids: ids, cull: cull)
    v.scan(CGPDFContentStreamCreateWithPage(page))
    v.closeAll()
    return cull == nil ? v.out : pruned(v.out)
  }

  /// Drops the groups and clips that culling left empty.
  static func pruned(_ markup: String) -> String {
    var s = markup
    let empties = [
      try! NSRegularExpression(pattern: "<clipPath id=\"([^\"]+)\"><path [^>]*/></clipPath><g clip-path=\"url\\(#\\1\\)\"></g>"),
      try! NSRegularExpression(pattern: "<g transform=\"[^\"]*\"></g>"),
      try! NSRegularExpression(pattern: "<g></g>"),
    ]
    while true {
      let before = s.count
      for re in empties {
        s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
      }
      if s.count == before { return s }
    }
  }

  /// Whether a user-space rect, as the current transform places it, can show.
  func visible(_ r: CGRect, margin: Double = 0) -> Bool {
    guard let cull, !r.isNull else { return true }
    return r.applying(state.ctm).insetBy(dx: -margin, dy: -margin).intersects(cull)
  }

  func point(_ x: Double, _ y: Double) {
    bounds = bounds.union(CGRect(x: x, y: y, width: 0, height: 0))
  }

  /// The page stretched to `rect` (y down) and clipped to it, as the raster
  /// drawing does: a nested `<svg>` clips to its own box.
  static func placed(_ page: CGPDFPage, in rect: CGRect, ids: IDs) -> String {
    guard rect.width > 0, rect.height > 0 else { return "" }
    let m = page.getBoxRect(.mediaBox)
    // A stretched piece (a 1 pt slice of the whole bezel) is the same all
    // along its stretch: its cross-section as rects, not the bezel's paths.
    if m.width <= 2 && rect.width > m.width * 4 { return crossSection(page, in: rect, alongX: true) }
    if m.height <= 2 && rect.height > m.height * 4 { return crossSection(page, in: rect, alongX: false) }
    // Clip a quarter point past the piece on every side, with the drawing's
    // scale unchanged, so antialiased edges of neighbouring pieces overlap
    // instead of leaving a hairline seam between them.
    let e = 0.25
    let ex = e * m.width / rect.width, ey = e * m.height / rect.height
    let r = rect.insetBy(dx: -e, dy: -e)
    let box = m.insetBy(dx: -ex, dy: -ey)
    // What the piece shows of the page: its box (stretched pieces show a sliver).
    // Flip y inside the page's own box: PDF space is y up.
    return "<svg x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" "
      + "viewBox=\"\(n(box.minX)) \(n(box.minY)) \(n(box.width)) \(n(box.height))\" preserveAspectRatio=\"none\" overflow=\"hidden\">"
      + "<g transform=\"matrix(1 0 0 -1 0 \(n(2 * m.minY + m.height)))\">"
      + markup(of: page, ids: ids, cull: box.insetBy(dx: -1, dy: -1))
      + "</g></svg>"
  }

  /// A stretched piece drawn as its cross-section: the page sampled across
  /// the unstretched axis at 8 samples a point, runs of one color as rects
  /// spanning the stretch. Stays sharp up to 8x.
  static func crossSection(_ page: CGPDFPage, in rect: CGRect, alongX: Bool) -> String {
    let m = page.getBoxRect(.mediaBox)
    let k = 8.0  // samples per point across
    let across = alongX ? m.height : m.width
    let count = max(1, Int((across * k).rounded()))
    // One row (or column) of pixels through the middle of the stretch axis.
    let (w, h) = alongX ? (1, count) : (count, 1)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(
      data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
    ctx.scaleBy(x: CGFloat(w) / m.width, y: CGFloat(h) / m.height)
    ctx.translateBy(x: -m.minX, y: -m.minY)
    ctx.drawPDFPage(page)
    // Sample i: across from the top (y down) or the left.
    func sample(_ i: Int) -> (r: Int, g: Int, b: Int, a: Int) {
      let o = alongX ? (i * w) * 4 : i * 4  // row 0 of the bitmap is the top
      return (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]), Int(px[o + 3]))
    }
    let e = 0.25  // overlap neighbours along the stretch, as `placed` does
    var out = "<g>"
    var start = 0
    func flush(_ end: Int) {
      let c = sample(start)
      guard c.a > 2 else { return }
      // Unpremultiply.
      func u(_ v: Int) -> Int { min(255, (v * 255 + c.a / 2) / c.a) }
      let fill = String(format: "#%02x%02x%02x", u(c.r), u(c.g), u(c.b))
      let alpha = c.a < 253 ? " fill-opacity=\"\(n(Double(c.a) / 255))\"" : ""
      let a0 = Double(start) / Double(count) * Double(alongX ? rect.height : rect.width)
      let a1 = Double(end) / Double(count) * Double(alongX ? rect.height : rect.width)
      if alongX {
        out += "<rect x=\"\(n(rect.minX - e))\" y=\"\(n(rect.minY + a0))\" width=\"\(n(rect.width + 2 * e))\" height=\"\(n(a1 - a0))\" fill=\"\(fill)\"\(alpha)/>"
      } else {
        out += "<rect x=\"\(n(rect.minX + a0))\" y=\"\(n(rect.minY - e))\" width=\"\(n(a1 - a0))\" height=\"\(n(rect.height + 2 * e))\" fill=\"\(fill)\"\(alpha)/>"
      }
    }
    for i in 1...count {
      if i == count || sample(i) != sample(start) {
        flush(i)
        start = i
      }
    }
    return out + "</g>"
  }

  static func n(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
  }
  static func n(_ v: CGFloat) -> String { n(Double(v)) }

  // MARK: Scanning

  func scan(_ content: CGPDFContentStreamRef) {
    let table = Self.table
    let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
    CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
  }

  func closeAll() {
    while !stack.isEmpty { restore() }
    out += String(repeating: "</g>", count: state.opened)
    state.opened = 0
  }

  static func me(_ info: UnsafeMutableRawPointer?) -> PDFVector {
    Unmanaged<PDFVector>.fromOpaque(info!).takeUnretainedValue()
  }

  static func pop(_ s: CGPDFScannerRef, _ count: Int) -> [Double] {
    var values = [Double](repeating: 0, count: count)
    for i in stride(from: count - 1, through: 0, by: -1) {
      var v: CGPDFReal = 0
      if !CGPDFScannerPopNumber(s, &v) { return [] }
      values[i] = Double(v)
    }
    return values
  }

  /// Pops every number on the stack (for `sc`/`scn`, whose count depends on the color space).
  static func popAll(_ s: CGPDFScannerRef) -> [Double] {
    var values: [Double] = []
    var v: CGPDFReal = 0
    while CGPDFScannerPopNumber(s, &v) { values.insert(Double(v), at: 0) }
    return values
  }

  static func color(_ c: [Double]) -> String? {
    func hex(_ x: Double) -> String { String(format: "%02x", Int((max(0, min(1, x)) * 255).rounded())) }
    switch c.count {
    case 1: return "#" + hex(c[0]) + hex(c[0]) + hex(c[0])
    case 3: return "#" + hex(c[0]) + hex(c[1]) + hex(c[2])
    case 4:
      let k = c[3]
      return "#" + hex((1 - c[0]) * (1 - k)) + hex((1 - c[1]) * (1 - k)) + hex((1 - c[2]) * (1 - k))
    default: return nil
    }
  }

  func save() {
    stack.append(state)
    state.opened = 0
  }

  func restore() {
    out += String(repeating: "</g>", count: state.opened)
    if let s = stack.popLast() { state = s }
  }

  func paint(fill: String?, stroke: Bool) {
    let scale = max(abs(state.ctm.a) + abs(state.ctm.c), abs(state.ctm.b) + abs(state.ctm.d))
    let shows = !state.hidden && visible(bounds, margin: stroke ? state.lineWidth * scale : 0)
    if !path.isEmpty, shows {
      var attrs = "d=\"\(path.trimmingCharacters(in: .whitespaces))\""
      if let rule = fill {
        attrs += " fill=\"\(state.fill)\""
        if rule == "evenodd" { attrs += " fill-rule=\"evenodd\"" }
        if state.fillAlpha < 1 { attrs += " fill-opacity=\"\(Self.n(state.fillAlpha))\"" }
      } else {
        attrs += " fill=\"none\""
      }
      if stroke {
        attrs += " stroke=\"\(state.stroke == "none" ? "#000" : state.stroke)\" stroke-width=\"\(Self.n(state.lineWidth))\""
        if state.strokeAlpha < 1 { attrs += " stroke-opacity=\"\(Self.n(state.strokeAlpha))\"" }
        if state.cap != 0 { attrs += " stroke-linecap=\"\(state.cap == 1 ? "round" : "square")\"" }
        if state.join != 0 { attrs += " stroke-linejoin=\"\(state.join == 1 ? "round" : "bevel")\"" }
        if state.miter != 4 { attrs += " stroke-miterlimit=\"\(Self.n(state.miter))\"" }
        if !state.dash.isEmpty { attrs += " stroke-dasharray=\"\(state.dash.map { Self.n($0) }.joined(separator: " "))\"" }
      }
      out += "<path \(attrs)/>"
    }
    endPath()
  }

  /// After painting (or `n`): apply a pending clip, then start a new path.
  func endPath() {
    if pendingClip != nil, !path.isEmpty, !visible(bounds) { state.hidden = true }
    if let rule = pendingClip, !path.isEmpty, !state.hidden {
      let id = ids.make()
      out += "<clipPath id=\"\(id)\"><path d=\"\(path.trimmingCharacters(in: .whitespaces))\""
        + (rule == "evenodd" ? " clip-rule=\"evenodd\"" : "") + "/></clipPath><g clip-path=\"url(#\(id))\">"
      state.opened += 1
    }
    pendingClip = nil
    path = ""
    bounds = .null
  }

  static let table: CGPDFOperatorTableRef = {
    let t = CGPDFOperatorTableCreate()!
    func on(_ op: String, _ cb: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(t, op, cb) }
    on("q") { _, i in me(i).save() }
    on("Q") { _, i in me(i).restore() }
    on("cm") { s, i in
      let v = pop(s, 6)
      guard v.count == 6 else { return }
      let m = me(i)
      m.out += "<g transform=\"matrix(\(v.map { n($0) }.joined(separator: " ")))\">"
      m.state.opened += 1
      m.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(m.state.ctm)
    }
    on("w") { s, i in if let v = pop(s, 1).first { me(i).state.lineWidth = v } }
    on("J") { s, i in if let v = pop(s, 1).first { me(i).state.cap = Int(v) } }
    on("j") { s, i in if let v = pop(s, 1).first { me(i).state.join = Int(v) } }
    on("M") { s, i in if let v = pop(s, 1).first { me(i).state.miter = v } }
    on("d") { s, i in
      var phase: CGPDFReal = 0
      _ = CGPDFScannerPopNumber(s, &phase)
      var array: CGPDFArrayRef?
      guard CGPDFScannerPopArray(s, &array), let a = array else { return }
      var dash: [Double] = []
      for k in 0..<CGPDFArrayGetCount(a) {
        var v: CGPDFReal = 0
        if CGPDFArrayGetNumber(a, k, &v) { dash.append(Double(v)) }
      }
      me(i).state.dash = dash
    }
    // Path construction.
    // Control points bound the curve, so they count toward the path's bounds.
    on("m") { s, i in
      let v = pop(s, 2)
      guard v.count == 2 else { return }
      let m = me(i)
      m.path += "M\(n(v[0])) \(n(v[1])) "
      m.point(v[0], v[1]); m.current = CGPoint(x: v[0], y: v[1])
    }
    on("l") { s, i in
      let v = pop(s, 2)
      guard v.count == 2 else { return }
      let m = me(i)
      m.path += "L\(n(v[0])) \(n(v[1])) "
      m.point(v[0], v[1]); m.current = CGPoint(x: v[0], y: v[1])
    }
    on("c") { s, i in
      let v = pop(s, 6)
      guard v.count == 6 else { return }
      let m = me(i)
      m.path += "C\(v.map { n($0) }.joined(separator: " ")) "
      m.point(v[0], v[1]); m.point(v[2], v[3]); m.point(v[4], v[5]); m.current = CGPoint(x: v[4], y: v[5])
    }
    on("v") { s, i in
      // The first control point is the current point.
      let v = pop(s, 4)
      guard v.count == 4 else { return }
      let m = me(i)
      let cur = m.current
      m.path += "C\(n(cur.x)) \(n(cur.y)) \(v.map { n($0) }.joined(separator: " ")) "
      m.point(v[0], v[1]); m.point(v[2], v[3]); m.current = CGPoint(x: v[2], y: v[3])
    }
    on("y") { s, i in
      let v = pop(s, 4)
      guard v.count == 4 else { return }
      let m = me(i)
      m.path += "C\(n(v[0])) \(n(v[1])) \(n(v[2])) \(n(v[3])) \(n(v[2])) \(n(v[3])) "
      m.point(v[0], v[1]); m.point(v[2], v[3]); m.current = CGPoint(x: v[2], y: v[3])
    }
    on("h") { _, i in me(i).path += "Z " }
    on("re") { s, i in
      let v = pop(s, 4)
      if v.count == 4 {
        let (x, y, w, h) = (v[0], v[1], v[2], v[3])
        let m = me(i)
        m.path += "M\(n(x)) \(n(y)) L\(n(x + w)) \(n(y)) L\(n(x + w)) \(n(y + h)) L\(n(x)) \(n(y + h)) Z "
        m.point(x, y); m.point(x + w, y + h); m.current = CGPoint(x: x, y: y)
      }
    }
    // Painting.
    on("f") { _, i in me(i).paint(fill: "nonzero", stroke: false) }
    on("F") { _, i in me(i).paint(fill: "nonzero", stroke: false) }
    on("f*") { _, i in me(i).paint(fill: "evenodd", stroke: false) }
    on("S") { _, i in me(i).paint(fill: nil, stroke: true) }
    on("s") { _, i in let m = me(i); m.path += "Z "; m.paint(fill: nil, stroke: true) }
    on("B") { _, i in me(i).paint(fill: "nonzero", stroke: true) }
    on("B*") { _, i in me(i).paint(fill: "evenodd", stroke: true) }
    on("b") { _, i in let m = me(i); m.path += "Z "; m.paint(fill: "nonzero", stroke: true) }
    on("b*") { _, i in let m = me(i); m.path += "Z "; m.paint(fill: "evenodd", stroke: true) }
    on("n") { _, i in me(i).endPath() }
    on("W") { _, i in me(i).pendingClip = "nonzero" }
    on("W*") { _, i in me(i).pendingClip = "evenodd" }
    // Color.
    on("g") { s, i in if let c = color(pop(s, 1)) { me(i).state.fill = c } }
    on("G") { s, i in if let c = color(pop(s, 1)) { me(i).state.stroke = c } }
    on("rg") { s, i in if let c = color(pop(s, 3)) { me(i).state.fill = c } }
    on("RG") { s, i in if let c = color(pop(s, 3)) { me(i).state.stroke = c } }
    on("k") { s, i in if let c = color(pop(s, 4)) { me(i).state.fill = c } }
    on("K") { s, i in if let c = color(pop(s, 4)) { me(i).state.stroke = c } }
    on("sc") { s, i in if let c = color(popAll(s)) { me(i).state.fill = c } }
    on("scn") { s, i in if let c = color(popAll(s)) { me(i).state.fill = c } }
    on("SC") { s, i in if let c = color(popAll(s)) { me(i).state.stroke = c } }
    on("SCN") { s, i in if let c = color(popAll(s)) { me(i).state.stroke = c } }
    on("gs") { s, i in
      var name: UnsafePointer<CChar>?
      guard CGPDFScannerPopName(s, &name), let name else { return }
      let content = CGPDFScannerGetContentStream(s)
      guard let obj = CGPDFContentStreamGetResource(content, "ExtGState", name) else { return }
      var dict: CGPDFDictionaryRef?
      guard CGPDFObjectGetValue(obj, .dictionary, &dict), let dict else { return }
      let m = me(i)
      var v: CGPDFReal = 0
      if CGPDFDictionaryGetNumber(dict, "ca", &v) { m.state.fillAlpha = Double(v) }
      if CGPDFDictionaryGetNumber(dict, "CA", &v) { m.state.strokeAlpha = Double(v) }
      if CGPDFDictionaryGetNumber(dict, "LW", &v) { m.state.lineWidth = Double(v) }
    }
    // Form XObjects: their own content, under their matrix.
    on("Do") { s, i in
      var name: UnsafePointer<CChar>?
      guard CGPDFScannerPopName(s, &name), let name else { return }
      let content = CGPDFScannerGetContentStream(s)
      guard let obj = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
      var stream: CGPDFStreamRef?
      guard CGPDFObjectGetValue(obj, .stream, &stream), let stream,
            let dict = CGPDFStreamGetDictionary(stream) else { return }
      var subtype: UnsafePointer<CChar>?
      guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
      let m = me(i)
      m.save()
      var matrix: CGPDFArrayRef?
      if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
        var v = [Double]()
        for k in 0..<6 {
          var x: CGPDFReal = 0
          _ = CGPDFArrayGetNumber(matrix, k, &x)
          v.append(Double(x))
        }
        m.out += "<g transform=\"matrix(\(v.map { n($0) }.joined(separator: " ")))\">"
        m.state.opened += 1
        m.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(m.state.ctm)
      }
      var resources: CGPDFDictionaryRef?
      _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
      let sub = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, content)
      m.scan(sub)
      m.restore()
    }
    return t
  }()

}
