import Foundation

public struct ConversationContextWindow: Equatable, Sendable {
  public let summary: String
  public let recentTurns: [ConversationTurn]

  public init(summary: String, recentTurns: [ConversationTurn]) {
    self.summary = summary
    self.recentTurns = recentTurns
  }

  public var promptText: String {
    let recent = recentTurns.map { turn in
      let user = turn.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      let assistant = turn.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      return "用户：" + user + (assistant.isEmpty ? "" : "\n助手：" + assistant)
    }.joined(separator: "\n\n")
    return [summary.isEmpty ? nil : "较早对话摘要：" + summary, recent.isEmpty ? nil : "最近对话：\n" + recent]
      .compactMap { $0 }
      .joined(separator: "\n\n")
  }
}

/// Keeps the prompt focused by retaining recent turns verbatim and reducing
/// earlier turns to a deterministic local summary. The original turns remain
/// in the event journal; this is only a model-context view.
public enum ConversationContextComposer {
  public static func make(
    from turns: [ConversationTurn],
    keepingLast: Int = 4,
    summaryCharacterLimit: Int = 4_000
  ) -> ConversationContextWindow {
    let ordered = turns.sorted { $0.sequence < $1.sequence }
    let retainedCount = max(0, min(keepingLast, ordered.count))
    let older = Array(ordered.dropLast(retainedCount))
    let recent = retainedCount == 0 ? [] : Array(ordered.suffix(retainedCount))
    let rawSummary = older.map { turn in
      let user = clipped(turn.userMessage, limit: 700)
      let assistant = clipped(turn.assistantMessage, limit: 900)
      return assistant.isEmpty ? "用户：" + user : "用户：" + user + "；结果：" + assistant
    }.joined(separator: "\n")
    return ConversationContextWindow(
      summary: clipped(rawSummary, limit: max(0, summaryCharacterLimit)),
      recentTurns: recent
    )
  }

  private static func clipped(_ value: String, limit: Int) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit, limit > 0 else { return limit == 0 ? "" : normalized }
    return String(normalized.prefix(limit)) + "…"
  }
}

