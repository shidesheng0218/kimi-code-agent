import Foundation

/// The two executable paths exposed by the desktop are deliberately kept
/// behind one Core-owned runtime boundary.  The UI can project the resulting
/// snapshots, but it cannot construct a second provider/tool loop of its own.
public struct AgentKernelRuntime: Sendable {
  public let operationDriver: AgentHarness.OperationDriver
  public let childExecutor: AgentGraphSupervisor.ChildExecutor
  public let onChildSessionEvent: AgentGraphSupervisor.SessionEventSink
  public let onChildCancellation: AgentGraphSupervisor.ChildCancellationSink

  public init(
    operationDriver: @escaping AgentHarness.OperationDriver,
    childExecutor: @escaping AgentGraphSupervisor.ChildExecutor,
    onChildSessionEvent: @escaping AgentGraphSupervisor.SessionEventSink = { _ in },
    onChildCancellation: @escaping AgentGraphSupervisor.ChildCancellationSink = { _ in }
  ) {
    self.operationDriver = operationDriver
    self.childExecutor = childExecutor
    self.onChildSessionEvent = onChildSessionEvent
    self.onChildCancellation = onChildCancellation
  }
}

public struct AgentKernelSnapshot: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let harness: HarnessSnapshot
  public let operations: [OperationID: HarnessOperation]
  public let graphSnapshots: [OperationID: AgentRunSchedulerSnapshot]
  public let handoffs: [OperationID: [UUID: [AgentHandoff]]]

  public init(
    sessionID: UUID,
    harness: HarnessSnapshot = HarnessSnapshot(sessionID: UUID()),
    operations: [OperationID: HarnessOperation] = [:],
    graphSnapshots: [OperationID: AgentRunSchedulerSnapshot] = [:],
    handoffs: [OperationID: [UUID: [AgentHandoff]]] = [:]
  ) {
    self.sessionID = sessionID
    self.harness = harness
    self.operations = operations
    self.graphSnapshots = graphSnapshots
    self.handoffs = handoffs
  }
}

public struct AgentKernelGraphRecord: Codable, Equatable, Sendable {
  public let operationID: OperationID
  public let taskID: UUID
  public let parent: SessionRecord
  public var snapshot: AgentRunSchedulerSnapshot
  public let promptSeed: String
  public var handoffs: [UUID: [AgentHandoff]]

  public init(
    operationID: OperationID,
    taskID: UUID,
    parent: SessionRecord,
    snapshot: AgentRunSchedulerSnapshot,
    promptSeed: String,
    handoffs: [UUID: [AgentHandoff]] = [:]
  ) {
    self.operationID = operationID
    self.taskID = taskID
    self.parent = parent
    self.snapshot = snapshot
    self.promptSeed = promptSeed
    self.handoffs = handoffs
  }
}

public enum AgentKernelEvent: Sendable {
  case harness(HarnessEvent)
  case operationChanged(HarnessOperation)
  case graphSnapshot(operationID: OperationID, snapshot: AgentRunSchedulerSnapshot)
  case childSessionCreated(operationID: OperationID, runID: UUID, session: SessionRecord)
  case handoffPrepared(operationID: OperationID, runID: UUID, handoffs: [AgentHandoff])
  case graphFinished(operationID: OperationID, snapshot: AgentRunSchedulerSnapshot)
}

public enum AgentKernelError: LocalizedError, Equatable {
  case missingOperation(OperationID)
  case timeout(OperationID)

  public var errorDescription: String? {
    switch self {
    case let .missingOperation(id): "找不到统一内核 Operation：\(id.uuidString)"
    case let .timeout(id): "等待统一内核 Operation 超时：\(id.uuidString)"
    }
  }
}

