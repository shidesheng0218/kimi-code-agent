import Foundation

public struct LaneID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public init(stringLiteral value: String) {
    self.init(rawValue: value)
  }

  public static let main: LaneID = "main"
}

public typealias OperationID = UUID
public typealias EntryID = UUID

/// Defines which execution authority owns a session. Both new and imported
/// sessions use the durable Harness; legacy data is only an import format.
public enum HarnessSessionKind: String, Codable, CaseIterable, Sendable {
  case newSession
  case legacySession
}

public enum HarnessExecutionPath: String, Codable, CaseIterable, Sendable {
  case harness
  case compatibility
}

public struct HarnessRoutePolicy: Sendable {
  public init() {}

  public func path(for session: HarnessSessionKind) -> HarnessExecutionPath {
    _ = session
    return .harness
  }
}

public struct PromptInput: Codable, Equatable, Sendable {
  public let text: String
  public let attachments: [String]

  public init(text: String, attachments: [String] = []) {
    self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    self.attachments = attachments
  }
}

public enum HarnessOperationKind: String, Codable, CaseIterable, Sendable {
  case prompt
  case compaction
  case navigation
}

public enum OperationState: String, Codable, CaseIterable, Sendable {
  case accepted
  case running
  case awaitingPermission
  case awaitingProvider
  case compacting
  case cancelling
  case suspended
  case completed
  case failed
  case aborted

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .aborted: true
    default: false
    }
  }
}

public enum HarnessQueueKind: String, Codable, CaseIterable, Sendable {
  case steer
  case followUp
  case nextRun
}

public enum HarnessEffectKind: String, Codable, CaseIterable, Sendable {
  case provider
  case tool
  case permission
  case hook
  case worktree
  case mcp
  case compaction
}

public enum HarnessEffectOutcome: String, Codable, CaseIterable, Sendable {
  case success
  case failure
  case cancelled
  case unknown
}

public struct HarnessEffectIntent: Codable, Equatable, Identifiable, Sendable {
  public let operationID: OperationID
  public let effectID: UUID
  public let kind: HarnessEffectKind
  public let subject: String
  public let risk: ToolRisk
  public let idempotencyKey: String
  public let createdAt: Date

  public var id: UUID { effectID }

  public init(
    operationID: OperationID,
    effectID: UUID = UUID(),
    kind: HarnessEffectKind,
    subject: String,
    risk: ToolRisk,
    idempotencyKey: String? = nil,
    createdAt: Date = .now
  ) {
    self.operationID = operationID
    self.effectID = effectID
    self.kind = kind
    self.subject = subject
    self.risk = risk
    self.idempotencyKey = idempotencyKey ?? effectID.uuidString
    self.createdAt = createdAt
  }
}

public struct HarnessEffectReceipt: Codable, Equatable, Identifiable, Sendable {
  public let operationID: OperationID
  public let effectID: UUID
  public let outcome: HarnessEffectOutcome
  public let output: String?
  public let errorMessage: String?
  public let settledAt: Date

  public var id: UUID { effectID }

  public init(
    operationID: OperationID,
    effectID: UUID,
    outcome: HarnessEffectOutcome,
    output: String? = nil,
    errorMessage: String? = nil,
    settledAt: Date = .now
  ) {
    self.operationID = operationID
    self.effectID = effectID
    self.outcome = outcome
    self.output = output
    self.errorMessage = errorMessage
    self.settledAt = settledAt
  }
}

public struct HarnessPermissionReceipt: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let operationID: OperationID
  public let requestID: UUID
  public let toolID: String
  public let decision: PermissionDecision
  public let resolvedAt: Date

  public init(
    id: UUID = UUID(),
    operationID: OperationID,
    requestID: UUID,
    toolID: String,
    decision: PermissionDecision,
    resolvedAt: Date = .now
  ) {
    self.id = id
    self.operationID = operationID
    self.requestID = requestID
    self.toolID = toolID
    self.decision = decision
    self.resolvedAt = resolvedAt
  }
}

