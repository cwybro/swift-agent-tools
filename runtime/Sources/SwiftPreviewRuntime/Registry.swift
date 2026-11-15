import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// How a preview is sized, from `#Preview(traits:)`.
public enum PreviewLayout: Sendable {
  case device
  case sizeThatFits
  case fixed(width: Double, height: Double)
}

/// One preview, registered by a generated thunk.
public struct PreviewEntry {
  public let name: String
  public let line: Int
  public let layout: PreviewLayout
  public let make: @MainActor () -> AnyView

  public init(name: String, line: Int, layout: PreviewLayout, make: @escaping @MainActor () -> AnyView) {
    self.name = name
    self.line = line
    self.layout = layout
    self.make = make
  }
}

/// Previews by file, replaced wholesale each time a thunk for that file loads.
@MainActor
public enum PreviewRegistry {
  static var files: [String: [PreviewEntry]] = [:]

  public static func set(file: String, _ entries: [PreviewEntry]) {
    files[file] = entries
  }
}

/// Turns a `#Preview` body into a view. Overloads mirror the `#Preview`
/// macro: SwiftUI content, a UIKit view controller or a UIKit view.
public enum PreviewContent {
  @MainActor
  public static func make<V: View>(@ViewBuilder _ body: () -> V) -> AnyView {
    AnyView(body())
  }

  #if canImport(UIKit)
  @MainActor
  public static func make(_ body: () -> UIViewController) -> AnyView {
    AnyView(ControllerHost(controller: body()).ignoresSafeArea())
  }

  @MainActor
  public static func make(_ body: () -> UIView) -> AnyView {
    AnyView(ViewHost(view: body()))
  }

  struct ControllerHost: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
  }

  struct ViewHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
  }
  #endif
}
