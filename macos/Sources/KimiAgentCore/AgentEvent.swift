import Foundation

public enum AgentEventKind: String, Codable, CaseIterable, Sendable {
  case sessionCreated
  case sessionResumed
  case sessionPaused
  case sessionCancelled
  case sessionCompleted
  case taskPlanned
  case taskStarted
  case taskBlocked
  case taskFailed
  case taskReviewReady
  case taskVerified
  case toolRequested
  case toolStarted
  case toolProgress
  case toolFinished
  case fileRead
  case fileCreated
  case fileChanged
  case fileDeleted
  case fileRenamed
  case commandRequested
  case commandApproved
  case commandStarted
  case commandFinished
  case testStarted
  case testFinished
  case permissionRequested
  case permissionApproved
  case permissionDenied
  case permissionExpired
  case diffGenerated
  case diffCommented
  case hunkAccepted
  case hunkRejected
  case verificationStarted
  case verificationStepFinished
  case verificationFailed
  case verificationPassed
  case browserOpened
  case browserClicked
  case browserTyped
  case browserScreenshot
  case browserConsoleError
  case output
  case error
}

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let taskID: UUID
  public let turnID: UUID?
  public let workItemID: UUID?
  public let sequence: Int64
  public let timestamp: Date
  public let actor: String
  public let kind: AgentEventKind
  public let payload: [String: String]
  public let requiresApproval: Bool

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    taskID: UUID,
    turnID: UUID? = nil,
    workItemID: UUID? = nil,
    sequence: Int64,
    timestamp: Date = .now,
    actor: String,
    kind: AgentEventKind,
    payload: [String: String] = [:],
    requiresApproval: Bool = false
  ) {
    self.id = id
    self.sessionID = sessionID
    self.taskID = taskID
    self.turnID = turnID
    self.workItemID = workItemID
    self.sequence = sequence
    self.timestamp = timestamp.roundedToMilliseconds
    self.actor = actor
    self.kind = kind
    self.payload = payload
    self.requiresApproval = requiresApproval
  }

  public func assigningTurn(_ turnID: UUID?) -> AgentEvent {
    AgentEvent(
      id: id,
      sessionID: sessionID,
      taskID: taskID,
      turnID: turnID,
      workItemID: workItemID,
      sequence: sequence,
      timestamp: timestamp,
      actor: actor,
      kind: kind,
      payload: payload,
      requiresApproval: requiresApproval
    )
  }
}

private extension Date {
  var roundedToMilliseconds: Date {
    Date(timeIntervalSince1970: (timeIntervalSince1970 * 1_000).rounded() / 1_000)
  }
}
