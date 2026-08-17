import Foundation

/// Durable, structured context passed from a completed DAG node to its
/// dependent Child Session. Natural-language summaries remain useful for the
/// model, but evidence and receipts are carried separately so the supervisor
/// never has to infer whether an upstream effect actually settled.
public struct AgentHandoff: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let sourceRunID: UUID
  public let targetRunID: UUID
  public let summary: String
  public let artifacts: [String]
  public let receipts: [UUID]
  public let changedFiles: [String]
  public let unresolved: [String]
  public let contextDigest: String
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    sourceRunID: UUID,
    targetRunID: UUID,
    summary: String,
    artifacts: [String] = [],
    receipts: [UUID] = [],
    changedFiles: [String] = [],
    unresolved: [String] = [],
    contextDigest: String? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.sourceRunID = sourceRunID
    self.targetRunID = targetRunID
    self.summary = summary
    self.artifacts = artifacts
    self.receipts = receipts
    self.changedFiles = changedFiles
    self.unresolved = unresolved
    self.contextDigest = contextDigest ?? HarnessDigest.sha256(summary + artifacts.joined(separator: "\n") + receipts.map { $0.uuidString }.joined())
    self.createdAt = createdAt
  }

  public init(sourceRunID: UUID, targetRunID: UUID, result: AgentResult) {
    self.init(
      sourceRunID: sourceRunID,
      targetRunID: targetRunID,
      summary: result.summary,
      artifacts: result.artifactIDs,
      receipts: result.receiptIDs,
      unresolved: result.status == .completed ? [] : result.nextActions + result.verification
    )
  }

  public var promptSection: String {
    var lines = ["上游阶段回流：" + summary]
    if !artifacts.isEmpty { lines.append("产物：" + artifacts.joined(separator: ", ")) }
    if !receipts.isEmpty { lines.append("已结算 Receipt：" + receipts.map { $0.uuidString }.joined(separator: ", ")) }
    if !changedFiles.isEmpty { lines.append("变更文件：" + changedFiles.joined(separator: ", ")) }
    if !unresolved.isEmpty { lines.append("未解决：" + unresolved.joined(separator: "；")) }
    lines.append("上下文摘要指纹：" + contextDigest)
    return lines.joined(separator: "\n")
  }
}
