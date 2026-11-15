#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import ImageIO
import SwiftUI

/// macOS host: an offscreen window, no Dock icon, no focus stealing.
@MainActor
final class MacDisplay {
  let window: NSWindow
  var hosting: NSHostingView<AnyView>?
  /// What `hosting` shows, at the size it was laid out, for `ImageRenderer`.
  var rendered: (root: AnyView, size: CGSize, scheme: ColorScheme?)?

  init() {
    window = NSWindow(
      contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
  }

  func present(_ view: AnyView, layout: PreviewLayout, size: CGSize?, scheme: ColorScheme?) {
    let appearance: NSAppearance? = scheme.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)! }
    window.appearance = appearance
    let background = Color(nsColor: .windowBackgroundColor)
    let root = AnyView(
      view
        .modifier(OptionalScheme(scheme: scheme))
        .background(background))
    let hosting = NSHostingView(rootView: root)
    self.hosting = hosting

    var target: CGSize
    switch (size, layout) {
    case (let s?, _): target = s
    case (nil, .fixed(let w, let h)): target = CGSize(width: w, height: h)
    default:
      // "Device" has no meaning for a Mac view: take the view's ideal size.
      let fit = hosting.fittingSize
      target = CGSize(width: min(max(fit.width, 120), 1600), height: min(max(fit.height, 60), 1200))
      if fit.width < 1 || fit.height < 1 { target = CGSize(width: 600, height: 400) }
    }
    // Whole points: a fractional fitting size leaves the last pixel row of an
    // opaque capture unpainted (a black line).
    target = CGSize(width: target.width.rounded(.up), height: target.height.rounded(.up))
    hosting.frame = NSRect(origin: .zero, size: target)
    window.setContentSize(target)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    rendered = (root, target, scheme)
  }

  func capture(mode: String) -> Capture? {
    guard let hosting else { return nil }
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    let bounds = hosting.bounds
    // The SwiftUI renderer draws shapes exactly (a window snapshot adds tick
    // marks to stroked capsules) but cannot draw AppKit-backed views
    // (Toggle, TextField, NSViewRepresentable…): it shows placeholders.
    let controls = platformViews(in: hosting)
    var reason: String?
    switch mode {
    case "window":
      break
    case "swiftui":
      if !controls.isEmpty { reason = "AppKit controls (like TextField) can draw as placeholders with the SwiftUI renderer" }
      if let r = rendered, let cg = renderWithSwiftUI(r) {
        return Capture(png: encode(cg, type: "public.png"), jpeg: thumbnailJPEG(cg), size: r.size, renderer: "swiftui", reason: reason)
      }
      reason = "the SwiftUI renderer failed"
    default:
      if controls.isEmpty, let r = rendered, let cg = renderWithSwiftUI(r) {
        return Capture(png: encode(cg, type: "public.png"), jpeg: thumbnailJPEG(cg), size: r.size, renderer: "swiftui", reason: nil)
      }
      reason = controls.isEmpty ? "the SwiftUI renderer failed" : "the view has AppKit controls"
    }
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    hosting.cacheDisplay(in: bounds, to: rep)
    guard let cg = rep.cgImage else { return nil }
    return Capture(png: encode(cg, type: "public.png"), jpeg: thumbnailJPEG(cg), size: bounds.size, renderer: "window", reason: reason)
  }

  func renderWithSwiftUI(_ r: (root: AnyView, size: CGSize, scheme: ColorScheme?)) -> CGImage? {
    let scheme = r.scheme ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    let renderer = ImageRenderer(content: r.root
      .frame(width: r.size.width, height: r.size.height)
      // The hosting view is at least 60pt tall; paint all of it, as the window does.
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme))
    renderer.scale = window.backingScaleFactor
    renderer.isOpaque = true
    return renderer.cgImage
  }

  /// Descendant views that are not SwiftUI's own drawing views.
  func platformViews(in view: NSView) -> [String] {
    var found: [String] = []
    for sub in view.subviews {
      let name = NSStringFromClass(type(of: sub))
      if !name.hasPrefix("SwiftUI.") && !name.hasPrefix("_TtC7SwiftUI") { found.append(name) }
      found += platformViews(in: sub)
    }
    return found
  }
}

struct OptionalScheme: ViewModifier {
  let scheme: ColorScheme?
  func body(content: Content) -> some View {
    if let scheme { content.environment(\.colorScheme, scheme) } else { content }
  }
}

final class HostAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      let display = MacDisplay()
      let server = PreviewServer.shared
      server.present = { view, layout, size, scheme in display.present(view, layout: layout, size: size, scheme: scheme) }
      server.capture = { mode in display.capture(mode: mode) }
      server.start()
    }
  }
}

/// Entry point for a macOS preview host executable.
@MainActor
public func runPreviewHost() -> Never {
  let app = NSApplication.shared
  app.setActivationPolicy(.prohibited)
  let delegate = HostAppDelegate()
  app.delegate = delegate
  app.run()
  exit(0)
}
#endif
