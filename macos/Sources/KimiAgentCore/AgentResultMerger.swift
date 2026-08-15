import Foundation

public enum ResponseLanguage: String, Codable, Sendable {
  case chinese
  case english
}

public enum AgentAggregationOutcome: String, Codable, Sendable {
  case completed
  case partial
  case failed
}

public struct AgentAggregationResult: Codable, Equatable, Sendable {
  public let outcome: AgentAggregationOutcome
  public let finalAnswer: String
  public let stageSummaries: [String]
  public let artifactIDs: [String]
  public let unresolved: [String]

  public init(outcome: AgentAggregationOutcome, finalAnswer: String, stageSummaries: [String], artifactIDs: [String], unresolved: [String]) {
    self.outcome = outcome
    self.finalAnswer = finalAnswer
    self.stageSummaries = stageSummaries
    self.artifactIDs = artifactIDs
    self.unresolved = unresolved
  }
}

public enum AgentResultMerger {
  public static func merge(
    runs: [AgentRun],
    contract: TaskContract,
    requestedLanguage: ResponseLanguage = .chinese
  ) -> AgentAggregationResult {
    let ordered = runs.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    let summaries = ordered.compactMap { run -> String? in
      guard let result = run.result else { return nil }
      let text = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      // A generic Review worker may receive no diff or artifact and respond
      // with a request for more input. That is not task evidence and must not
      // overwrite a successful specialized result (Browser, Computer Use,
      // Web Research, etc.) in the final conversation.
      if run.definition.kind == .review && isNonActionableReview(text) {
        return nil
      }
      return "\(run.definition.kind.title)：\(text)"
    }
    let artifacts = ordered.flatMap { $0.result?.artifactIDs ?? [] }
    let unresolved = ordered.compactMap { run -> String? in
      if run.state == .completed,
         isReceiptBoundStage(run.definition.kind),
         !specializedStageHasReceipt(run) {
        return "\(run.definition.kind.title) 尚缺成功的 Harness receipt"
      }
      guard !run.state.isTerminal || run.state == .failed else { return nil }
      if let error = run.errorMessage, !error.isEmpty { return "\(run.definition.kind.title)：\(error)" }
      return "\(run.definition.kind.title) 尚未完成"
    }
    let failed = ordered.contains { $0.state == .failed }
    let allCompleted = !ordered.isEmpty && ordered.allSatisfy { run in
      guard run.state == .completed else { return false }
      return specializedStageHasReceipt(run) || !isReceiptBoundStage(run.definition.kind)
    }
    let outcome: AgentAggregationOutcome = failed ? .failed : (allCompleted ? .completed : .partial)
    let summary = summaries.isEmpty ? contract.goal : summaries.joined(separator: "；")
    let answer: String
    switch requestedLanguage {
    case .chinese:
      answer = FinalAnswerComposer.compose(
        outcome: outcome == .completed ? .completed : (outcome == .partial ? .partial : .failed),
        summary: summary,
        changedFiles: [],
        verification: allCompleted ? ["DAG 阶段已全部完成。"] : [],
        risks: unresolved
      )
    case .english:
      answer = outcome == .completed ? "Completed: \(summary)" : "Execution incomplete: \(summary)"
    }
    let finalAnswer = ResponseQualityGate.enforce(answer, outcome: outcome == .completed ? .completed : (outcome == .partial ? .partial : .failed))
    return AgentAggregationResult(outcome: outcome, finalAnswer: finalAnswer, stageSummaries: summaries, artifactIDs: artifacts, unresolved: unresolved)
  }

  private static func isNonActionableReview(_ text: String) -> Bool {
    let normalized = text.lowercased()
    let markers = [
      "没有 browser 工具",
      "没有 computer use",
      "没有提供要审查",
      "请提供 diff",
      "请提供 diff/patch",
      "请提供以下任一信息",
      "当前环境中没有",
      "i currently have no",
      "i don't have",
      "no browser tool",
      "no computer use",
      "please provide a diff",
      "please provide diff",
      "let me try using",
      "i will try",
      "i'm unable to"
    ]
    return markers.contains { normalized.contains($0) }
  }

  private static func isReceiptBoundStage(_ kind: AgentKind) -> Bool {
    switch kind {
    case .browserVerification, .computerUse, .webResearch:
      return true
    default:
      return false
    }
  }

  private static func specializedStageHasReceipt(_ run: AgentRun) -> Bool {
    guard let result = run.result else { return false }
    if !result.receiptIDs.isEmpty { return true }
    let receiptEvidence = result.evidence.contains { evidence in
      evidence.source?.localizedCaseInsensitiveContains("receipt") == true
    }
    let receiptVerification = result.verification.contains { text in
      text.localizedCaseInsensitiveContains("receipt") && text.localizedCaseInsensitiveContains("成功")
    }
    return receiptEvidence || receiptVerification
  }
}
