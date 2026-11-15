#if canImport(UIKit)
import ImageIO
import SwiftUI
import UIKit

/// What the host app shows: the current preview, sized per its layout, with
/// its frame reported so the capture can crop to it.
@MainActor
final class DisplayModel: ObservableObject {
  @Published var content: AnyView = AnyView(IdleView())
  @Published var layout: PreviewLayout = .device
  @Published var size: CGSize?
  @Published var scheme: ColorScheme?
  @Published var generation = 0
  var contentFrame: CGRect = .zero
}

struct IdleView: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "eye")
        .font(.largeTitle)
      Text("SwiftUI preview host")
        .font(.headline)
      Text("Waiting for swiftpreview…")
        .foregroundStyle(.secondary)
    }
  }
}

struct FramePreference: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct PreviewRootView: View {
  @ObservedObject var model: DisplayModel

  var body: some View {
    ZStack {
      Color(uiColor: .systemBackground).ignoresSafeArea()
      sized(model.content)
        .background(GeometryReader { proxy in
          Color.clear.preference(key: FramePreference.self, value: proxy.frame(in: .global))
        })
        .id(model.generation)  // fresh @State on every reload, like Xcode
    }
    .modifier(OptionalSchemeUI(scheme: model.scheme))
    .onPreferenceChange(FramePreference.self) { frame in
      MainActor.assumeIsolated { model.contentFrame = frame }
    }
  }

  @ViewBuilder
  func sized(_ content: AnyView) -> some View {
    if let size = model.size {
      content.frame(width: size.width, height: size.height)
    } else {
      switch model.layout {
      case .device: content.frame(maxWidth: .infinity, maxHeight: .infinity)
      case .sizeThatFits: content.fixedSize()
      case .fixed(let w, let h): content.frame(width: w, height: h)
      }
    }
  }
}

struct OptionalSchemeUI: ViewModifier {
  let scheme: ColorScheme?
  func body(content: Content) -> some View {
    if let scheme { content.preferredColorScheme(scheme) } else { content }
  }
}

@MainActor
func keyWindow() -> UIWindow? {
  UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap(\.windows)
    .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }.first?.windows.first
}

@MainActor
func installServer(model: DisplayModel) {
  let server = PreviewServer.shared
  guard server.present == nil else { return }
  server.present = { view, layout, size, scheme in
    model.content = view
    model.layout = layout
    model.size = size
    model.scheme = scheme
    model.generation += 1
  }
  server.capture = { mode in
    guard let window = keyWindow() else { return nil }
    let full = window.bounds
    var crop = full
    if model.size != nil || { if case .device = model.layout { return false } else { return true } }() {
      crop = model.contentFrame.intersection(full)
      if crop.isEmpty { crop = full }
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = window.screen.scale
    let image = UIGraphicsImageRenderer(bounds: crop, format: format).image { _ in
      window.drawHierarchy(in: full, afterScreenUpdates: true)
    }
    guard let cg = image.cgImage else { return nil }
    return Capture(
      png: encode(cg, type: "public.png"), jpeg: thumbnailJPEG(cg), size: crop.size, renderer: "window",
      reason: mode == "swiftui" ? "the iOS host always snapshots the window" : nil)
  }
  server.start()
}

/// The SwiftUI app a preview host runs.
public struct PreviewHostApp: App {
  @StateObject private var model = DisplayModel()

  public init() {}

  public var body: some Scene {
    WindowGroup {
      PreviewRootView(model: model)
        .onAppear { installServer(model: model) }
    }
  }
}

/// Entry point for an iOS preview host app.
@MainActor
public func runPreviewHost() -> Never {
  PreviewHostApp.main()
  exit(0)
}
#endif
