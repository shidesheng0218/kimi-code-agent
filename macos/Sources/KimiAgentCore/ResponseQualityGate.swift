import Foundation

public struct ResponseQualityResult: Equatable, Sendable {
  public let cleanedText: String
  public let hasBlockingIssues: Bool
  public let issues: [String]

  public init(cleanedText: String, hasBlockingIssues: Bool, issues: [String] = []) {
    self.cleanedText = cleanedText
    self.hasBlockingIssues = hasBlockingIssues
    self.issues = issues
  }
}

public struct FinalAnswerEvidence: Codable, Equatable, Sendable {
  public let subject: String
  public let receiptID: UUID?
  public let succeeded: Bool

  public init(subject: String, receiptID: UUID?, succeeded: Bool) {
    self.subject = subject
    self.receiptID = receiptID
    self.succeeded = succeeded
  }
}

/// Final-answer boundary. Raw provider text must pass through this gate before
/// it can be shown as the assistant's final answer.
public enum ResponseQualityGate {
  public static func validate(_ text: String, outcome: FinalAnswerOutcome) -> ResponseQualityResult {
    var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let internalMarkers = ["thinking:", "analysis:", "assistant analysis", "<think>", "</think>"]
    for marker in internalMarkers {
      if let range = cleaned.range(of: marker, options: [.caseInsensitive]) {
        cleaned = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    var issues: [String] = []
    if cleaned.isEmpty { issues.append("empty_answer") }
    if cleaned.contains("(run.definition") { issues.append("unresolved_interpolation") }
    if outcome == .completed && cleaned.localizedCaseInsensitiveContains("尚未完成") {
      issues.append("completed_answer_contains_unresolved_state")
    }
    let blocking = cleaned.isEmpty || issues.contains("unresolved_interpolation") || issues.contains("completed_answer_contains_unresolved_state")
    return ResponseQualityResult(cleanedText: cleaned, hasBlockingIssues: blocking, issues: issues)
  }

  /// Evidence-aware overload used by specialized stages. A completed answer
  /// cannot claim a Browser/Web/Computer Use result unless every required
  /// evidence item has a successful durable receipt.
  public static func validate(
    _ text: String,
    outcome: FinalAnswerOutcome,
    requiredEvidence: [FinalAnswerEvidence]
  ) -> ResponseQualityResult {
    var result = validate(text, outcome: outcome)
    guard outcome == .completed else { return result }
    let missing = requiredEvidence.filter { !$0.succeeded || $0.receiptID == nil }
    guard !missing.isEmpty else { return result }
    let subjects = missing.map(\.subject).joined(separator: ", ")
    result = ResponseQualityResult(
      cleanedText: result.cleanedText,
      hasBlockingIssues: true,
      issues: result.issues + ["missing_receipt:\(subjects)"]
    )
    return result
  }

  public static func enforce(_ text: String, outcome: FinalAnswerOutcome) -> String {
    let result = validate(text, outcome: outcome)
    guard !result.hasBlockingIssues else {
      return outcome == .failed ? "执行未完成，请查看失败上下文后重试。" : "执行结果需要人工确认。"
    }
    return result.cleanedText
  }

  public static func enforce(
    _ text: String,
    outcome: FinalAnswerOutcome,
    requiredEvidence: [FinalAnswerEvidence]
  ) -> String {
    let result = validate(text, outcome: outcome, requiredEvidence: requiredEvidence)
    guard !result.hasBlockingIssues else {
      return outcome == .failed ? "执行未完成，请查看失败上下文后重试。" : "执行结果缺少可验证回执，已暂停最终确认。"
    }
    return result.cleanedText
  }
}