public struct HarnessOperation: Codable, Equatable, Identifiable, Sendable {
  public let id: OperationID
  public let sessionID: UUID
  public let lane: LaneID
  public let kind: HarnessOperationKind
  public let prompt: PromptInput?
  public let sourceEntryID: EntryID?
  public var state: OperationState
  public var errorMessage: String?
  public let acceptedAt: Date
  public var updatedAt: Date

  public init(
    id: OperationID = UUID(),
    sessionID: UUID,
    lane: LaneID,
    kind: HarnessOperationKind,
    prompt: PromptInput? = nil,
    sourceEntryID: EntryID? = nil,
    state: OperationState = .accepted,
    errorMessage: String? = nil,
    acceptedAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.lane = lane
    self.kind = kind
    self.prompt = prompt
    self.sourceEntryID = sourceEntryID
    self.state = state
    self.errorMessage = errorMessage
    self.acceptedAt = acceptedAt
    self.updatedAt = updatedAt
  }
}

public struct HarnessLaneState: Codable, Equatable, Sendable {
  public let id: LaneID
  public var leafEntryID: EntryID?
  public var activeOperation: OperationID?
  public var queuedSteering: [PromptInput]
  public var queuedFollowUps: [PromptInput]
  public var queuedNextRuns: [PromptInput]

  public init(
    id: LaneID,
    leafEntryID: EntryID? = nil,
    activeOperation: OperationID? = nil,
    queuedSteering: [PromptInput] = [],
    queuedFollowUps: [PromptInput] = [],
    queuedNextRuns: [PromptInput] = []
  ) {
    self.id = id
    self.leafEntryID = leafEntryID
    self.activeOperation = activeOperation
    self.queuedSteering = queuedSteering
    self.queuedFollowUps = queuedFollowUps
    self.queuedNextRuns = queuedNextRuns
  }
}

public enum HarnessEntryKind: String, Codable, CaseIterable, Sendable {
  case user
  case assistant
  case tool
  case artifact
  case compactionSummary
  case legacy
}

public struct HarnessSessionEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: EntryID
  public let parentID: EntryID?
  public let lane: LaneID
  public let kind: HarnessEntryKind
  public let text: String
  public let createdAt: Date

  public init(
    id: EntryID = UUID(),
    parentID: EntryID?,
    lane: LaneID,
    kind: HarnessEntryKind,
    text: String,
    createdAt: Date = .now
  ) {
    self.id = id
    self.parentID = parentID
    self.lane = lane
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
  }
}

public enum HarnessEventKind: String, Codable, CaseIterable, Sendable {
  case operationAccepted
  case operationStateChanged
  case queueEnqueued
  case effectIntentWritten
  case permissionSettled
  case effectStarted
  case effectSettled
  case entryAppended
  case snapshotPublished
}

public struct HarnessEvent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let operationID: OperationID?
  public let lane: LaneID
  public let sequence: Int64
  public let kind: HarnessEventKind
  public let payload: Data?
  public let timestamp: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    operationID: OperationID? = nil,
    lane: LaneID,
    sequence: Int64,
    kind: HarnessEventKind,
    payload: Data? = nil,
    timestamp: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.operationID = operationID
    self.lane = lane
    self.sequence = sequence
    self.kind = kind
    self.payload = payload
    self.timestamp = timestamp
  }
}

