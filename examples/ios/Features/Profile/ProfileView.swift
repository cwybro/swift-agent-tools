import SwiftUI

public struct ProfileView: View {
  let name: String
  let bio: String
  @State private var isFollowing = false

  public init(name: String, bio: String) {
    self.name = name
    self.bio = bio
  }

  public var body: some View {
    VStack(spacing: 16) {
      Circle()
        .fill(.indigo.gradient)
        .frame(width: 96, height: 96)
        .overlay(Text(initials).font(.largeTitle.bold()).foregroundStyle(.white))
      Text(name).font(.title2.bold())
      Text(bio)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button(isFollowing ? "Following" : "Follow") {
        isFollowing.toggle()
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(24)
  }

  private var initials: String {
    name.split(separator: " ").compactMap(\.first).map(String.init).joined()
  }
}

#Preview("Profile") {
  ProfileView(name: "Ada Lovelace", bio: "Wrote the first published algorithm.")
}

#Preview("Compact", traits: .sizeThatFitsLayout) {
  ProfileView(name: "Grace Hopper", bio: "Compilers, COBOL, nanoseconds.")
}

#Preview("Interactive") {
  @Previewable @State var name = "Alan Turing"
  VStack {
    TextField("Name", text: $name).textFieldStyle(.roundedBorder).padding()
    ProfileView(name: name, bio: "Edit the name above.")
  }
}
