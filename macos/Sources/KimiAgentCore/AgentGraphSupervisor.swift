import Foundation

/// Events emitted by the Core-owned graph runtime. The desktop projects these
/// events into SwiftUI state but never decides which node may run next.
public enum AgentGraphSupervisorEvent: Sendable {
  case schedulerSnapshot(AgentRunSchedulerSnapshot)
  case childSessionCreated(runID: UUID, session: SessionRecord)
  case handoffPrepared(runID: UUID, handoffs: [AgentHandoff])
  case graphFinished(AgentRunSchedulerSnapshot)
}

public enum AgentGraphSupervisorError: LocalizedError, Equatable {
  case alreadyDriving

  public var errorDescription: String? {
    switch self {
    case .alreadyDriving: "该 Agent Graph 已在运行。"
    }
  }
}

/// Owns the executable lifecycle of a Supervisor DAG. It composes the durable
/// scheduler with isolated Child Sessions so callers only supply the actual
/// Harness-bound model/tool executor and consume snapshots/events.
public actor AgentGraphSupervisor {
  public typealias PromptBuilder = @Sendable (AgentRun) -> String
  public typealias ChildExecutor = @Sendable (AgentRun, SessionRecord, String, [ToolDefinition]) async throws -> AgentResult
  public typealias EventSink = @Sendable (AgentGraphSupervisorEvent) -> Void
  public typealias SessionEventSink = @Sendable (RuntimeEvent) -> Void
  public typealias ChildCancellationSink = @Sendable (UUID) -> Void

  private let parent: SessionRecord
  private let promptBuilder: PromptBuilder
  private let childExecutor: ChildExecutor
  private let onEvent: EventSink
  private let onSessionEvent: SessionEventSink
  private let onChildCancellation: ChildCancellationSink
  private let maxConcurrent: Int
  private let scheduler: AgentRunScheduler
  private var coordinators: [UUID: ChildSessionCoordinator] = [:]
  private var childSessionIDs: [UUID: UUID] = [:]
  private var handoffsByRunID: [UUID: [AgentHandoff]] = [:]
  private var isDriving = false

  public init(
    parent: SessionRecord,
    runs: [AgentRun],
    maxConcurrent: Int = 8,
    prompt: @escaping PromptBuilder,
    onEvent: @escaping EventSink = { _ in },
    onSessionEvent: @escaping SessionEventSink = { _ in },
    onChildCancellation: @escaping ChildCancellationSink = { _ in },
    executor: @escaping ChildExecutor
  ) {
    self.parent = parent
    self.promptBuilder = prompt
    self.childExecutor = executor
    self.onEvent = onEvent
    self.onSessionEvent = onSessionEvent
    self.onChildCancellation = onChildCancellation
    self.maxConcurrent = min(max(maxConcurrent, 1), 8)
    self.scheduler = AgentRunScheduler(runs: runs, maxConcurrent: maxConcurrent)
  }

  public init(
    parent: SessionRecord,
    snapshot: AgentRunSchedulerSnapshot,
    prompt: @escaping PromptBuilder,
    onEvent: @escaping EventSink = { _ in },
    onSessionEvent: @escaping SessionEventSink = { _ in },
    onChildCancellation: @escaping ChildCancellationSink = { _ in },
    executor: @escaping ChildExecutor
  ) {
    self.parent = parent
    self.promptBuilder = prompt
    self.childExecutor = executor
    self.onEvent = onEvent
    self.onSessionEvent = onSessionEvent
    self.onChildCancellation = onChildCancellation
    self.maxConcurrent = snapshot.maxConcurrent
    self.scheduler = AgentRunScheduler(snapshot: snapshot)
  }

  /// Drives every currently runnable DAG node. Callers may invoke it again
  /// after an explicit pause/resume or retry; scheduler state stays inside the
  /// supervisor and never has to be reconstructed by the UI.
  public func run() async throws -> [AgentRun] {
    guard !isDriving else { throw AgentGraphSupervisorError.alreadyDriving }
    isDriving = true
    defer { isDriving = false }

    let runs = try await scheduler.drive(
      execute: { [weak self] run in
        guard let self else { throw CancellationError() }
        return try await self.execute(run)
      },
      onUpdate: { [onEvent, maxConcurrent] runs in
        onEvent(.schedulerSnapshot(AgentRunSchedulerSnapshot(runs: runs, maxConcurrent: maxConcurrent)))
      }
    )
    onEvent(.graphFinished(AgentRunSchedulerSnapshot(runs: runs, maxConcurrent: maxConcurrent)))
    return runs
  }

  public func snapshot() async -> AgentRunSchedulerSnapshot {
    await scheduler.snapshotRecord()
  }

  /// Returns the durable upstream results prepared for each dependent Child
  /// Session.  The Kernel uses this when settling a graph so a late UI event
  /// can never make an already-completed graph lose its handoff record.
  public func handoffs() -> [UUID: [AgentHandoff]] {
    handoffsByRunID
  }

  public func pause(_ runID: UUID) async {
    await scheduler.pause(runID)
    if let coordinator = coordinators[runID], let sessionID = childSessionIDs[runID] {
      await coordinator.pause(sessionID)
    }
    await publishSnapshot()
  }

  public func continueRun(_ runID: UUID) async {
    if let coordinator = coordinators[runID], let sessionID = childSessionIDs[runID] {
      await coordinator.resume(sessionID)
    }
    await scheduler.resume(runID)
    await publishSnapshot()
  }

  public func resume(_ runID: UUID) async {
    await continueRun(runID)
  }

  public func retry(_ runID: UUID) async {
    await scheduler.retry(runID)
    await publishSnapshot()
  }

  public func cancel(_ runID: UUID) async {
    await scheduler.cancel(runID)
    if let coordinator = coordinators[runID], let sessionID = childSessionIDs[runID] {
      await coordinator.cancel(sessionID)
    }
    await publishSnapshot()
  }

  public func cancelAll() async {
    let runs = await scheduler.snapshot()
    for run in runs where !run.state.isTerminal {
      await cancel(run.id)
    }
  }

  private func execute(_ run: AgentRun) async throws -> AgentResult {
    if let coordinator = coordinators[run.id], let sessionID = childSessionIDs[run.id] {
      return try await coordinator.run(sessionID)
    }

    let upstreamRuns = await scheduler.snapshot().filter { run.dependencies.contains($0.id) && $0.state == .completed }
    let handoffs = upstreamRuns.compactMap { upstream -> AgentHandoff? in
      guard let result = upstream.result else { return nil }
      return AgentHandoff(sourceRunID: upstream.id, targetRunID: run.id, result: result)
    }
    handoffsByRunID[run.id] = handoffs
    if !handoffs.isEmpty { onEvent(.handoffPrepared(runID: run.id, handoffs: handoffs)) }
    let resolvedPrompt: String
    if handoffs.isEmpty {
      resolvedPrompt = promptBuilder(run)
    } else {
      resolvedPrompt = promptBuilder(run) + "\n\n" + handoffs.map(\.promptSection).joined(separator: "\n\n")
    }

    let coordinator = ChildSessionCoordinator(
      onEvent: onSessionEvent,
      onCancel: onChildCancellation,
      executor: { [childExecutor] session, prompt, tools in
        try await childExecutor(run, session, prompt, tools)
      }
    )
    coordinators[run.id] = coordinator
    let session = await coordinator.createChild(
      parent: parent,
      taskID: run.taskID,
      definition: run.definition,
      prompt: resolvedPrompt,
      worktreePath: run.worktreePath
    )
    childSessionIDs[run.id] = session.id
    await scheduler.attachChildSession(session.id, to: run.id)
    onEvent(.childSessionCreated(runID: run.id, session: session))
    await publishSnapshot()
    return try await coordinator.run(session.id)
  }

  private func publishSnapshot() async {
    let snapshot = await scheduler.snapshotRecord()
    onEvent(.schedulerSnapshot(snapshot))
  }
}
