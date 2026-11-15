import SwiftUI

/// A small view with real SwiftUI macros: @State, #Preview, @Previewable.
public struct Counter: View {
  public let title: String
  @State private var count = 0

  public init(title: String) { self.title = title }

  public var body: some View {
    HStack(spacing: 12) {
      Text(title).font(.headline)
      Spacer()
      Button("−") { count -= 1 }
      Text("\(count)").monospacedDigit().frame(minWidth: 28)
      Button("+") { count += 1 }
    }
    .padding()
    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
  }
}

#Preview("Counter") {
  Counter(title: "Coffees")
    .padding()
    .frame(width: 320)
}

#Preview("Bound", traits: .sizeThatFitsLayout) {
  @Previewable @State var on = true
  Toggle("Notifications", isOn: $on)
    .padding()
}
