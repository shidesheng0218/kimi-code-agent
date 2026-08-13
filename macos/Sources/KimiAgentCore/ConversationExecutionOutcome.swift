import Foundation

/// Pure completion rules shared by the desktop runtime and Core checks.
public enum ConversationExecutionOutcome: Equatable, Sendable {
  case completed
  case failed(String)

  public static func resolve(
    exitCode: Int32,
    events: [AgentEvent],
    turnID: UUID?
  ) -> ConversationExecutionOutcome {
    let hasReply = events.contains { event in
      guard event.kind == .output,
            event.actor != "desktop",
            turnID == nil || event.turnID == turnID else { return false }
      let text = AssistantReplySanitizer.finalConversationText(
        from: event.payload["text"] ?? "",
        contentType: event.payload["contentType"]
      )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return !text.isEmpty && !text.contains("正在思考")
    }

    guard exitCode == 0 else { return .failed("Runtime 退出码：\(exitCode)") }
    return hasReply ? .completed : .failed("模型未返回有效回复。")
  }
}
