import Foundation

public actor OpenCodeOperationDriver {
  private let client: any OpenCodeSessionClient
  private var sessionID: String?

  public init(client: any OpenCodeSessionClient) {
    self.client = client
  }

  public func setSession(_ sessionID: String) {
    self.sessionID = sessionID
  }

  public func run(
    context: HarnessOperationContext,
    sink: @escaping AgentHarness.DriverEventSink
  ) async throws {
    guard let sessionID else {
      throw OpenCodeRuntimeError.requestFailed("当前没有可用的 OpenCode Session。")
    }
    let turnID = UUID()
    await sink(.turnStarted(HarnessTurnRecord(turnID: turnID, modelID: "kimi-k2.7-code")))
    await sink(.stepStarted(HarnessStepRecord(turnID: turnID, step: 1)))
    let events = try await client.subscribeEvents(sessionID: sessionID)
    try await client.prompt(OpenCodePromptInput(sessionID: sessionID, text: context.prompt.text))
    try await Self.waitForCompletion(events)
    await sink(.stepEnded(HarnessStepRecord(turnID: turnID, step: 1, status: .completed)))
    await sink(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: "kimi-k2.7-code", status: .completed)))
  }

  private static func waitForCompletion(
    _ events: AsyncThrowingStream<OpenCodeEvent, Error>,
    timeout: Duration = .seconds(300)
  ) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for try await event in events {
          switch event.kind {
          case .sessionIdle:
            return
          case .error:
            throw OpenCodeRuntimeError.requestFailed(event.text ?? "OpenCode Session 执行失败。")
          default:
            continue
          }
        }
        throw OpenCodeRuntimeError.requestFailed("OpenCode Session 事件流在完成前中断。")
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw OpenCodeRuntimeError.requestFailed("OpenCode Session 在规定时间内没有进入 idle。")
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }
}

