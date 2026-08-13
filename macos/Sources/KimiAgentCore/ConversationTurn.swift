import Foundation

public enum ConversationTurnStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case running
  case waitingForApproval
  case paused
  case completed
  case failed
  case cancelled
  case retrying
}

public struct ConversationTurn: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sequence: Int
  public var userMessage: String
  public var assistantMessage: String
  public var status: ConversationTurnStatus
  public var attempt: Int
  public var errorMessage: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    sequence: Int,
    userMessage: String,
    assistantMessage: String = "",
    status: ConversationTurnStatus = .queued,
    attempt: Int = 0,
    errorMessage: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.sequence = sequence
    self.userMessage = userMessage
    self.assistantMessage = assistantMessage
    self.status = status
    self.attempt = attempt
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
