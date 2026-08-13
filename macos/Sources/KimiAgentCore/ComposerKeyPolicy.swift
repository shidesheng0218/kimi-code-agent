import Foundation

public enum ComposerKeyAction: Equatable, Sendable {
  case submit
  case insertNewline
  case ignore
}

public enum ComposerKeyPolicy {
  public static func action(
    for key: String,
    command: Bool = false,
    shift: Bool = false,
    option: Bool = false
  ) -> ComposerKeyAction {
    guard key.lowercased() == "return" || key.lowercased() == "enter" else {
      return .ignore
    }
    if shift || option {
      return .insertNewline
    }
    return .submit
  }
}
