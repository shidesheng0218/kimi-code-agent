import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
  case idle
  case running
  case paused
  case awaitingApproval
  case completed
  case failed
  case cancelled
  case interrupted

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled: true
    case .idle, .running, .paused, .awaitingApproval, .interrupted: false
    }
  }
}

public enum MessagePartRole: String, Codable, CaseIterable, Sendable {
  case user
  case assistant
  case system
  case tool
}

public enum MessagePartKind: String, Codable, CaseIterable, Sendable {
  case text
  case reasoning
  case toolCall
  case toolResult
  case permission
  case question
  case patch
  case artifact
  case stepStart
  case stepFinish
  case error
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID
  public let parentID: UUID?
  public let agentID: String
  public let modelID: String?
  public var status: SessionStatus
  public var worktreePath: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    parentID: UUID? = nil,
    agentID: String,
    modelID: String? = nil,
    status: SessionStatus = .idle,
    worktreePath: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.taskID = taskID
    self.parentID = parentID
    self.agentID = agentID
    self.modelID = modelID
    self.status = status
    self.worktreePath = worktreePath
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct MessagePart: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let role: MessagePartRole
  public let kind: MessagePartKind
  public let text: String?
  public let toolName: String?
  public let toolCallID: String?
  public let payload: Data?
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    role: MessagePartRole,
    kind: MessagePartKind,
    text: String? = nil,
    toolName: String? = nil,
    toolCallID: String? = nil,
    payload: Data? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.role = role
    self.kind = kind
    self.text = text
    self.toolName = toolName
    self.toolCallID = toolCallID
    self.payload = payload
    self.createdAt = createdAt
  }

  public static func text(sessionID: UUID, role: MessagePartRole, text: String) -> MessagePart {
    MessagePart(sessionID: sessionID, role: role, kind: .text, text: text)
  }
}

public enum RuntimeEventKind: String, Codable, CaseIterable, Sendable {
  case sessionCreated
  case sessionResumed
  case sessionPaused
  case sessionCompleted
  case sessionFailed
  case messagePartAppended
  case messagePartUpdated
  case agentRunUpdated
  case permissionRequested
  case permissionResolved
  case artifactCreated
}

public struct RuntimeEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let taskID: UUID
  public let parentEventID: UUID?
  public let sequence: Int64
  public let kind: RuntimeEventKind
  public let payload: Data?
  public let timestamp: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    taskID: UUID,
    parentEventID: UUID? = nil,
    sequence: Int64,
    kind: RuntimeEventKind,
    payload: Data? = nil,
    timestamp: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.taskID = taskID
    self.parentEventID = parentEventID
    self.sequence = sequence
    self.kind = kind
    self.payload = payload
    self.timestamp = timestamp
  }
}

public enum SessionEventStoreError: LocalizedError, Equatable {
  case sequenceConflict(sessionID: UUID, expected: Int64, actual: Int64)
  case duplicateEvent(UUID)

  public var errorDescription: String? {
    switch self {
    case let .sequenceConflict(sessionID, expected, actual):
      "Session \(sessionID) 事件序号冲突：期望 \(expected)，收到 \(actual)。"
    case let .duplicateEvent(id):
      "事件 \(id) 已经写入。"
    }
  }
}

