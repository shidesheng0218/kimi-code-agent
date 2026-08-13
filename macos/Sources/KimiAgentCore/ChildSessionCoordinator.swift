import Foundation

public enum ChildSessionError: LocalizedError, Equatable {
  case missingSession(UUID)
  case alreadyRunning(UUID)
  case cancelled(UUID)

  public var errorDescription: String? {
    switch self {
    case let .missingSession(id): "找不到 Child Session：\(id)"
    case let .alreadyRunning(id): "Child Session 已经在运行：\(id)"
    case let .cancelled(id): "Child Session 已取消：\(id)"
    }
  }
}

public actor ChildSessionCoordinator {
  public typealias Executor = @Sendable (SessionRecord, String, [ToolDefinition]) async throws -> AgentResult

  private let executor: Executor
  private let onEvent: @Sendable (RuntimeEvent) -> Void
  private let onCancel: @Sendable (UUID) -> Void
  private var sessions: [UUID: SessionRecord] = [:]
  private var prompts: [UUID: String] = [:]
  private var tools: [UUID: [ToolDefinition]] = [:]
  private var results: [UUID: AgentResult] = [:]
  private var cancelledIDs: Set<UUID> = []
  private var eventSequences: [UUID: Int64] = [:]

  public init(
    onEvent: @escaping @Sendable (RuntimeEvent) -> Void = { _ in },
    onCancel: @escaping @Sendable (UUID) -> Void = { _ in },
    executor: @escaping Executor
  ) {
    self.executor = executor
    self.onEvent = onEvent
    self.onCancel = onCancel
  }

  public func createChild(
    parent: SessionRecord,
    taskID: UUID,
    definition: AgentDefinition,
    prompt: String,
    worktreePath: String? = nil
  ) -> SessionRecord {
    let session = SessionRecord(
      taskID: taskID,
      parentID: parent.id,
      agentID: definition.name,
      modelID: definition.model ?? parent.modelID,
      status: .idle,
      worktreePath: worktreePath ?? (definition.isolation == .worktree ? parent.worktreePath : nil)
    )
    sessions[session.id] = session
    eventSequences[session.id] = 0
    prompts[session.id] = prompt
    tools[session.id] = ToolCatalog.defaultDefinitions.filter { tool in
      if definition.deniedTools.contains(tool.id) { return false }
      if definition.allowedTools.isEmpty { return true }
      return definition.allowedTools.contains(tool.id)
    }
    emit(.sessionCreated, session: session)
    return session
  }

  public func run(_ sessionID: UUID) async throws -> AgentResult {
    guard var session = sessions[sessionID], let prompt = prompts[sessionID], let tools = tools[sessionID] else {
      throw ChildSessionError.missingSession(sessionID)
    }
    guard session.status != .running else { throw ChildSessionError.alreadyRunning(sessionID) }
    guard !cancelledIDs.contains(sessionID) else { throw ChildSessionError.cancelled(sessionID) }
    session.status = .running
    session.updatedAt = .now
    sessions[sessionID] = session
    emit(.sessionResumed, session: session)

    do {
      let result = try await executor(session, prompt, tools)
      guard !cancelledIDs.contains(sessionID) else {
        session.status = .cancelled
        sessions[sessionID] = session
        throw ChildSessionError.cancelled(sessionID)
      }
      session.status = .completed
      session.updatedAt = .now
      sessions[sessionID] = session
      results[sessionID] = result
      emit(.messagePartAppended, session: session, payload: try? JSONEncoder().encode(MessagePart(
        sessionID: session.id,
        role: .assistant,
        kind: .text,
        text: result.summary
      )))
      emit(.sessionCompleted, session: session)
      return result
    } catch {
      session.status = cancelledIDs.contains(sessionID) ? .cancelled : .failed
      session.updatedAt = .now
      sessions[sessionID] = session
      emit(session.status == .cancelled ? .sessionPaused : .sessionFailed, session: session)
      throw error
    }
  }

  public func pause(_ sessionID: UUID) {
    guard var session = sessions[sessionID], session.status == .running else { return }
    session.status = .paused
    session.updatedAt = .now
    sessions[sessionID] = session
  }

  public func cancel(_ sessionID: UUID) {
    cancelledIDs.insert(sessionID)
    onCancel(sessionID)
    guard var session = sessions[sessionID], !session.status.isTerminal else { return }
    session.status = .cancelled
    session.updatedAt = .now
    sessions[sessionID] = session
  }

  public func session(id: UUID) -> SessionRecord? {
    sessions[id]
  }

  public func result(id: UUID) -> AgentResult? {
    results[id]
  }

  private func emit(_ kind: RuntimeEventKind, session: SessionRecord, payload: Data? = nil) {
    let next = (eventSequences[session.id] ?? 0) + 1
    eventSequences[session.id] = next
    let resolvedPayload: Data?
    switch kind {
    case .sessionCreated, .sessionResumed, .sessionPaused, .sessionCompleted, .sessionFailed:
      resolvedPayload = payload ?? (try? JSONEncoder().encode(session))
    default:
      resolvedPayload = payload
    }
    onEvent(RuntimeEvent(
      sessionID: session.id,
      taskID: session.taskID,
      parentEventID: session.parentID,
      sequence: next,
      kind: kind,
      payload: resolvedPayload
    ))
  }
}
