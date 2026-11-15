import SwiftPreviewRuntime

// Entry point of a swiftui_preview_host. The libraries under preview are
// linked in whole (-all_load) so thunks can bind to any of their symbols.
@main
enum PreviewHostMain {
  static func main() {
    MainActor.assumeIsolated { runPreviewHost() }
  }
}