/// The native application owns the UI projection and sends all user intent
/// through this actor. OpenCode remains the headless execution service; the
/// Harness records the operation boundary and provides recovery semantics.
public actor KimiAppKernel {
  private let sessionClient: any OpenCodeSessionClient
  private let runtimeSupervisor: OpenCodeRuntimeSupervisor?
  private let operationDriver: OpenCodeOperationDriver
  private let harness: AgentHarness
  private let stateStore: KimiAppStateStore?
  private let harnessSessionID: UUID
  private var state: KimiUIState
  private var operationSessions: [OperationID: String] = [:]
  private var sessionOperations: [String: OperationID] = [:]
  private var permissionOperations: [UUID: OperationID] = [:]
  private var effectByToolCall: [String: UUID] = [:]
  private var eventTasks: [String: Task<Void, Never>] = [:]
  private var continuations: [UUID: AsyncStream<KimiEvent>.Continuation] = [:]

  public init(
    sessionClient: any OpenCodeSessionClient = UnavailableOpenCodeSessionClient(),
    runtimeSupervisor: OpenCodeRuntimeSupervisor? = nil,
    sessionID: UUID = UUID(),
    persistence: KimiAppStateStore? = nil,
    harnessStore: HarnessEventStore? = nil
  ) {
    self.sessionClient = sessionClient
    self.runtimeSupervisor = runtimeSupervisor
    self.stateStore = persistence
    let restored = persistence.flatMap { try? $0.load() }
    let resolvedHarnessSessionID = restored?.harnessSessionID ?? sessionID
    self.harnessSessionID = resolvedHarnessSessionID
    let driver = OpenCodeOperationDriver(client: sessionClient)
    self.operationDriver = driver
    self.harness = AgentHarness(
      sessionID: resolvedHarnessSessionID,
      store: harnessStore ?? HarnessEventStore(),
      driver: { context, sink in
        try await driver.run(context: context, sink: sink)
      }
    )
    self.state = restored?.uiState ?? KimiUIState()
  }

  public func snapshot() -> KimiUIState {
    state
  }

  public func events() -> AsyncStream<KimiEvent> {
    let token = UUID()
    return AsyncStream { continuation in
      continuations[token] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeContinuation(token) }
      }
    }
  }

  public func startRuntime() async {
    try? await harness.restore()
    guard let runtimeSupervisor else {
      state.runtimeState = .degraded
      state.lastError = "OpenCode Headless Runtime 尚未打包或未配置。"
      publish(.runtimeChanged(.degraded))
      publish(.error(state.lastError ?? "OpenCode Headless Runtime 尚未连接。"))
      persistState()
      return
    }
    do {
      _ = try await runtimeSupervisor.start()
      try await runtimeSupervisor.waitUntilReady()
      state.runtimeState = .ready
      publish(.runtimeChanged(.ready))
      await restoreRuntimeSessions()
      if let activeID = state.activeSessionID,
         let runtimeID = state.sessions.first(where: { $0.id == activeID })?.runtimeID {
        try? await watch(sessionID: runtimeID)
      }
      persistState()
    } catch {
      state.runtimeState = .failed
      state.lastError = error.localizedDescription
      publish(.error(error.localizedDescription))
      persistState()
    }
  }

  public func send(_ command: KimiAppCommand) async throws {
    switch command {
    case .createSession:
      let session = try await sessionClient.createSession(CreateSessionInput())
      let summary = KimiSessionSummary(id: UUID(), runtimeID: session.id, title: session.title ?? "新会话", projectPath: session.directory)
      state.sessions.insert(summary, at: 0)
      state.activeSessionID = summary.id
      state.messages.removeAll()
      state.activities.removeAll()
      try await watch(sessionID: session.id)
      publish(.sessionChanged(summary))

    case let .selectSession(id):
      guard state.sessions.contains(where: { $0.id == id }) else { return }
      state.activeSessionID = id
      state.messages.removeAll()
      state.activities.removeAll()
      let runtimeID = state.sessions.first(where: { $0.id == id })?.runtimeID ?? id.uuidString
      try await watch(sessionID: runtimeID)

    case let .prompt(input):
      let session = try await ensureActiveSession()
      await operationDriver.setSession(session.id)
      state.messages.append(KimiMessage(role: .user, text: input.text))
      publish(.userText(input.text))
      let operationID = try await harness.prompt(input)
      operationSessions[operationID] = session.id
      sessionOperations[session.id] = operationID
      state.runtimeState = .ready

    case let .steer(input):
      try await harness.steer(input, lane: .main)

    case let .followUp(input):
      try await harness.followUp(input, lane: .main)

    case let .abort(operationID):
      if let sessionID = operationSessions[operationID] {
        try await sessionClient.abort(sessionID: sessionID)
      }
      await harness.abort(operationID)

    case let .approve(permissionID):
      try await respondToPermission(permissionID, reply: "once")

    case let .deny(permissionID):
      try await respondToPermission(permissionID, reply: "reject")

    case .retry:
      state.lastError = nil

    case .resume:
      try await harness.resume(.main)

    case .openTerminal:
      state.activePane = .conversation

    case .openDiff:
      state.activePane = .diff

    case .openBrowser:
      state.activePane = .browser

    case .openFile:
      state.activePane = .files

    case .changeModel:
      break

    case .restartRuntime:
      if let runtimeSupervisor {
        _ = try await runtimeSupervisor.restart()
        try await runtimeSupervisor.waitUntilReady()
      }
      state.runtimeState = .ready
      publish(.runtimeChanged(.ready))
    }
    persistState()
  }

  private func ensureActiveSession() async throws -> OpenCodeSession {
    if let activeID = state.activeSessionID,
       let existing = state.sessions.first(where: { $0.id == activeID }) {
      return OpenCodeSession(id: existing.runtimeID ?? existing.id.uuidString, title: existing.title, directory: existing.projectPath)
    }
    let created = try await sessionClient.createSession(CreateSessionInput())
    let summary = KimiSessionSummary(id: UUID(), runtimeID: created.id, title: created.title ?? "新会话", projectPath: created.directory)
    state.sessions.insert(summary, at: 0)
    state.activeSessionID = summary.id
    try await watch(sessionID: created.id)
    return created
  }

  private func restoreRuntimeSessions() async {
    guard let sessions = try? await sessionClient.listSessions(directory: nil) else { return }
    for session in sessions {
      if let index = state.sessions.firstIndex(where: { $0.runtimeID == session.id }) {
        state.sessions[index].title = session.title ?? state.sessions[index].title
        state.sessions[index].projectPath = session.directory ?? state.sessions[index].projectPath
        state.sessions[index].updatedAt = .now
      } else {
        state.sessions.append(KimiSessionSummary(
          runtimeID: session.id,
          title: session.title ?? "新会话",
          projectPath: session.directory
        ))
      }
    }
    if state.activeSessionID == nil { state.activeSessionID = state.sessions.first?.id }
    state.sessions.sort { $0.updatedAt > $1.updatedAt }
  }

  private func watch(sessionID: String) async throws {
    guard eventTasks[sessionID] == nil else { return }
    let stream = try await sessionClient.subscribeEvents(sessionID: sessionID)
    eventTasks[sessionID] = Task { [weak self] in
      do {
        for try await event in stream {
          await self?.ingest(event)
        }
      } catch {
        await self?.ingest(OpenCodeEvent(sessionID: sessionID, kind: .error, text: error.localizedDescription))
      }
    }
  }

  private func ingest(_ event: OpenCodeEvent) async {
    await recordOpenCodeEvent(event)
    for mapped in OpenCodeEventBridge.map(event) {
      apply(mapped)
      publish(mapped)
    }
    persistState()
  }

  private func apply(_ event: KimiEvent) {
    switch event {
    case let .runtimeChanged(runtime):
      state.runtimeState = runtime
    case let .sessionChanged(summary):
      if let index = state.sessions.firstIndex(where: { $0.id == summary.id }) { state.sessions[index] = summary }
      else { state.sessions.insert(summary, at: 0) }
    case let .userText(text):
      state.messages.append(KimiMessage(role: .user, text: text))
    case let .assistantText(text):
      if let index = state.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
        state.messages[index].text += text
      } else {
        state.messages.append(KimiMessage(role: .assistant, text: text, isStreaming: false))
      }
    case let .activity(activity):
      if let index = state.activities.firstIndex(where: { $0.toolCallID == activity.toolCallID && activity.toolCallID != nil }) {
        state.activities[index] = activity
      } else { state.activities.append(activity) }
    case let .permission(permission):
      if !state.pendingPermissions.contains(where: { $0.id == permission.id }) { state.pendingPermissions.append(permission) }
    case let .error(message):
      state.lastError = message
    }
  }

  private func respondToPermission(_ id: UUID, reply: String) async throws {
    guard let permission = state.pendingPermissions.first(where: { $0.id == id }) else { return }
    guard let operationID = permissionOperations[id], let sessionID = operationSessions[operationID] else {
      throw OpenCodeRuntimeError.requestFailed("找不到该权限请求对应的 OpenCode Session。")
    }
    try await sessionClient.respondPermission(PermissionResponse(
      sessionID: sessionID,
      requestID: permission.runtimeID ?? permission.id.uuidString,
      reply: reply
    ))
    state.pendingPermissions.removeAll { $0.id == id }
    let decision: PermissionDecision = reply == "reject" ? .deny : .allow
    await harness.record(
      .permissionSettled(HarnessPermissionReceipt(
        operationID: operationID,
        requestID: id,
        toolID: permission.toolID,
        decision: decision
      )),
      operationID: operationID
    )
    permissionOperations.removeValue(forKey: id)
    persistState()
  }

  private func recordOpenCodeEvent(_ event: OpenCodeEvent) async {
    guard let operationID = sessionOperations[event.sessionID] else { return }
    let snapshot = await harness.snapshot()
    let checkpoint = snapshot.checkpoints[operationID]
    let turnID = checkpoint?.turnID ?? UUID()
    let step = checkpoint?.step ?? 1
    switch event.kind {
    case .permissionAsked:
      permissionOperations[event.id] = operationID
    case .toolCall:
      let callID = event.toolCallID ?? event.id.uuidString
      let toolName = event.toolID ?? "unknown"
      let call = HarnessToolCall(
        id: callID,
        name: toolName,
        argumentsJSON: event.payload["arguments"] ?? "{}"
      )
      await harness.record(.toolCallDeclared(HarnessToolCallRecord(turnID: turnID, step: step, call: call)), operationID: operationID)
      let key = "\(operationID.uuidString)|\(callID)"
      if effectByToolCall[key] == nil {
        let intent = HarnessEffectIntent(
          operationID: operationID,
          kind: .tool,
          subject: toolName,
          risk: Self.toolRisk(for: toolName),
          inputDigest: HarnessDigest.sha256(call.argumentsJSON)
        )
        effectByToolCall[key] = intent.effectID
        await harness.record(.effectIntentWritten(intent), operationID: operationID)
        await harness.record(.effectStarted(intent), operationID: operationID)
      }
    case .toolResult:
      let callID = event.toolCallID ?? event.id.uuidString
      let toolName = event.toolID ?? "unknown"
      let result = HarnessToolResult(
        callID: callID,
        toolName: toolName,
        output: event.text ?? "",
        isError: event.payload["status"]?.lowercased() == "failed" || event.payload["error"] != nil
      )
      await harness.record(.toolResultRecorded(HarnessToolResultRecord(turnID: turnID, step: step, result: result)), operationID: operationID)
      let key = "\(operationID.uuidString)|\(callID)"
      if let effectID = effectByToolCall.removeValue(forKey: key) {
        let receipt = HarnessEffectReceipt(
          operationID: operationID,
          effectID: effectID,
          outcome: result.isError ? .failure : .success,
          output: result.output,
          errorMessage: result.isError ? result.output : nil,
          retryable: result.isError && Self.toolRisk(for: toolName) == .low
        )
        await harness.record(.effectSettled(receipt), operationID: operationID)
      }
    default:
      break
    }
  }

  private static func toolRisk(for toolID: String) -> ToolRisk {
    ToolCatalog.defaultDefinitions.first(where: { $0.id == toolID })?.risk ?? .medium
  }

  private func persistState() {
    guard let stateStore else { return }
    try? stateStore.save(KimiPersistedAppState(harnessSessionID: harnessSessionID, uiState: state))
  }

  private func publish(_ event: KimiEvent) {
    continuations.values.forEach { $0.yield(event) }
  }

  private func removeContinuation(_ token: UUID) {
    continuations.removeValue(forKey: token)
  }
}

public final class UnavailableOpenCodeSessionClient: OpenCodeSessionClient, @unchecked Sendable {
  public init() {}

  public func createSession(_ input: CreateSessionInput) async throws -> OpenCodeSession {
    throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。")
  }

  public func prompt(_ input: OpenCodePromptInput) async throws { throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。") }
  public func steer(_ input: OpenCodeSteerInput) async throws { throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。") }
  public func abort(sessionID: String) async throws { throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。") }
  public func respondPermission(_ input: PermissionResponse) async throws { throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。") }
  public func listSessions(directory: String?) async throws -> [OpenCodeSession] { throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。") }
  public func subscribeEvents(sessionID: String) async throws -> AsyncThrowingStream<OpenCodeEvent, Error> { throw OpenCodeRuntimeError.requestFailed("OpenCode Headless Runtime 尚未连接。") }
}
