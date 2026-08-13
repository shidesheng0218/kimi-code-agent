import Foundation

public enum ComputerUseAction: String, Codable, CaseIterable, Sendable {
  case click
  case typeText
  case navigate
  case screenshot
  case delete
  case externalSend
  case systemSettings
  case purchase
}

public enum ComputerUsePolicy {
  public static func decision(for action: ComputerUseAction) -> PermissionDecision {
    switch action {
    case .click, .typeText, .navigate, .screenshot:
      .allow
    case .delete, .externalSend, .systemSettings, .purchase:
      .ask
    }
  }
}