public actor HarnessEventStore {
  private let fileURL: URL?
  private var values: [HarnessEvent]
  private var ids: Set<UUID>

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    if let fileURL,
       let data = try? Data(contentsOf: fileURL),
       let text = String(data: data, encoding: .utf8) {
      let decoder = JSONDecoder()
      self.values = text.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(HarnessEvent.self, from: Data($0.utf8)) }
    } else {
      self.values = []
    }
    self.ids = Set(values.map(\.id))
  }

  @discardableResult
  public func append(_ event: HarnessEvent) throws -> HarnessEvent {
    guard !ids.contains(event.id) else { throw HarnessError.duplicateEvent(event.id) }
    let sequence = (values.filter { $0.sessionID == event.sessionID }.map(\.sequence).max() ?? 0) + 1
    let persisted = HarnessEvent(
      id: event.id,
      sessionID: event.sessionID,
      operationID: event.operationID,
      lane: event.lane,
      sequence: sequence,
      kind: event.kind,
      payload: event.payload,
      timestamp: event.timestamp
    )
    values.append(persisted)
    ids.insert(persisted.id)
    guard let fileURL else { return persisted }
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(persisted) + Data([0x0A])
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.close()
    } else {
      try data.write(to: fileURL, options: .atomic)
    }
    return persisted
  }

  public func events(operationID: OperationID) -> [HarnessEvent] {
    values.filter { $0.operationID == operationID }.sorted { $0.sequence < $1.sequence }
  }

  public func events(sessionID: UUID) -> [HarnessEvent] {
    values.filter { $0.sessionID == sessionID }.sorted { $0.sequence < $1.sequence }
  }
}

public struct HarnessSnapshot: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public var lanes: [LaneID: HarnessLaneState]
  public var operations: [OperationID: HarnessOperation]
  public var entries: [HarnessSessionEntry]
  public var intents: [UUID: HarnessEffectIntent]
  public var permissions: [UUID: HarnessPermissionReceipt]
  public var receipts: [UUID: HarnessEffectReceipt]

  public init(
    sessionID: UUID,
    lanes: [LaneID: HarnessLaneState] = [.main: HarnessLaneState(id: .main)],
    operations: [OperationID: HarnessOperation] = [:],
    entries: [HarnessSessionEntry] = [],
    intents: [UUID: HarnessEffectIntent] = [:],
    permissions: [UUID: HarnessPermissionReceipt] = [:],
    receipts: [UUID: HarnessEffectReceipt] = [:]
  ) {
    self.sessionID = sessionID
    self.lanes = lanes
    self.operations = operations
    self.entries = entries
    self.intents = intents
    self.permissions = permissions
    self.receipts = receipts
  }
}

public struct HarnessOperationContext: Sendable {
  public let sessionID: UUID
  public let operationID: OperationID
  public let lane: LaneID
  public let prompt: PromptInput

  public init(sessionID: UUID, operationID: OperationID, lane: LaneID, prompt: PromptInput) {
    self.sessionID = sessionID
    self.operationID = operationID
    self.lane = lane
    self.prompt = prompt
  }
}

public enum HarnessDriverEvent: Sendable {
  case effectIntentWritten(HarnessEffectIntent)
  case permissionSettled(HarnessPermissionReceipt)
  case effectStarted(HarnessEffectIntent)
  case effectSettled(HarnessEffectReceipt)
  case assistantText(String)
  case artifact(String)
}

public enum HarnessError: LocalizedError, Equatable {
  case laneBusy(LaneID, OperationID)
  case missingOperation(OperationID)
  case invalidOperation(OperationID)
  case effectWithoutIntent(UUID)
  case duplicateEvent(UUID)
  case timeout(OperationID)

  public var errorDescription: String? {
    switch self {
    case let .laneBusy(lane, operation): "Lane \(lane.rawValue) 正在执行 Operation \(operation.uuidString)。"
    case let .missingOperation(id): "找不到 Operation：\(id.uuidString)。"
    case let .invalidOperation(id): "Operation 状态不允许该操作：\(id.uuidString)。"
    case let .effectWithoutIntent(id): "Effect \(id.uuidString) 未先写入 intent。"
    case let .duplicateEvent(id): "Harness 事件重复：\(id.uuidString)。"
    case let .timeout(id): "等待 Operation 超时：\(id.uuidString)。"
    }
  }
}

public enum HarnessRecoveryActionKind: String, Codable, CaseIterable, Sendable {
  case resumeOperation
  case retrySafeEffect
  case markUnknownEffect
}

