import Foundation

public enum WorkbenchConversationPage: Equatable, Sendable {
  case home
  case newConversation
  case existingConversation(UUID)
}

public enum WorkbenchConversationNavigationPolicy {
  public static func page(
    selectedTaskID: UUID?,
    hasSelectedTask: Bool,
    isComposingNewConversation: Bool
  ) -> WorkbenchConversationPage {
    if let selectedTaskID, hasSelectedTask {
      return .existingConversation(selectedTaskID)
    }
    if isComposingNewConversation {
      return .newConversation
    }
    return .home
  }
}
