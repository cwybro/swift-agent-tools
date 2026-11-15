import SwiftUI

public struct ProfileCard: View {
  public let name: String
  public let role: String
  // The CLT has no SwiftUI macro plugins, so this example avoids @State.
  public let isFollowing: Bool

  public init(name: String, role: String, isFollowing: Bool = false) {
    self.name = name
    self.role = role
    self.isFollowing = isFollowing
  }

  public var body: some View {
    HStack(spacing: 12) {
      avatar
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.headline)
        Text(role).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      Text(isFollowing ? "Following" : "Follow")
        .font(.callout.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().stroke(Palette.accent))
    }
    .padding()
    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
  }

  private var avatar: some View {
    Circle()
      .fill(Palette.accent)
      .frame(width: 44, height: 44)
      .overlay(Text(initials).foregroundStyle(.white).bold())
  }

  private var initials: String {
    name.split(separator: " ").compactMap(\.first).map(String.init).joined()
  }
}

enum Palette {
  static var accent: Color { .indigo }
  static var card: Color { Color.gray.opacity(0.15) }
}

#if XCODE_PREVIEW_MACROS
#Preview("Default") {
  ProfileCard(name: "Ada Lovelace", role: "Analyst")
    .padding()
}
#endif

struct ProfileCard_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 16) {
      ProfileCard(name: "Ada Lovelace", role: "Analyst")
      ProfileCard(name: "Grace Hopper", role: "Rear Admiral", isFollowing: true)
      // TextField("Search people", text: .constant("Ada"))
    }
    .padding()
    .frame(width: 360)
  }
}