public struct HarnessRecoveryAction: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: HarnessRecoveryActionKind
  public let operationID: OperationID
  public let effectID: UUID?
  public let reason: String

  public init(
    id: UUID = UUID(),
    kind: HarnessRecoveryActionKind,
    operationID: OperationID,
    effectID: UUID? = nil,
    reason: String
  ) {
    self.id = id
    self.kind = kind
    self.operationID = operationID
    self.effectID = effectID
    self.reason = reason
  }
}

public enum HarnessRecoveryEngine {
  public static func actions(for snapshot: HarnessSnapshot) -> [HarnessRecoveryAction] {
    var actions: [HarnessRecoveryAction] = []
    for operation in snapshot.operations.values where !operation.state.isTerminal {
      actions.append(HarnessRecoveryAction(
        kind: .resumeOperation,
        operationID: operation.id,
        reason: "Operation 在应用退出时尚未完成，恢复前保持 suspended。"
      ))
    }
    for intent in snapshot.intents.values where snapshot.receipts[intent.effectID] == nil {
      let kind: HarnessRecoveryActionKind = intent.risk == .low ? .retrySafeEffect : .markUnknownEffect
      actions.append(HarnessRecoveryAction(
        kind: kind,
        operationID: intent.operationID,
        effectID: intent.effectID,
        reason: kind == .retrySafeEffect ? "Effect 没有 receipt，可以安全重试。" : "Effect 没有 receipt，禁止自动重放。"
      ))
    }
    return actions.sorted { $0.operationID.uuidString < $1.operationID.uuidString }
  }
}

