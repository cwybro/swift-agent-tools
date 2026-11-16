import Core
import SwiftUI
import UI

public struct ProfileView: View {
  public let person: Person

  public init(person: Person) {
    self.person = person
  }

  public var body: some View {
    VStack(spacing: 12) {
      Text(person.name).font(.title)
      Badge(person: person)
    }
    .padding()
  }
}

#Preview("Profile") {
  ProfileView(person: Person(name: "Ada"))
    .frame(width: 240, height: 140)
}