public actor SessionEventStore {
  private let fileURL: URL?
  private var allEvents: [RuntimeEvent]
  private var eventIDs: Set<UUID>

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    if let fileURL,
       let data = try? Data(contentsOf: fileURL),
       let text = String(data: data, encoding: .utf8) {
      let decoder = JSONDecoder()
      self.allEvents = text.split(whereSeparator: \.isNewline).compactMap { line in
        try? decoder.decode(RuntimeEvent.self, from: Data(line.utf8))
      }
    } else {
      self.allEvents = []
    }
    self.eventIDs = Set(self.allEvents.map(\.id))
  }

  public func append(_ event: RuntimeEvent) throws {
    guard !eventIDs.contains(event.id) else { throw SessionEventStoreError.duplicateEvent(event.id) }
    let sessionEvents = allEvents.filter { $0.sessionID == event.sessionID }
    let expected = sessionEvents.last.map { $0.sequence + 1 } ?? event.sequence
    guard event.sequence == expected else {
      throw SessionEventStoreError.sequenceConflict(sessionID: event.sessionID, expected: expected, actual: event.sequence)
    }
    allEvents.append(event)
    eventIDs.insert(event.id)
    guard let fileURL else { return }
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(event) + Data([0x0A])
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } else {
      try data.write(to: fileURL, options: .atomic)
    }
  }

  /// Persists a runtime event with the next valid sequence for its session.
  /// ACP, CLI, and plugin transports all maintain their own local sequences, so
  /// the durable session journal is the single authority for replay ordering.
  @discardableResult
  public func appendNext(_ event: RuntimeEvent) throws -> RuntimeEvent {
    let nextSequence = (allEvents
      .filter { $0.sessionID == event.sessionID }
      .map(\.sequence)
      .max() ?? 0) + 1
    let rebased = RuntimeEvent(
      id: event.id,
      sessionID: event.sessionID,
      taskID: event.taskID,
      parentEventID: event.parentEventID,
      sequence: nextSequence,
      kind: event.kind,
      payload: event.payload,
      timestamp: event.timestamp
    )
    try append(rebased)
    return rebased
  }

  public func events(sessionID: UUID) -> [RuntimeEvent] {
    allEvents.filter { $0.sessionID == sessionID }.sorted { $0.sequence < $1.sequence }
  }

  public func all() -> [RuntimeEvent] {
    allEvents
  }

  /// Replays every known session. Callers can use this at launch to restore
  /// conversations without treating the compatibility state file as the source
  /// of truth.
  public func snapshots() -> [UUID: SessionSnapshot] {
    Dictionary(uniqueKeysWithValues: Dictionary(grouping: allEvents, by: \.sessionID).map { sessionID, events in
      (sessionID, SessionProjector.replay(events))
    })
  }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
  public var session: SessionRecord?
  public var parts: [MessagePart]
  public var pendingPermissionIDs: [UUID]

  public init(session: SessionRecord? = nil, parts: [MessagePart] = [], pendingPermissionIDs: [UUID] = []) {
    self.session = session
    self.parts = parts
    self.pendingPermissionIDs = pendingPermissionIDs
  }
}

public enum SessionProjector {
  public static func replay(_ events: [RuntimeEvent]) -> SessionSnapshot {
    var snapshot = SessionSnapshot()
    for event in events.sorted(by: { $0.sequence < $1.sequence }) {
      switch event.kind {
      case .sessionCreated, .sessionResumed, .sessionPaused, .sessionCompleted, .sessionFailed:
        if let payload = event.payload, var session = try? JSONDecoder().decode(SessionRecord.self, from: payload) {
          switch event.kind {
          case .sessionResumed: session.status = .running
          case .sessionPaused: session.status = .paused
          case .sessionCompleted: session.status = .completed
          case .sessionFailed: session.status = .failed
          default: break
          }
          snapshot.session = session
        }
      case .messagePartAppended, .messagePartUpdated:
        guard let payload = event.payload, let part = try? JSONDecoder().decode(MessagePart.self, from: payload) else { continue }
        if let index = snapshot.parts.firstIndex(where: { $0.id == part.id }) {
          snapshot.parts[index] = part
        } else {
          snapshot.parts.append(part)
        }
      case .permissionRequested:
        snapshot.pendingPermissionIDs.append(event.id)
      case .permissionResolved:
        snapshot.pendingPermissionIDs.removeAll { $0 == event.id }
      case .agentRunUpdated, .artifactCreated:
        break
      }
    }
    return snapshot
  }
}