public actor AgentHarness {
  public typealias DriverEventSink = @Sendable (HarnessDriverEvent) async -> Void
  public typealias OperationDriver = @Sendable (HarnessOperationContext, @escaping DriverEventSink) async throws -> Void

  private let store: HarnessEventStore
  private let driver: OperationDriver
  private var snapshotValue: HarnessSnapshot
  private var runningTasks: [OperationID: Task<Void, Never>] = [:]
  private var continuations: [UUID: AsyncStream<HarnessEvent>.Continuation] = [:]

  public init(
    sessionID: UUID = UUID(),
    store: HarnessEventStore = HarnessEventStore(),
    driver: @escaping OperationDriver = { _, _ in }
  ) {
    self.store = store
    self.driver = driver
    self.snapshotValue = HarnessSnapshot(sessionID: sessionID)
  }

  public func prompt(_ input: PromptInput, lane: LaneID = .main) async throws -> OperationID {
    guard !input.text.isEmpty else { throw HarnessError.invalidOperation(UUID()) }
    var laneState = snapshotValue.lanes[lane] ?? HarnessLaneState(id: lane)
    if let active = laneState.activeOperation,
       let operation = snapshotValue.operations[active],
       !operation.state.isTerminal {
      throw HarnessError.laneBusy(lane, active)
    }

    let entry = HarnessSessionEntry(parentID: laneState.leafEntryID, lane: lane, kind: .user, text: input.text)
    snapshotValue.entries.append(entry)
    laneState.leafEntryID = entry.id
    let operation = HarnessOperation(
      sessionID: snapshotValue.sessionID,
      lane: lane,
      kind: .prompt,
      prompt: input,
      sourceEntryID: entry.id
    )
    laneState.activeOperation = operation.id
    snapshotValue.lanes[lane] = laneState
    snapshotValue.operations[operation.id] = operation
    try await publish(.entryAppended, operationID: operation.id, lane: lane, payload: try? JSONEncoder().encode(entry))
    try await publish(.operationAccepted, operationID: operation.id, lane: lane, payload: try? JSONEncoder().encode(operation))
    schedule(operation)
    return operation.id
  }

  public func steer(_ input: PromptInput, lane: LaneID) async throws {
    try await enqueue(input, kind: .steer, lane: lane)
  }

  public func followUp(_ input: PromptInput, lane: LaneID) async throws {
    try await enqueue(input, kind: .followUp, lane: lane)
  }

  public func enqueueNextRun(_ input: PromptInput, lane: LaneID) async throws {
    try await enqueue(input, kind: .nextRun, lane: lane)
  }

  public func abort(_ operationID: OperationID) async {
    guard var operation = snapshotValue.operations[operationID], !operation.state.isTerminal else { return }
    operation.state = .cancelling
    operation.updatedAt = .now
    snapshotValue.operations[operationID] = operation
    try? await publish(.operationStateChanged, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(operation))
    runningTasks[operationID]?.cancel()
    operation.state = .aborted
    operation.updatedAt = .now
    snapshotValue.operations[operationID] = operation
    releaseLane(operation)
    try? await publish(.operationStateChanged, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(operation))
  }

  /// Stops the active driver without discarding its durable Operation. The
  /// owning Lane stays reserved so `resume(_:)` can continue from the same
  /// user request after an explicit user action.
  public func suspend(_ operationID: OperationID) async {
    guard var operation = snapshotValue.operations[operationID], !operation.state.isTerminal else { return }
    operation.state = .suspended
    operation.updatedAt = .now
    snapshotValue.operations[operationID] = operation
    try? await publish(.operationStateChanged, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(operation))
    runningTasks[operationID]?.cancel()
  }

  public func resume(_ lane: LaneID) async throws {
    guard let active = snapshotValue.lanes[lane]?.activeOperation,
          var operation = snapshotValue.operations[active] else {
      throw HarnessError.invalidOperation(UUID())
    }
    guard operation.state == .suspended else { throw HarnessError.invalidOperation(active) }
    operation.state = .accepted
    operation.updatedAt = .now
    snapshotValue.operations[active] = operation
    try await publish(.operationStateChanged, operationID: active, lane: lane, payload: try? JSONEncoder().encode(operation))
    schedule(operation)
  }

  public func compact(_ lane: LaneID) async throws -> OperationID {
    let summary = snapshotValue.entries.suffix(8).map(\.text).joined(separator: "\n")
    let entry = HarnessSessionEntry(parentID: snapshotValue.lanes[lane]?.leafEntryID, lane: lane, kind: .compactionSummary, text: summary)
    snapshotValue.entries.append(entry)
    var laneState = snapshotValue.lanes[lane] ?? HarnessLaneState(id: lane)
    laneState.leafEntryID = entry.id
    snapshotValue.lanes[lane] = laneState
    let operation = HarnessOperation(sessionID: snapshotValue.sessionID, lane: lane, kind: .compaction, sourceEntryID: entry.id, state: .completed)
    snapshotValue.operations[operation.id] = operation
    try await publish(.entryAppended, operationID: operation.id, lane: lane, payload: try? JSONEncoder().encode(entry))
    try await publish(.operationAccepted, operationID: operation.id, lane: lane, payload: try? JSONEncoder().encode(operation))
    return operation.id
  }

  public func navigate(_ lane: LaneID, to entryID: EntryID) async throws -> OperationID {
    guard snapshotValue.entries.contains(where: { $0.id == entryID }) else { throw HarnessError.invalidOperation(UUID()) }
    var laneState = snapshotValue.lanes[lane] ?? HarnessLaneState(id: lane)
    guard laneState.activeOperation == nil else { throw HarnessError.laneBusy(lane, laneState.activeOperation!) }
    laneState.leafEntryID = entryID
    snapshotValue.lanes[lane] = laneState
    let operation = HarnessOperation(sessionID: snapshotValue.sessionID, lane: lane, kind: .navigation, sourceEntryID: entryID, state: .completed)
    snapshotValue.operations[operation.id] = operation
    try await publish(.operationAccepted, operationID: operation.id, lane: lane, payload: try? JSONEncoder().encode(operation))
    return operation.id
  }

  public func snapshot() -> HarnessSnapshot {
    snapshotValue
  }

  /// Rebuilds the in-memory projection from durable Harness events. An open
  /// operation is deliberately restored as suspended; the caller must invoke
  /// resume() to cross the next effect boundary.
  public func restore() async throws {
    let events = await store.events(sessionID: snapshotValue.sessionID)
    var restored = HarnessSnapshot(sessionID: snapshotValue.sessionID)
    for event in events {
      switch event.kind {
      case .operationAccepted, .operationStateChanged:
        guard let payload = event.payload,
              let operation = try? JSONDecoder().decode(HarnessOperation.self, from: payload) else { continue }
        restored.operations[operation.id] = operation
        if restored.lanes[operation.lane] == nil { restored.lanes[operation.lane] = HarnessLaneState(id: operation.lane) }
        if !operation.state.isTerminal { restored.lanes[operation.lane]?.activeOperation = operation.id }
      case .entryAppended:
        guard let payload = event.payload,
              let entry = try? JSONDecoder().decode(HarnessSessionEntry.self, from: payload) else { continue }
        if !restored.entries.contains(where: { $0.id == entry.id }) { restored.entries.append(entry) }
        var lane = restored.lanes[entry.lane] ?? HarnessLaneState(id: entry.lane)
        lane.leafEntryID = entry.id
        restored.lanes[entry.lane] = lane
      case .effectIntentWritten:
        guard let payload = event.payload,
              let intent = try? JSONDecoder().decode(HarnessEffectIntent.self, from: payload) else { continue }
        restored.intents[intent.effectID] = intent
      case .permissionSettled:
        guard let payload = event.payload,
              let receipt = try? JSONDecoder().decode(HarnessPermissionReceipt.self, from: payload) else { continue }
        restored.permissions[receipt.requestID] = receipt
      case .effectSettled:
        guard let payload = event.payload,
              let receipt = try? JSONDecoder().decode(HarnessEffectReceipt.self, from: payload) else { continue }
        restored.receipts[receipt.effectID] = receipt
      case .effectStarted, .queueEnqueued, .snapshotPublished:
        continue
      }
    }
    for id in restored.operations.keys {
      guard var operation = restored.operations[id], !operation.state.isTerminal else { continue }
      operation.state = .suspended
      operation.updatedAt = .now
      restored.operations[id] = operation
      restored.lanes[operation.lane]?.activeOperation = operation.id
    }
    snapshotValue = restored
  }

  public func events() -> AsyncStream<HarnessEvent> {
    let token = UUID()
    return AsyncStream { continuation in
      continuations[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(token) }
      }
    }
  }

  public func wait(for operationID: OperationID, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(max(timeout, 0.01))
    while Date() < deadline {
      guard let operation = snapshotValue.operations[operationID] else { throw HarnessError.missingOperation(operationID) }
      if operation.state.isTerminal { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw HarnessError.timeout(operationID)
  }

  private func enqueue(_ input: PromptInput, kind: HarnessQueueKind, lane: LaneID) async throws {
    guard !input.text.isEmpty else { return }
    var laneState = snapshotValue.lanes[lane] ?? HarnessLaneState(id: lane)
    switch kind {
    case .steer:
      guard laneState.activeOperation != nil else { throw HarnessError.invalidOperation(UUID()) }
      laneState.queuedSteering.append(input)
    case .followUp:
      guard laneState.activeOperation != nil else { throw HarnessError.invalidOperation(UUID()) }
      laneState.queuedFollowUps.append(input)
    case .nextRun:
      laneState.queuedNextRuns.append(input)
    }
    snapshotValue.lanes[lane] = laneState
    try await publish(.queueEnqueued, operationID: laneState.activeOperation, lane: lane, payload: try? JSONEncoder().encode(input))
  }

  private func schedule(_ operation: HarnessOperation) {
    runningTasks[operation.id]?.cancel()
    runningTasks[operation.id] = Task { [weak self, driver] in
      await self?.run(operation.id, driver: driver)
    }
  }

  private func run(_ operationID: OperationID, driver: @escaping OperationDriver) async {
    guard var operation = snapshotValue.operations[operationID],
          let prompt = operation.prompt else { return }
    if operation.state == .aborted { return }
    operation.state = .running
    operation.updatedAt = .now
    snapshotValue.operations[operationID] = operation
    try? await publish(.operationStateChanged, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(operation))
    let context = HarnessOperationContext(sessionID: snapshotValue.sessionID, operationID: operationID, lane: operation.lane, prompt: prompt)
    do {
      try await driver(context) { [weak self] event in
        await self?.receive(event, operationID: operationID)
      }
      guard var settled = snapshotValue.operations[operationID], settled.state != .aborted else { return }
      settled.state = .completed
      settled.updatedAt = .now
      snapshotValue.operations[operationID] = settled
      releaseLane(settled)
      try? await publish(.operationStateChanged, operationID: operationID, lane: settled.lane, payload: try? JSONEncoder().encode(settled))
    } catch is CancellationError {
      // abort() already persisted the terminal state before cancelling the task.
    } catch {
      guard var failed = snapshotValue.operations[operationID], failed.state != .aborted else { return }
      failed.state = .failed
      failed.errorMessage = error.localizedDescription
      failed.updatedAt = .now
      snapshotValue.operations[operationID] = failed
      releaseLane(failed)
      try? await publish(.operationStateChanged, operationID: operationID, lane: failed.lane, payload: try? JSONEncoder().encode(failed))
    }
    runningTasks.removeValue(forKey: operationID)
  }

  private func receive(_ event: HarnessDriverEvent, operationID: OperationID) async {
    guard let operation = snapshotValue.operations[operationID], operation.state != .aborted else { return }
    switch event {
    case let .effectIntentWritten(intent):
      guard intent.operationID == operationID else { return }
      snapshotValue.intents[intent.effectID] = intent
      try? await publish(.effectIntentWritten, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(intent))
    case let .permissionSettled(receipt):
      guard receipt.operationID == operationID else { return }
      snapshotValue.permissions[receipt.requestID] = receipt
      try? await publish(.permissionSettled, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(receipt))
    case let .effectStarted(intent):
      guard snapshotValue.intents[intent.effectID] != nil else { return }
      try? await publish(.effectStarted, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(intent))
    case let .effectSettled(receipt):
      guard snapshotValue.intents[receipt.effectID] != nil else { return }
      snapshotValue.receipts[receipt.effectID] = receipt
      try? await publish(.effectSettled, operationID: operationID, lane: operation.lane, payload: try? JSONEncoder().encode(receipt))
    case let .assistantText(text):
      appendEntry(parent: operation.sourceEntryID, lane: operation.lane, kind: .assistant, text: text, operationID: operationID)
    case let .artifact(text):
      appendEntry(parent: snapshotValue.lanes[operation.lane]?.leafEntryID, lane: operation.lane, kind: .artifact, text: text, operationID: operationID)
    }
  }

  private func appendEntry(parent: EntryID?, lane: LaneID, kind: HarnessEntryKind, text: String, operationID: OperationID) {
    let entry = HarnessSessionEntry(parentID: parent, lane: lane, kind: kind, text: text)
    snapshotValue.entries.append(entry)
    var state = snapshotValue.lanes[lane] ?? HarnessLaneState(id: lane)
    state.leafEntryID = entry.id
    snapshotValue.lanes[lane] = state
    Task { [weak self] in
      try? await self?.publish(.entryAppended, operationID: operationID, lane: lane, payload: try? JSONEncoder().encode(entry))
    }
  }

  private func releaseLane(_ operation: HarnessOperation) {
    var lane = snapshotValue.lanes[operation.lane] ?? HarnessLaneState(id: operation.lane)
    if lane.activeOperation == operation.id { lane.activeOperation = nil }
    snapshotValue.lanes[operation.lane] = lane
  }

  private func publish(_ kind: HarnessEventKind, operationID: OperationID?, lane: LaneID, payload: Data?) async throws {
    let event = try await store.append(HarnessEvent(
      sessionID: snapshotValue.sessionID,
      operationID: operationID,
      lane: lane,
      sequence: 0,
      kind: kind,
      payload: payload
    ))
    continuations.values.forEach { $0.yield(event) }
  }

  private func removeContinuation(_ token: UUID) {
    continuations.removeValue(forKey: token)
  }
}
