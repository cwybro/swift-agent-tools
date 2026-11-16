import Core
import SwiftUI

public struct Badge: View {
  public let person: Person

  public init(person: Person) {
    self.person = person
  }

  public var body: some View {
    Text(Greeting.text(for: person.name))
      .padding(8)
      .background(Capsule().fill(Color.blue.opacity(0.2)))
  }
}
