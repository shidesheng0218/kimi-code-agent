import Foundation

public enum WorkItemStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case planning
  case awaitingApproval
  case running
  case reviewReady
  case verifying
  case mergeReady
  case merged
  case failed
  case retrying
  case blocked
  case cancelling
  case cancelled
  case cleaned
}

public enum WorkerRole: String, Codable, CaseIterable, Sendable {
  case analyzer
  case implementer
  case testRunner
  case reviewer
}

public struct WorkItem: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let parentID: UUID?
  public let role: WorkerRole
  public let dependencies: [UUID]
  public let worktreePath: String?
  public var status: WorkItemStatus
  public var retryCount: Int
  public var inputArtifactIDs: [String]
  public var outputArtifactIDs: [String]

  public init(
    id: UUID = UUID(),
    parentID: UUID? = nil,
    role: WorkerRole,
    dependencies: [UUID] = [],
    worktreePath: String? = nil,
    status: WorkItemStatus = .queued,
    retryCount: Int = 0,
    inputArtifactIDs: [String] = [],
    outputArtifactIDs: [String] = []
  ) {
    self.id = id
    self.parentID = parentID
    self.role = role
    self.dependencies = dependencies
    self.worktreePath = worktreePath
    self.status = status
    self.retryCount = retryCount
    self.inputArtifactIDs = inputArtifactIDs
    self.outputArtifactIDs = outputArtifactIDs
  }
}

public enum TaskStateMachine {
  public static func canTransition(from: WorkItemStatus, to: WorkItemStatus) -> Bool {
    switch (from, to) {
    case (.queued, .planning), (.queued, .cancelled):
      true
    case (.planning, .awaitingApproval), (.planning, .running), (.planning, .blocked), (.planning, .cancelled):
      true
    case (.awaitingApproval, .running), (.awaitingApproval, .cancelled), (.awaitingApproval, .blocked):
      true
    case (.running, .reviewReady), (.running, .verifying), (.running, .failed), (.running, .blocked), (.running, .cancelling):
      true
    case (.reviewReady, .verifying), (.reviewReady, .cancelled):
      true
    case (.verifying, .mergeReady), (.verifying, .failed), (.verifying, .blocked), (.verifying, .cancelling):
      true
    case (.mergeReady, .merged), (.mergeReady, .cancelled):
      true
    case (.failed, .retrying), (.failed, .blocked), (.failed, .cancelled):
      true
    case (.retrying, .running), (.retrying, .cancelled):
      true
    case (.blocked, .awaitingApproval), (.blocked, .running), (.blocked, .cancelled):
      true
    case (.cancelling, .cancelled), (.cancelling, .cleaned):
      true
    case (.cancelled, .cleaned):
      true
    default:
      false
    }
  }
}