/// The only Core entry point for a normal prompt or a Supervisor graph.
/// `AgentHarness` remains the durable lane/turn runtime and
/// `AgentGraphSupervisor` remains the DAG runtime; this actor owns their
/// lifecycle, operation projection, cancellation and durable graph boundary.
public actor AgentKernel {
  private let sessionID: UUID
  private let store: HarnessEventStore
  private let runtime: AgentKernelRuntime
  private let harness: AgentHarness
  private var operations: [OperationID: HarnessOperation] = [:]
  private var graphSnapshots: [OperationID: AgentRunSchedulerSnapshot] = [:]
  private var graphRecords: [OperationID: AgentKernelGraphRecord] = [:]
  private var graphSupervisors: [OperationID: AgentGraphSupervisor] = [:]
  private var graphTasks: [OperationID: Task<Void, Never>] = [:]
  private var continuations: [UUID: AsyncStream<AgentKernelEvent>.Continuation] = [:]
  private var harnessForwardTask: Task<Void, Never>?

  public init(
    sessionID: UUID = UUID(),
    store: HarnessEventStore = HarnessEventStore(),
    runtime: AgentKernelRuntime
  ) {
    self.sessionID = sessionID
    self.store = store
    self.runtime = runtime
    self.harness = AgentHarness(sessionID: sessionID, store: store, driver: runtime.operationDriver)
  }

  public func prompt(_ input: PromptInput, lane: LaneID = .main) async throws -> OperationID {
    let operationID = try await harness.prompt(input, lane: lane)
    await syncHarnessOperations()
    return operationID
  }

  public func restore() async throws {
    try await harness.restore()
    await syncHarnessOperations()
    let events = await store.events(sessionID: sessionID)
    var records: [OperationID: AgentKernelGraphRecord] = [:]
    for event in events where event.kind == .kernelGraphSnapshot {
      guard let payload = event.payload,
            let record = try? JSONDecoder().decode(AgentKernelGraphRecord.self, from: payload) else { continue }
      records[record.operationID] = record
    }
    for event in events where event.kind == .kernelHandoffPrepared {
      guard let payload = event.payload,
            let record = try? JSONDecoder().decode(AgentKernelGraphRecord.self, from: payload) else { continue }
      records[record.operationID] = record
    }
    for record in records.values {
      graphRecords[record.operationID] = record
      graphSnapshots[record.operationID] = record.snapshot
      guard let operation = operations[record.operationID], !operation.state.isTerminal else { continue }
      let supervisor = AgentGraphSupervisor(
        parent: record.parent,
        snapshot: record.snapshot,
        prompt: { run in
          let prefix = record.promptSeed.isEmpty ? "继续执行父任务" : record.promptSeed
          return prefix + "\n请执行你的阶段：" + run.definition.description
        },
        onEvent: { [weak self] event in
          guard let self else { return }
          Task { await self.receiveGraphEvent(event, operationID: record.operationID) }
        },
        onSessionEvent: runtime.onChildSessionEvent,
        onChildCancellation: runtime.onChildCancellation,
        executor: runtime.childExecutor
      )
      graphSupervisors[record.operationID] = supervisor
    }
  }

  public func resumeMain() async throws {
    try await harness.resume(.main)
    await syncHarnessOperations()
  }

  public func suspendMain() async {
    let snapshot = await harness.snapshot()
    if let operationID = snapshot.lanes[.main]?.activeOperation {
      await harness.suspend(operationID)
      await syncHarnessOperations()
    }
  }

  public func startGraph(
    taskID: UUID,
    parent: SessionRecord,
    runs: [AgentRun],
    prompt: @escaping AgentGraphSupervisor.PromptBuilder,
    maxConcurrent: Int = 8,
    recoveryPrompt: String? = nil
  ) async throws -> OperationID {
    let operation = HarnessOperation(
      sessionID: parent.id,
      lane: .main,
      kind: .prompt,
      prompt: PromptInput(text: "执行 \(runs.count) 个 Child Agent 阶段"),
      state: .accepted
    )
    operations[operation.id] = operation
    graphSnapshots[operation.id] = AgentRunSchedulerSnapshot(
      runs: runs,
      maxConcurrent: maxConcurrent
    )
    graphRecords[operation.id] = AgentKernelGraphRecord(
      operationID: operation.id,
      taskID: taskID,
      parent: parent,
      snapshot: graphSnapshots[operation.id]!,
      promptSeed: recoveryPrompt ?? ""
    )
    try await persist(operation)
    try? await persistGraphRecord(operation.id)
    publish(.operationChanged(operation))

    let supervisor = AgentGraphSupervisor(
      parent: parent,
      runs: runs,
      maxConcurrent: maxConcurrent,
      prompt: prompt,
      onEvent: { [weak self] event in
        guard let self else { return }
        Task { await self.receiveGraphEvent(event, operationID: operation.id) }
      },
      onSessionEvent: runtime.onChildSessionEvent,
      onChildCancellation: runtime.onChildCancellation,
      executor: runtime.childExecutor
    )
    graphSupervisors[operation.id] = supervisor
    var running = operation
    running.state = .running
    running.updatedAt = .now
    operations[operation.id] = running
    try? await persist(running)
    publish(.operationChanged(running))

    scheduleGraph(operationID: operation.id, supervisor: supervisor)
    return operation.id
  }

  /// Imports an interrupted pre-Kernel graph or restores a graph whose
  /// scheduler checkpoint was retained but whose runtime task no longer
  /// exists. Registration is intentionally suspended: no provider or tool
  /// effect is started until `resumeGraph(_:)` is called explicitly.
  public func registerSuspendedGraph(
    taskID: UUID,
    parent: SessionRecord,
    snapshot: AgentRunSchedulerSnapshot,
    recoveryPrompt: String
  ) async throws -> OperationID {
    let operation = HarnessOperation(
      sessionID: parent.id,
      lane: .main,
      kind: .prompt,
      prompt: PromptInput(text: "恢复 " + String(snapshot.runs.count) + " 个 Child Agent 阶段"),
      state: .suspended
    )
    let supervisor = AgentGraphSupervisor(
      parent: parent,
      snapshot: snapshot,
      prompt: { run in
        recoveryPrompt + "\n请执行你的阶段：" + run.definition.description
      },
      onEvent: { [weak self] event in
        guard let self else { return }
        Task { await self.receiveGraphEvent(event, operationID: operation.id) }
      },
      onSessionEvent: runtime.onChildSessionEvent,
      onChildCancellation: runtime.onChildCancellation,
      executor: runtime.childExecutor
    )
    let restoredSnapshot = await supervisor.snapshot()
    operations[operation.id] = operation
    graphSupervisors[operation.id] = supervisor
    graphSnapshots[operation.id] = restoredSnapshot
    graphRecords[operation.id] = AgentKernelGraphRecord(
      operationID: operation.id,
      taskID: taskID,
      parent: parent,
      snapshot: restoredSnapshot,
      promptSeed: recoveryPrompt
    )
    try await persist(operation)
    try await persistGraphRecord(operation.id)
    publish(.operationChanged(operation))
    publish(.graphSnapshot(operationID: operation.id, snapshot: restoredSnapshot))
    return operation.id
  }

  private func scheduleGraph(operationID: OperationID, supervisor: AgentGraphSupervisor) {
    guard graphTasks[operationID] == nil else { return }
    graphTasks[operationID] = Task { [weak self, supervisor] in
      do {
        let runs = try await supervisor.run()
        let state: OperationState
        if runs.contains(where: { $0.state == .failed }) {
          state = .failed
        } else if runs.allSatisfy({ $0.state == .completed || $0.state == .cancelled }) {
          state = .completed
        } else {
          state = .suspended
        }
        await self?.finishGraph(
          operationID: operationID,
          state: state,
          errorMessage: state == .failed ? "一个或多个 Child Agent 阶段失败。" : nil
        )
      } catch is CancellationError {
        await self?.finishGraph(operationID: operationID, state: .aborted, errorMessage: "Child Graph 已取消。")
      } catch {
        await self?.finishGraph(operationID: operationID, state: .failed, errorMessage: error.localizedDescription)
      }
    }
  }

  private func scheduleGraphIfNeeded(_ operationID: OperationID) async {
    guard graphTasks[operationID] == nil,
          let supervisor = graphSupervisors[operationID],
          let operation = operations[operationID],
          !operation.state.isTerminal else { return }
    var running = operation
    running.state = .running
    running.updatedAt = .now
    operations[operationID] = running
    try? await persist(running)
    publish(.operationChanged(running))
    scheduleGraph(operationID: operationID, supervisor: supervisor)
  }

  public func cancel(_ operationID: OperationID) async {
    if let supervisor = graphSupervisors[operationID] {
      await supervisor.cancelAll()
      graphTasks[operationID]?.cancel()
      await finishGraph(operationID: operationID, state: .aborted, errorMessage: "Child Graph 已取消。")
      return
    }
    await harness.abort(operationID)
    await syncHarnessOperations()
  }

  public func pauseGraph(_ operationID: OperationID, runID: UUID) async {
    await graphSupervisors[operationID]?.pause(runID)
    await refreshGraph(operationID)
  }

  public func cancelGraphRun(_ operationID: OperationID, runID: UUID) async {
    await graphSupervisors[operationID]?.cancel(runID)
    await refreshGraph(operationID)
  }

  public func continueGraph(_ operationID: OperationID, runID: UUID) async {
    await graphSupervisors[operationID]?.continueRun(runID)
    await refreshGraph(operationID)
    await scheduleGraphIfNeeded(operationID)
  }

  public func retryGraph(_ operationID: OperationID, runID: UUID) async {
    await graphSupervisors[operationID]?.retry(runID)
    await refreshGraph(operationID)
    await scheduleGraphIfNeeded(operationID)
  }

  public func resumeGraph(_ operationID: OperationID) async {
    guard let supervisor = graphSupervisors[operationID] else { return }
    let snapshot = await supervisor.snapshot()
    for run in snapshot.runs where run.state == .paused || run.state == .interrupted {
      await supervisor.continueRun(run.id)
    }
    await refreshGraph(operationID)
    await scheduleGraphIfNeeded(operationID)
  }

  public func events() async -> AsyncStream<AgentKernelEvent> {
    if harnessForwardTask == nil {
      let stream = await harness.events()
      harnessForwardTask = Task { [weak self] in
        for await event in stream {
          guard let self else { return }
          await self.publish(.harness(event))
        }
      }
    }
    let token = UUID()
    return AsyncStream { continuation in
      continuations[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(token) }
      }
    }
  }

  public func wait(_ operationID: OperationID, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(max(timeout, 0.01))
    while Date() < deadline {
      await syncHarnessOperations()
      guard let operation = operations[operationID] else {
        throw AgentKernelError.missingOperation(operationID)
      }
      if operation.state.isTerminal { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw AgentKernelError.timeout(operationID)
  }

  public func snapshot() async -> AgentKernelSnapshot {
    await syncHarnessOperations()
    return AgentKernelSnapshot(
      sessionID: sessionID,
      harness: await harness.snapshot(),
      operations: operations,
      graphSnapshots: graphSnapshots,
      handoffs: Dictionary(uniqueKeysWithValues: graphRecords.map { ($0.key, $0.value.handoffs) })
    )
  }

  /// Composes a graph answer from the Kernel-owned durable scheduler snapshot.
  /// The desktop projection may lag by a UI frame, so it must never aggregate
  /// directly from its own task dictionary when deciding whether a graph is
  /// complete or whether specialized stages have receipts.
  public func finalAnswer(
    for operationID: OperationID,
    contract: TaskContract,
    requestedLanguage: ResponseLanguage = .chinese
  ) throws -> AgentAggregationResult {
    guard let snapshot = graphSnapshots[operationID] else {
      throw AgentKernelError.missingOperation(operationID)
    }
    return AgentResultMerger.merge(
      runs: snapshot.runs,
      contract: contract,
      requestedLanguage: requestedLanguage
    )
  }

  private func receiveGraphEvent(_ event: AgentGraphSupervisorEvent, operationID: OperationID) async {
    switch event {
    case let .schedulerSnapshot(snapshot):
      graphSnapshots[operationID] = snapshot
      graphRecords[operationID]?.snapshot = snapshot
      try? await persistGraphRecord(operationID)
      publish(.graphSnapshot(operationID: operationID, snapshot: snapshot))
    case let .childSessionCreated(runID, session):
      publish(.childSessionCreated(operationID: operationID, runID: runID, session: session))
    case let .handoffPrepared(runID, handoffs):
      graphRecords[operationID]?.handoffs[runID] = handoffs
      try? await persistHandoffRecord(operationID)
      publish(.handoffPrepared(operationID: operationID, runID: runID, handoffs: handoffs))
    case let .graphFinished(snapshot):
      graphSnapshots[operationID] = snapshot
      graphRecords[operationID]?.snapshot = snapshot
      try? await persistGraphRecord(operationID)
      publish(.graphFinished(operationID: operationID, snapshot: snapshot))
    }
  }

  private func finishGraph(
    operationID: OperationID,
    state: OperationState,
    errorMessage: String?
  ) async {
    guard var operation = operations[operationID], !operation.state.isTerminal else { return }
    operation.state = state
    operation.errorMessage = errorMessage
    operation.updatedAt = .now
    operations[operationID] = operation
    if let supervisor = graphSupervisors[operationID] {
      graphSnapshots[operationID] = await supervisor.snapshot()
      graphRecords[operationID]?.snapshot = graphSnapshots[operationID]!
      graphRecords[operationID]?.handoffs = await supervisor.handoffs()
    }
    try? await persistGraphRecord(operationID)
    try? await persist(operation)
    publish(.operationChanged(operation))
    graphTasks.removeValue(forKey: operationID)
  }

  private func refreshGraph(_ operationID: OperationID) async {
    guard let supervisor = graphSupervisors[operationID] else { return }
    let snapshot = await supervisor.snapshot()
    graphSnapshots[operationID] = snapshot
    publish(.graphSnapshot(operationID: operationID, snapshot: snapshot))
  }

  private func syncHarnessOperations() async {
    let snapshot = await harness.snapshot()
    for operation in snapshot.operations.values {
      operations[operation.id] = operation
    }
  }

  private func persist(_ operation: HarnessOperation) async throws {
    try await store.append(HarnessEvent(
      sessionID: operation.sessionID,
      operationID: operation.id,
      lane: operation.lane,
      sequence: 0,
      kind: operation.state == .accepted ? .operationAccepted : .operationStateChanged,
      payload: try JSONEncoder().encode(operation)
    ))
  }

  private func persistGraphRecord(_ operationID: OperationID) async throws {
    guard let record = graphRecords[operationID] else { return }
    try await store.append(HarnessEvent(
      sessionID: record.parent.id,
      operationID: operationID,
      lane: .main,
      sequence: 0,
      kind: .kernelGraphSnapshot,
      payload: try JSONEncoder().encode(record)
    ))
  }

  private func persistHandoffRecord(_ operationID: OperationID) async throws {
    guard let record = graphRecords[operationID] else { return }
    try await store.append(HarnessEvent(
      sessionID: record.parent.id,
      operationID: operationID,
      lane: .main,
      sequence: 0,
      kind: .kernelHandoffPrepared,
      payload: try JSONEncoder().encode(record)
    ))
  }

  private func publish(_ event: AgentKernelEvent) {
    continuations.values.forEach { $0.yield(event) }
  }

  private func removeContinuation(_ token: UUID) {
    continuations.removeValue(forKey: token)
  }
}
