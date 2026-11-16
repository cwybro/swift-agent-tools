import Core

public enum Unrelated {
  public static func label() -> String {
    Greeting.text(for: "sibling")
  }
}
