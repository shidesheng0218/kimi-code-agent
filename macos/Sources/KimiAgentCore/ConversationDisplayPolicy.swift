import Foundation

/// Keeps long replies lossless and lets the native transcript follow a
/// streaming reply even when the stable turn ID does not change.
public enum ConversationDisplayPolicy {
  public static func visibleText(_ text: String) -> String { text }

  public static func shouldFollowStreamingText(
    previousID: String?,
    previousText: String?,
    currentID: String?,
    currentText: String?
  ) -> Bool {
    guard let currentID, let currentText else { return false }
    guard previousID == currentID else { return true }
    return previousText != currentText
  }
}
