import AppKit
import Combine
import Darwin
import Foundation
import KimiAgentCore

private actor ChildToolEvidenceStore {
  struct Entry: Sendable {
    let toolID: String
    let output: String
    let metadata: [String: String]
  }

  private var entries: [Entry] = []

  func append(toolID: String, result: ToolExecutionResult) {
    entries.append(Entry(toolID: toolID, output: result.output, metadata: result.metadata))
  }

  func snapshot() -> [Entry] { entries }
}

@MainActor
final class DesktopAppModel: ObservableObject {
  @Published private(set) var state: AppState
  @Published var selectedTaskID: AgentTask.ID? {
    didSet {
      state.selectedTaskID = selectedTaskID
      schedulePersistence()
    }
  }
  @Published var selectedMode: TaskMode = .plan
  @Published var selectedModelID = ""
  @Published var draftPrompt = ""
  @Published var isComposingNewConversation = false
  @Published var eventLog: [AgentTask.ID: [String]] = [:]
  @Published var verificationInProgress: Set<AgentTask.ID> = []
  @Published var pendingToolApproval: PendingToolApproval?
  @Published var pendingTerminalApproval: PendingTerminalApproval?
  @Published var pendingInteractiveTerminalPaste: PendingInteractiveTerminalPaste?
  @Published var loginOutput = ""
  @Published var showLoginSheet = false
  @Published var notice: Notice?
  @Published var showAutomaticConfirmation = false
  @Published private(set) var extensionHookResults: [AgentTask.ID: [HookResult]] = [:]
  @Published private(set) var extensionMCPStatuses: [MCPServerStatus] = []
  @Published private(set) var extensionMCPTools: [MCPDiscoveredTool] = []
  @Published private(set) var extensionConfiguration: ProjectAgentConfiguration?
  @Published private(set) var extensionSkills: [SkillDescriptor] = []
  @Published private(set) var extensionPlugins: [KimiPluginDescriptor] = []
  @Published private(set) var pluginWorkerStatuses: [PluginWorkerStatus] = []
  @Published private(set) var extensionAgents: [AgentDefinition] = []
  @Published private(set) var integrationAccounts: [AccountRecord] = []
  @Published private(set) var kimiRuntimeIdentity: KimiRuntimeIdentityRecord
  @Published private(set) var kimiAvailableModels: [KimiModelSummary] = []
  @Published private(set) var isRefreshingKimiModels = false
  @Published private(set) var lastKimiModelRefreshAt: Date?
  @Published private(set) var kimiModelRefreshError: String?
  @Published private(set) var webResearchSettings: WebResearchSettingsRecord
  @Published private(set) var webResearchCapability: WebResearchCapabilityState = .notTested
  @Published private(set) var terminalWorkspace: TerminalWorkspaceState
  @Published private(set) var tmuxSessions: [UUID: [TmuxSessionRecord]] = [:]

  private let repository: TaskRepository
  private let persistenceWriter: StatePersistenceWriter
  private let sessionEventStore: SessionEventStore
  private let harnessEventStore: HarnessEventStore
  private let applicationSupportDirectory: URL
  let credentialStorageMode: CredentialStorageMode
  private let credentialVault: CredentialVault
  private let integrationStore: IntegrationAccountStore
  private let kimiRuntimeIdentityStore: KimiRuntimeIdentityStore
  private let webResearchSettingsStore: WebResearchSettingsStore
  private let usageLedger: UsageLedger
  private let memoryStore: MemoryStore
  private let providerTraceRecorder: ProviderTraceRecorder
  private let mcpToolCatalog = MCPToolCatalog()
  private let mcpWorkerSupervisor = MCPWorkerSupervisor()
  private let pluginWorkerSupervisor = PluginWorkerSupervisor()
  private var extensionRuntime: ProjectExtensionRuntime?
  private var extensionRuntimeWorkspacePath: String?
  private var pendingAutomaticTaskID: AgentTask.ID?
  private var pendingAutomaticPrompt: String?
  private let approvalMemory = ApprovalMemory()
  private let terminalApprovalMemory = ApprovalMemory()
  private var currentWorkspaceAccess: WorkspaceAccessToken?
  private var taskWorkspaceAccessTokens: [AgentTask.ID: WorkspaceAccessToken] = [:]
  private var runningProcesses: [AgentTask.ID: KimiProcessHandle] = [:]
  private var runningAgentHosts: [AgentTask.ID: KimiAgentHostHandle] = [:]
  private var automatedGraphTasks: [AgentTask.ID: Task<Void, Never>] = [:]
  private var agentGraphSupervisors: [AgentTask.ID: AgentGraphSupervisor] = [:]
  private var graphContracts: [AgentTask.ID: TaskContract] = [:]
  private var runningTerminalCommands: [UUID: TerminalCommandHandle] = [:]
  private var runningTerminalSessionIDs: [UUID: UUID] = [:]
  private var terminalJobIDs: [UUID: UUID] = [:]
  private var terminalPTYHandles: [UUID: TerminalPTYHandle] = [:]
  private var terminalPTYWaitTasks: [UUID: Task<Void, Never>] = [:]
  private var terminalReconnectTasks: [UUID: Task<Void, Never>] = [:]
  private var terminalReconnectAttempts: [UUID: Int] = [:]
  private var terminalTimeoutTasks: [UUID: Task<Void, Never>] = [:]
  private var cancelledTerminalCommands = Set<UUID>()
  private var webResearchBridge: KimiProcessHandle?
  private var webResearchBridgeURL: String?
  private var webResearchBridgeConfigurationFingerprint: String?
  private var loginProcess: KimiProcessHandle?
  private var streamBuffers: [AgentTask.ID: TaskStreamBuffers] = [:]
  private var streamParsers: [AgentTask.ID: KimiStreamEventParser] = [:]
  private var activeTurnIDs: [AgentTask.ID: UUID] = [:]
  private var pendingOutputEvents: [AgentTask.ID: [String]] = [:]
  private var pendingStructuredEvents: [AgentTask.ID: [AgentEvent]] = [:]
  private var outputFlushTask: Task<Void, Never>?
  private var persistenceTask: Task<Void, Never>?
  private var sessionEventWriteTails: [UUID: Task<Void, Never>] = [:]
  private var persistenceRevision = 0
  private let maximumPersistedEvents = 1_000
  private let terminalQueueScheduler = TerminalQueueScheduler(maxConcurrent: 4)
  private var harnesses: [AgentTask.ID: AgentHarness] = [:]
  private var harnessOperationIDs: [AgentTask.ID: OperationID] = [:]
  private var harnessEventTasks: [AgentTask.ID: Task<Void, Never>] = [:]
  private var nativeToolApprovalContinuations: [String: CheckedContinuation<PermissionDecision, Never>] = [:]

  init() {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Kimi Agent Desktop", isDirectory: true)
    let stateURL = applicationSupport.appendingPathComponent("state.json")
    let sessionEventsURL = applicationSupport.appendingPathComponent("session-events.jsonl")
    let harnessEventsURL = applicationSupport.appendingPathComponent("harness-v2/events.jsonl")
    applicationSupportDirectory = applicationSupport
    // One-time, lossless migration gate. It only creates backups and a
    // version marker; legacy records are imported below and then routed
    // through the same Harness as new sessions.
    _ = try? HarnessMigrationCoordinator(directory: applicationSupport).prepare()
    usageLedger = UsageLedger(fileURL: applicationSupport.appendingPathComponent("harness-v3/usage-ledger.json"))
    memoryStore = MemoryStore(fileURL: applicationSupport.appendingPathComponent("harness-v3/memory.json"))
    providerTraceRecorder = ProviderTraceRecorder(fileURL: applicationSupport.appendingPathComponent("harness-v3/provider-traces.jsonl"))
    repository = TaskRepository(fileURL: stateURL)
    persistenceWriter = StatePersistenceWriter(fileURL: stateURL)
    sessionEventStore = SessionEventStore(fileURL: sessionEventsURL)
    harnessEventStore = HarnessEventStore(fileURL: harnessEventsURL)
    let credentialSelection = CredentialVaultFactory.makeDefault(applicationSupportDirectory: applicationSupport)
    credentialStorageMode = credentialSelection.mode
    let credentialVault = credentialSelection.vault
    self.credentialVault = credentialVault
    integrationStore = IntegrationAccountStore(vault: credentialVault)
    kimiRuntimeIdentityStore = KimiRuntimeIdentityStore(vault: credentialVault)
    webResearchSettingsStore = WebResearchSettingsStore(vault: credentialVault)
    kimiRuntimeIdentity = (try? kimiRuntimeIdentityStore.record()) ?? KimiRuntimeIdentityRecord()
    webResearchSettings = (try? webResearchSettingsStore.record()) ?? WebResearchSettingsRecord()
    let loadedState = (try? repository.load()) ?? AppState()
    var migratedState = Self.migrateConversationState(loadedState)
    var restoredTerminalWorkspace = migratedState.terminalWorkspace
    restoredTerminalWorkspace.markInterrupted()
    migratedState.terminalWorkspace = restoredTerminalWorkspace
    state = migratedState
    terminalWorkspace = restoredTerminalWorkspace
    let restoredSelection = loadedState.selectedTaskID.flatMap { selectedID in
      loadedState.tasks.contains(where: { $0.id == selectedID }) ? selectedID : nil
    }
    selectedTaskID = restoredSelection ?? loadedState.tasks.first?.id
    state.selectedTaskID = selectedTaskID
    if selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       kimiRuntimeIdentity.mode == .apiKey {
      selectedModelID = kimiRuntimeIdentity.modelID
    }
    eventLog = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0.events) })
    activeTurnIDs = Dictionary(uniqueKeysWithValues: state.tasks.compactMap { task in
      guard let turnID = task.activeTurnID ?? task.turns.last?.id else { return nil }
      return (task.id, turnID)
    })
    restoreCurrentWorkspaceAccess()
    refreshExtensionRuntime()
    refreshIntegrationAccounts()
    refreshWebResearchSettings()
    refreshKimiModelsIfNeeded()
    restoreSessionSnapshots()
    restoreAgentGraphSupervisors()
    importLegacyHarnessState(migratedState)
    if state != loadedState {
      schedulePersistence()
    }
  }

  deinit {
    webResearchBridge?.terminate()
    currentWorkspaceAccess?.stop()
    taskWorkspaceAccessTokens.values.forEach { $0.stop() }
    runningTerminalCommands.values.forEach { $0.terminate() }
    runningTerminalSessionIDs.removeAll()
    terminalPTYHandles.values.forEach { $0.terminate() }
    terminalPTYWaitTasks.values.forEach { $0.cancel() }
    terminalReconnectTasks.values.forEach { $0.cancel() }
    terminalTimeoutTasks.values.forEach { $0.cancel() }
    harnessEventTasks.values.forEach { $0.cancel() }
    automatedGraphTasks.values.forEach { $0.cancel() }
    agentGraphSupervisors.removeAll()
    graphContracts.removeAll()
  }

  private static func migrateConversationState(_ original: AppState) -> AppState {
    var migrated = original
    var normalizedTasks: [AgentTask] = []
    var seenKeys = Set<String>()

    for var task in original.tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) {
      let key = "\(task.workspacePath)|\(task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
      if seenKeys.contains(key), task.status != .running {
        continue
      }
      seenKeys.insert(key)

      if task.turns.isEmpty {
        let turn = ConversationTurn(
          sequence: 1,
          userMessage: task.title,
          status: task.status == .failed ? .failed : task.status == .completed || task.status == .reviewReady ? .completed : .queued
        )
        task.turns = [turn]
        task.activeTurnID = turn.id
      } else if task.activeTurnID == nil {
        task.activeTurnID = task.turns.last?.id
      }

      if let turnID = task.activeTurnID {
        task.structuredEvents = task.structuredEvents.map { event in
          event.turnID == nil ? event.assigningTurn(turnID) : event
        }
      }
      let sessionUUID = UUID(uuidString: task.sessionID ?? "") ?? task.id
      if task.agentRuns.isEmpty {
        task.agentRuns = AgentOrchestrator.makePlan(taskID: task.id, mode: task.mode, sessionID: sessionUUID, model: task.modelID).runs
      }
      task.agentRuns = task.agentRuns.map { run in
        var run = run
        if run.state == .running || run.state == .awaitingApproval {
          run.state = .interrupted
          run.errorMessage = "应用重启前任务尚未结束。"
          run.updatedAt = .now
        }
        return run
      }
      if task.workspaceLayout == nil {
        task.workspaceLayout = WorkspaceLayout.defaultLayout()
      }
      if var terminalSession = task.terminalSession {
        terminalSession.markRunningCommandsInterrupted()
        task.terminalSession = terminalSession
      }
      normalizedTasks.append(task)
    }

    migrated.tasks = normalizedTasks
    if let selected = original.selectedTaskID, normalizedTasks.contains(where: { $0.id == selected }) {
      migrated.selectedTaskID = selected
    } else {
      migrated.selectedTaskID = normalizedTasks.first?.id
    }
    return migrated
  }

  var selectedTask: AgentTask? {
    guard let selectedTaskID else { return nil }
    return state.tasks.first { $0.id == selectedTaskID }
  }

  var workspaceURL: URL? {
    state.workspacePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  var credentialStorageTitle: String {
    switch credentialStorageMode {
    case .keychain:
      "macOS Keychain"
    case .localFile:
      "本地受保护文件"
    }
  }

  var credentialStorageHint: String {
    switch credentialStorageMode {
    case .keychain:
      "凭据保存在 macOS Keychain，不会写入项目或普通日志。"
    case .localFile:
      "当前是未稳定签名的本地开发构建：凭据仅保存在这台 Mac 的受保护本地文件中，避免系统反复请求钥匙串密码。首次需要重新保存一次 API Key。"
    }
  }

  private func bookmarkData(for workspacePath: String) -> Data? {
    state.workspaceBookmarks[workspacePath]
      ?? (state.workspacePath == workspacePath ? state.workspaceBookmarkData : nil)
  }

  private func saveWorkspaceBookmark(_ bookmarkData: Data?, for workspacePath: String) {
    guard let bookmarkData else { return }
    state.workspaceBookmarkData = bookmarkData
    state.workspaceBookmarks[workspacePath] = bookmarkData
  }

  @discardableResult
  private func restoreWorkspaceAccess(path: String?) -> URL? {
    guard let path else { return nil }
    guard let grant = WorkspaceAccessManager.restoreWorkspace(
      path: path,
      bookmarkData: bookmarkData(for: path)
    ) else {
      return nil
    }
    activateWorkspaceAccess(grant)
    if grant.url.path != path || grant.isStale {
      state.workspacePath = grant.url.path
      saveWorkspaceBookmark(grant.bookmarkData, for: grant.url.path)
      schedulePersistence()
    }
    return grant.url
  }

  private func restoreCurrentWorkspaceAccess() {
    _ = restoreWorkspaceAccess(path: state.workspacePath)
  }

  private func activateWorkspaceAccess(_ grant: WorkspaceAccessGrant) {
    currentWorkspaceAccess?.stop()
    currentWorkspaceAccess = WorkspaceAccessManager.startAccessing(grant)
  }

  @discardableResult
  private func beginTaskWorkspaceAccess(for task: AgentTask) -> URL {
    let restoredURL = restoreWorkspaceAccess(path: task.workspacePath)
    let workspaceURL = restoredURL ?? URL(fileURLWithPath: task.workspacePath, isDirectory: true).standardizedFileURL
    if let grant = WorkspaceAccessManager.restoreWorkspace(
      path: workspaceURL.path,
      bookmarkData: bookmarkData(for: workspaceURL.path) ?? bookmarkData(for: task.workspacePath)
    ) {
      taskWorkspaceAccessTokens[task.id]?.stop()
      taskWorkspaceAccessTokens[task.id] = WorkspaceAccessManager.startAccessing(grant)
      if grant.isStale {
        saveWorkspaceBookmark(grant.bookmarkData, for: grant.url.path)
        schedulePersistence()
      }
    }
    return workspaceURL
  }

  private func endTaskWorkspaceAccess(for taskID: AgentTask.ID) {
    taskWorkspaceAccessTokens[taskID]?.stop()
    taskWorkspaceAccessTokens.removeValue(forKey: taskID)
  }

  var selectedDiff: DiffSnapshot? {
    selectedTask?.diffSnapshot
  }

  var selectedVerification: VerificationResult? {
    selectedTask?.verificationResult
  }

  var selectedWorkItems: [WorkItem] {
    selectedTask?.workItems ?? []
  }

  func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.title = "选择项目文件夹"
    panel.prompt = "选择项目"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true

    guard panel.runModal() == .OK, let url = panel.url else { return }
    let grant = WorkspaceAccessManager.grantForUserSelectedWorkspace(url)
    activateWorkspaceAccess(grant)
    state.workspacePath = grant.url.path
    saveWorkspaceBookmark(grant.bookmarkData, for: grant.url.path)
    refreshExtensionRuntime()
    schedulePersistence()
    notice = Notice(kind: .success, text: grant.bookmarkData == nil
      ? "已选择 \(grant.url.lastPathComponent)。当前构建未返回持久授权；如仍弹窗，请重新从系统选择器选择一次。"
      : "已选择 \(grant.url.lastPathComponent)，以后会自动复用项目访问权限。")
  }

  func selectWorkspace(path: String) {
    let restoredURL = restoreWorkspaceAccess(path: path)
    let resolvedPath = restoredURL?.path ?? path
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
      notice = Notice(kind: .error, text: "项目路径不存在：\(path)")
      return
    }
    state.workspacePath = resolvedPath
    if let task = state.tasks.first(where: { $0.workspacePath == resolvedPath }) {
      isComposingNewConversation = false
      selectedTaskID = task.id
    }
    refreshExtensionRuntime()
    schedulePersistence()
  }

  func startNewConversation() {
    isComposingNewConversation = true
    selectedTaskID = nil
    draftPrompt = ""
  }

  func openConversation(id: AgentTask.ID) {
    guard let task = state.tasks.first(where: { $0.id == id }) else {
      notice = Notice(kind: .error, text: "找不到该会话。")
      return
    }
    let destination = TaskWorkspacePresentation.conversationDestination(for: task)
    isComposingNewConversation = false
    let restoredURL = restoreWorkspaceAccess(path: destination.workspacePath)
    state.workspacePath = restoredURL?.path ?? destination.workspacePath
    selectedTaskID = destination.taskID
    selectedMode = task.mode
    selectedModelID = task.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? task.modelID!
      : kimiRuntimeIdentity.modelID
    refreshExtensionRuntime()
    schedulePersistence()
  }

  /// Runs one orchestration node in a real independent Child Session. The
  /// Core-owned graph supervisor chooses the node and owns its Child Session;
  /// this View Model only forwards the user's explicit resume/retry command.
  func runAgentRun(taskID: AgentTask.ID, runID: UUID) {
    guard let supervisor = agentGraphSupervisors[taskID] else { return }
    Task { @MainActor [weak self] in
      let snapshot = await supervisor.snapshot()
      guard let run = snapshot.runs.first(where: { $0.id == runID }) else { return }
      switch run.state {
      case .paused, .interrupted:
        await supervisor.continueRun(runID)
      case .failed:
        await supervisor.retry(runID)
      case .queued:
        break
      case .running, .awaitingApproval, .completed, .cancelled:
        return
      }
      self?.startAgentGraphDriver(taskID: taskID)
    }
  }

  /// Native-only Child Agent executor. Child sessions use the same Kimi API →
  /// ToolExecutionCoordinator → Intent/Permission/Receipt loop as the main
  /// session and never delegate side effects to ACP/CLI.
  private func executeNativeChildAgent(
    parentTaskID: AgentTask.ID,
    session: SessionRecord,
    prompt: String,
    tools: [ToolDefinition],
    agentDefinition: AgentDefinition
  ) async throws -> AgentResult {
    guard let parent = state.tasks.first(where: { $0.id == parentTaskID }),
          let apiKey = try kimiRuntimeIdentityStore.apiKey(), !apiKey.isEmpty,
          let baseURL = URL(string: kimiRuntimeIdentity.baseURL) else {
      throw NSError(domain: "HarnessChild", code: 401, userInfo: [NSLocalizedDescriptionKey: "Child Agent 缺少 Kimi API 连接。"])
    }
    let workspaceURL = URL(fileURLWithPath: session.worktreePath ?? parent.worktreePath ?? parent.workspacePath, isDirectory: true)
      .standardizedFileURL
    let artifactDirectory = applicationSupportDirectory
      .appendingPathComponent("browser-artifacts", isDirectory: true)
      .appendingPathComponent(session.id.uuidString, isDirectory: true)
    let allowedDomains = activeNetworkDomains
    let preferredModelID = session.modelID ?? parent.modelID ?? kimiRuntimeIdentity.modelID
    let modelRoute = ModelRouter.route(
      intent: agentDefinition.kind.modelRoutingIntent,
      promptLength: prompt.count,
      budget: .standard
    )
    let modelID = ModelRouteResolver.resolve(preferredModelID: preferredModelID, route: modelRoute).modelID
    let webToolExecutor: WebRuntimeToolExecutor?
    if tools.contains(where: { $0.id == "web.search" || $0.id == "web.fetch" }) {
      webToolExecutor = WebRuntimeToolExecutor(runtime: try await makeNativeWebRuntime(modelID: modelID, baseURL: baseURL, apiKey: apiKey))
    } else {
      webToolExecutor = nil
    }
    let promptURL = BrowserHarnessRequestDecoder.firstHTTPURL(in: prompt)
    let browserHandler: NativeHarnessToolRuntime.SpecializedToolHandler = { request in
      var plan = try BrowserHarnessRequestDecoder.plan(from: request, fallbackURL: promptURL)
      plan.allowedDomains = Array(Set(plan.allowedDomains + allowedDomains)).sorted()
      // The user supplied the target URL in the parent prompt. Bind that
      // explicit host to this single read-only Browser verification so the
      // child adapter does not ask a second, disconnected approval question.
      for step in plan.steps {
        if let host = step.url?.host?.lowercased(), !BrowserDomainPolicy.isLocal(host: host) {
          plan.allowedDomains.append(host)
        }
      }
      plan.allowedDomains = Array(Set(plan.allowedDomains)).sorted()
      let controller = await MainActor.run { BrowserVerificationController() }
      let result = await controller.run(plan: plan, artifactsDirectory: artifactDirectory)
      return ToolExecutionResult(
        output: result.passed ? "浏览器验证通过。\n\(result.repairSummary)" : "浏览器验证失败。\n\(result.repairSummary)",
        metadata: ["adapter": "browser", "passed": result.passed ? "true" : "false"],
        exitCode: result.passed ? 0 : 1
      )
    }
    let mcpExecutor = extensionRuntime.map { MCPHarnessToolExecutor(runtime: $0, workerSupervisor: self.mcpWorkerSupervisor) }
    let computerUseHandler: NativeHarnessToolRuntime.SpecializedToolHandler = { request in
      try await ComputerUseController.executeHarnessRequest(request)
    }
    let mcpHandler: NativeHarnessToolRuntime.SpecializedToolHandler?
    if let mcpExecutor {
      mcpHandler = { request in try await mcpExecutor.execute(request) }
    } else {
      mcpHandler = nil
    }
    let runtime = NativeHarnessToolRuntime(
      workspaceURL: workspaceURL,
      browserHandler: browserHandler,
      computerUseHandler: computerUseHandler,
      mcpHandler: mcpHandler
    )
    let registry = ToolRegistry(definitions: tools)
    for definition in tools {
      if (definition.id == "web.search" || definition.id == "web.fetch"), let webToolExecutor {
        await registry.register(definition, executor: webToolExecutor)
      } else if definition.id.hasPrefix("mcp."), let mcpExecutor {
        await registry.register(definition, executor: mcpExecutor)
      } else {
        await registry.register(definition, executor: runtime)
      }
    }
    let journal = ToolEffectJournal(store: harnessEventStore, sessionID: session.id, lane: .main)
    let coordinator = ToolExecutionCoordinator(
      registry: registry,
      permissionResolver: ChildAgentToolPermissionResolver(definition: agentDefinition),
      approvalHandler: { [weak self] request, definition in
        guard let self else { return .deny }
        return await self.requestNativeToolApproval(request: request, definition: definition, workspacePath: workspaceURL.path)
      },
      hookResolver: { [weak self] request in
        await MainActor.run { self?.resolveHarnessHooks(request, taskID: parentTaskID) }
      },
      journal: journal
    )
    let provider = KimiHTTPModelProvider(
      baseURL: baseURL,
      apiKey: apiKey,
      modelID: modelID,
      maximumOutputTokens: modelRoute.maximumOutputTokens,
      traceRecorder: providerTraceRecorder
    )
    let evidenceStore = ChildToolEvidenceStore()
    let loop = HarnessConversationLoop(provider: provider, maxRounds: 8) { call, _ in
      let request = ToolExecutionRequest(
        taskID: parentTaskID,
        sessionID: session.id,
        operationID: session.id,
        agentID: session.agentID,
        toolID: call.name,
        inputJSON: Self.nativeToolInputJSON(from: call.argumentsJSON),
        resource: Self.nativeToolResource(from: call.argumentsJSON),
        command: Self.nativeToolCommand(from: call.argumentsJSON)
      )
      do {
        let result = try await coordinator.execute(request)
        await evidenceStore.append(toolID: call.name, result: result)
        return HarnessToolResult(callID: call.id, toolName: call.name, output: result.output, isError: result.exitCode.map { $0 != 0 } ?? false)
      } catch {
        return HarnessToolResult(callID: call.id, toolName: call.name, output: error.localizedDescription, isError: true)
      }
    }
    let result = try await loop.run(
      request: HarnessConversationRequest(modelID: modelID, messages: [.user(prompt)]),
      tools: await registry.all()
    )
    guard !result.blockedByToolFailure else {
      throw NSError(domain: "HarnessChild", code: 1, userInfo: [NSLocalizedDescriptionKey: result.text])
    }
    let summary = ResponseQualityGate.enforce(result.text, outcome: .completed)
    let evidence = await evidenceStore.snapshot()
    let receiptIDs = evidence.compactMap { entry in
      entry.metadata["effectID"].flatMap(UUID.init(uuidString:))
    }
    switch agentDefinition.kind {
    case .webResearch:
      let webEvidence = evidence.filter { entry in
        let id = entry.toolID.lowercased()
        return id == "web.search" || id == "web.fetch" || id == "web_search" || id == "web_fetch" || id == "fetchurl" || id == "network.fetch"
      }
      guard !webEvidence.isEmpty else {
        return AgentResult(summary: summary, nextActions: ["Web Research 没有成功的 Harness receipt，请重试当前阶段。"], status: .partial, verification: ["Web Research 未完成。"])
      }
      let sourceCount = webEvidence.reduce(into: Set<String>()) { domains, entry in
        if let rawURL = entry.metadata["url"], let host = URL(string: rawURL)?.host { domains.insert(host) }
      }.count
      let output = webEvidence.map(\.output).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
      return AgentResult(
        summary: output.isEmpty ? summary : output,
        receiptIDs: receiptIDs,
        status: .completed,
        evidence: [AgentEvidence(label: "Web Research", value: sourceCount > 0 ? "已处理 \(sourceCount) 个来源。" : "已完成搜索和抓取。", source: "harness receipt")],
        verification: ["Web Research receipt 已成功结算。"]
      )
    case .browserVerification:
      let browserOutput = evidence.last(where: { $0.toolID == "browser" })?.output ?? summary
      return AgentResult(
        summary: browserOutput,
        receiptIDs: receiptIDs,
        status: .completed,
        evidence: [AgentEvidence(label: "Browser Adapter", value: browserOutput, source: "harness receipt")],
        verification: ["Browser Adapter receipt 已成功结算。"]
      )
    case .computerUse:
      let computerOutput = evidence.last(where: { $0.toolID.hasPrefix("computer_use.") })?.output ?? summary
      return AgentResult(
        summary: computerOutput,
        receiptIDs: receiptIDs,
        status: .completed,
        evidence: [AgentEvidence(label: "Computer Use Adapter", value: computerOutput, source: "harness receipt")],
        verification: ["Computer Use Adapter receipt 已成功结算。"]
      )
    default:
      return AgentResult(summary: summary)
    }
  }

  func cancelAgentRun(taskID: AgentTask.ID, runID: UUID) {
    guard let supervisor = agentGraphSupervisors[taskID] else { return }
    Task { await supervisor.cancel(runID) }
  }

  func refreshExtensions() {
    refreshExtensionRuntime()
  }

  func memories(for task: AgentTask? = nil) -> [MemoryRecord] {
    let resolvedTask = task ?? selectedTask
    guard let resolvedTask else { return memoryStore.effectiveRecords() }
    return memoryStore.effectiveRecords(
      projectKey: resolvedTask.workspacePath,
      taskKey: resolvedTask.id.uuidString
    )
  }

  func saveMemory(scope: MemoryScope, content: String, for task: AgentTask? = nil) {
    let resolvedTask = task ?? selectedTask
    let scopeKey: String?
    switch scope {
    case .user: scopeKey = nil
    case .project: scopeKey = resolvedTask?.workspacePath
    case .task: scopeKey = resolvedTask?.id.uuidString
    }
    do {
      try memoryStore.upsert(MemoryRecord(scope: scope, scopeKey: scopeKey, kind: .fact, content: content, provenance: .userConfirmed))
      notice = Notice(kind: .success, text: "已保存记忆。")
    } catch {
      notice = Notice(kind: .error, text: "保存记忆失败：\(error.localizedDescription)")
    }
  }

  func deleteMemory(id: UUID) {
    do {
      try memoryStore.delete(id: id)
      notice = Notice(kind: .success, text: "已删除记忆。")
    } catch {
      notice = Notice(kind: .error, text: "删除记忆失败：\(error.localizedDescription)")
    }
  }

  func openExtensionConfiguration() {
    guard let workspacePath = state.workspacePath else {
      notice = Notice(kind: .error, text: "请先选择项目文件夹。")
      return
    }
    let workspaceURL = restoreWorkspaceAccess(path: workspacePath)
      ?? URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
    let configURL = ProjectAgentConfiguration.configurationURL(projectDirectory: workspaceURL)
    if FileManager.default.fileExists(atPath: configURL.path) {
      NSWorkspace.shared.activateFileViewerSelecting([configURL])
      notice = Notice(kind: .success, text: "已打开扩展配置。")
    } else {
      notice = Notice(kind: .error, text: "当前项目还没有 .kimi-agent/config.json。")
    }
  }

  func createTask() {
    let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      notice = Notice(kind: .error, text: "请先描述希望 Kimi 完成的工作。")
      return
    }
    guard let workspacePath = state.workspacePath else {
      notice = Notice(kind: .error, text: "请先选择项目文件夹。")
      return
    }
    let workspaceURL = restoreWorkspaceAccess(path: workspacePath)
      ?? URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
    let resolvedWorkspacePath = workspaceURL.path

    let sessionID = UUID()
    let taskID = UUID()
    let turn = ConversationTurn(sequence: 1, userMessage: prompt)
    let decision = TaskIntentRouter.decide(for: prompt)
    let contract = TaskContract.make(prompt: prompt, decision: decision, mode: selectedMode)

    let taskEvents = [
      AgentEvent(sessionID: sessionID, taskID: taskID, turnID: turn.id, sequence: 1, actor: "desktop", kind: .sessionCreated, payload: ["mode": selectedMode.rawValue]),
      AgentEvent(sessionID: sessionID, taskID: taskID, turnID: turn.id, sequence: 2, actor: "desktop", kind: .taskPlanned, payload: ["title": prompt])
    ]

    let modelID = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)

    var task = AgentTask(
      id: taskID,
      title: prompt,
      mode: selectedMode,
      modelID: modelID,
      skillsDirectories: SkillRegistry.discover(projectDirectory: workspaceURL).map { $0.fileURL.deletingLastPathComponent().path },
      workspacePath: resolvedWorkspacePath,
      sessionID: sessionID.uuidString,
      events: [],
      structuredEvents: taskEvents,
      workItems: TaskSupervisor.makePlan(taskID: taskID, mode: selectedMode).workItems,
      agentRuns: [],
      workspaceLayout: WorkspaceLayout.defaultLayout(),
      ruleSet: AgentRuleSet(project: AgentRuleRegistry.projectRules(projectDirectory: workspaceURL)),
      turns: [turn],
      activeTurnID: turn.id
    )
    task.status = .planning
    state.tasks.insert(task, at: 0)
    seedSessionJournal(for: task)
    activeTurnIDs[task.id] = turn.id
    isComposingNewConversation = false
    selectedTaskID = task.id
    draftPrompt = ""
    schedulePersistence()

    // 使用默认的任务编排（Kimi 会通过 system prompt 自己处理任务分解）
    let agentPlan = TaskGraphCompiler.plan(from: TaskGraphCompiler.compile(
      taskID: taskID,
      sessionID: sessionID,
      contract: contract,
      model: modelID
    ))
    updateTask(taskID) { current in
      current.agentRuns = agentPlan.runs
      current.status = agentPlan.runs.isEmpty ? .draft : .planning
    }
    if selectedMode.isReadOnly {
      appendEvent("正在准备回复…", kind: .toolProgress, for: task.id, turnID: turn.id)
    } else {
      appendEvent("等待自动执行确认…", kind: .permissionRequested, for: task.id, payload: ["action": "自动执行"], requiresApproval: true, turnID: turn.id)
    }
    runSelectedTask()
  }

  func submitComposerPrompt() {
    let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      notice = Notice(kind: .error, text: "请先描述希望 Kimi 完成的工作。")
      return
    }

    guard let task = selectedTask,
          TaskWorkspacePresentation.composerSubmissionTarget(for: task) == .continueTask else {
      createTask()
      return
    }

    guard task.status != .running else {
      notice = Notice(kind: .error, text: "当前会话正在运行，请等待这一轮完成后再继续发送。")
      return
    }

    draftPrompt = ""
    let turn = ConversationTurn(
      sequence: (task.turns.last?.sequence ?? 0) + 1,
      userMessage: prompt
    )
    updateTask(task.id) { current in
      current.turns.append(turn)
      current.activeTurnID = turn.id
      current.updatedAt = .now
    }
    activeTurnIDs[task.id] = turn.id
    appendEvent("你：\(prompt)", kind: .output, for: task.id, payload: ["role": "user", "text": prompt], turnID: turn.id)
    if task.mode.isReadOnly {
      appendEvent("正在准备回复…", kind: .toolProgress, for: task.id, turnID: turn.id)
      startTask(task, permission: .interactive, promptOverride: prompt)
    } else {
      pendingAutomaticTaskID = task.id
      pendingAutomaticPrompt = prompt
      appendEvent("等待自动执行确认…", kind: .permissionRequested, for: task.id, payload: ["action": "自动执行"], requiresApproval: true, turnID: turn.id)
      showAutomaticConfirmation = true
    }
  }

  func runSelectedTask() {
    guard let task = selectedTask else { return }
    if task.status == .waitingForUser {
      resumeSelectedTask()
      return
    }
    if task.mode.isReadOnly {
      startTask(task, permission: .interactive)
    } else {
      pendingAutomaticTaskID = task.id
      pendingAutomaticPrompt = nil
      showAutomaticConfirmation = true
    }
  }

  func confirmAutomaticTask() {
    guard let pendingAutomaticTaskID,
          let task = state.tasks.first(where: { $0.id == pendingAutomaticTaskID }) else {
      showAutomaticConfirmation = false
      return
    }
    self.pendingAutomaticTaskID = nil
    let promptOverride = pendingAutomaticPrompt
    self.pendingAutomaticPrompt = nil
    showAutomaticConfirmation = false
    startTask(task, permission: .automatic, promptOverride: promptOverride)
  }

  func cancelAutomaticTask() {
    pendingAutomaticTaskID = nil
    pendingAutomaticPrompt = nil
    showAutomaticConfirmation = false
  }

  func cancelSelectedTask() {
    guard let selectedTaskID else { return }
    cancelNativeToolApproval(for: selectedTaskID)
    automatedGraphTasks.removeValue(forKey: selectedTaskID)?.cancel()
    if let supervisor = agentGraphSupervisors[selectedTaskID] {
      Task { await supervisor.cancelAll() }
    }
    if let operationID = harnessOperationIDs[selectedTaskID], let harness = harnesses[selectedTaskID] {
      Task { await harness.abort(operationID) }
      harnessOperationIDs.removeValue(forKey: selectedTaskID)
    }
    runningProcesses[selectedTaskID]?.terminate()
    runningAgentHosts[selectedTaskID]?.terminate()
    stopTerminalCommand(for: selectedTaskID)
    endTaskWorkspaceAccess(for: selectedTaskID)
    updateTask(selectedTaskID) { task in
      task.status = .cancelled
      if let turnID = task.activeTurnID,
         let index = task.turns.firstIndex(where: { $0.id == turnID }) {
        task.turns[index].status = .cancelled
        task.turns[index].updatedAt = .now
      }
      task.updatedAt = .now
    }
    appendEvent("任务已停止。", for: selectedTaskID)
  }

  func pauseSelectedTask() {
    guard let task = selectedTask, task.status == .running else { return }
    cancelNativeToolApproval(for: task.id)
    if let operationID = harnessOperationIDs[task.id], let harness = harnesses[task.id] {
      Task { await harness.suspend(operationID) }
    }
    runningProcesses[task.id]?.terminate()
    runningAgentHosts[task.id]?.terminate()
    endTaskWorkspaceAccess(for: task.id)
    if let supervisor = agentGraphSupervisors[task.id] {
      Task {
        let snapshot = await supervisor.snapshot()
        for run in snapshot.runs where run.state == .running || run.state == .awaitingApproval {
          await supervisor.pause(run.id)
        }
      }
    }
    updateTask(task.id) { current in
      current.status = .waitingForUser
      if let turnID = current.activeTurnID,
         let index = current.turns.firstIndex(where: { $0.id == turnID }) {
        current.turns[index].status = .paused
        current.turns[index].updatedAt = .now
      }
      current.updatedAt = .now
    }
    appendEvent("任务已暂停，可继续执行。", kind: .toolProgress, for: task.id)
  }

  func resumeSelectedTask() {
    guard let task = selectedTask, task.status == .waitingForUser || task.status == .failed || task.status == .blocked else {
      return
    }
    if let supervisor = agentGraphSupervisors[task.id] {
      Task { @MainActor [weak self] in
        let snapshot = await supervisor.snapshot()
        for run in snapshot.runs where run.state == .paused || run.state == .interrupted {
          await supervisor.continueRun(run.id)
        }
        self?.startAgentGraphDriver(taskID: task.id)
      }
      return
    }
    if task.status == .waitingForUser,
       let operationID = harnessOperationIDs[task.id],
       let harness = harnesses[task.id] {
      Task {
        do {
          try await harness.resume(.main)
        } catch {
          await MainActor.run { [weak self] in
            self?.startTask(task, permission: task.mode.isReadOnly ? .interactive : .automatic)
          }
        }
      }
      _ = operationID
      return
    }
    appendEvent("继续执行任务。", kind: .taskStarted, for: task.id)
    startTask(task, permission: task.mode.isReadOnly ? .interactive : .automatic)
  }

  func submitTerminalCommand(_ rawCommand: String) {
    guard let task = selectedTask else {
      notice = Notice(kind: .error, text: "请先选择一个会话，再使用终端。")
      return
    }
    let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return }
    requestTerminalCommand(command, for: task, actor: .user)
  }

  func openInteractiveTerminalTab(environmentProfileID: UUID? = nil) {
    let cwd = selectedTask?.worktreePath ?? selectedTask?.workspacePath ?? state.workspacePath
    guard let cwd, FileManager.default.fileExists(atPath: cwd) else {
      notice = Notice(kind: .error, text: "请先选择一个有效项目目录，再打开交互式终端。")
      return
    }
    let taskID = selectedTask?.id
    let profile = environmentProfileID.flatMap { id in terminalWorkspace.environmentProfiles.first(where: { $0.id == id }) }
    let resolvedCWD = profile?.workingDirectory ?? cwd
    let tab = terminalWorkspace.openLocalTab(
      title: selectedTask.map { "Shell · \($0.title.prefix(22))" } ?? "项目 Shell",
      cwd: resolvedCWD,
      taskID: taskID
    )
    if let index = terminalWorkspace.tabs.firstIndex(where: { $0.id == tab.id }) {
      terminalWorkspace.tabs[index].environmentProfileID = profile?.id
      terminalWorkspace.tabs[index].shellPath = profile?.shellPath ?? "/bin/zsh"
    }
    terminalWorkspace.updateTab(tab.id, status: .running)
    syncTerminalWorkspace()
    startPTYTab(
      terminalWorkspace.tabs.first(where: { $0.id == tab.id }) ?? tab,
      command: "",
      cwd: URL(fileURLWithPath: resolvedCWD, isDirectory: true),
      interactive: true,
      environmentProfile: profile
    )
  }

  func openSSHTerminalTab(profile: SSHProfile) {
    let tab = terminalWorkspace.openSSHTab(profile: profile, taskID: selectedTask?.id)
    terminalWorkspace.updateTab(tab.id, status: .running)
    syncTerminalWorkspace()
    startPTYTab(
      tab,
      command: TerminalSSHAdapter.command(for: profile),
      cwd: URL(fileURLWithPath: selectedTask?.workspacePath ?? state.workspacePath ?? FileManager.default.currentDirectoryPath, isDirectory: true),
      interactive: false,
      runtimeEnvironment: sshAskPassEnvironment(for: profile)
    )
  }

  func saveSSHProfile(_ profile: SSHProfile) {
    guard SSHProfileValidation.validate(profile).isEmpty else {
      notice = Notice(kind: .error, text: SSHProfileValidation.validate(profile).joined(separator: "、"))
      return
    }
    if let index = terminalWorkspace.sshProfiles.firstIndex(where: { $0.id == profile.id }) {
      terminalWorkspace.sshProfiles[index] = profile
    } else {
      terminalWorkspace.sshProfiles.append(profile)
    }
    syncTerminalWorkspace()
    notice = Notice(kind: .success, text: "SSH 配置已保存")
  }

  func deleteSSHProfile(_ id: UUID) {
    terminalWorkspace.sshProfiles.removeAll { $0.id == id }
    try? credentialVault.delete(key: sshCredentialKey(profileID: id))
    syncTerminalWorkspace()
  }

  func saveSSHCredential(profileID: UUID, secret: String) {
    let trimmed = secret.trimmingCharacters(in: .newlines)
    guard !trimmed.isEmpty else { return }
    do {
      try credentialVault.write(trimmed, key: sshCredentialKey(profileID: profileID))
      if let index = terminalWorkspace.sshProfiles.firstIndex(where: { $0.id == profileID }) {
        terminalWorkspace.sshProfiles[index].credentialReference = .keychain(
          account: "SSH \(terminalWorkspace.sshProfiles[index].name)",
          service: "com.kimiagent.desktop.ssh"
        )
      }
      syncTerminalWorkspace()
      notice = Notice(kind: .success, text: "SSH 凭据已保存到 \(credentialStorageTitle)")
    } catch {
      notice = Notice(kind: .error, text: "无法保存 SSH 凭据：\(error.localizedDescription)")
    }
  }

  func saveEnvironmentProfile(_ profile: TerminalEnvironmentProfile) {
    if let index = terminalWorkspace.environmentProfiles.firstIndex(where: { $0.id == profile.id }) {
      terminalWorkspace.environmentProfiles[index] = profile
    } else {
      terminalWorkspace.environmentProfiles.append(profile)
    }
    syncTerminalWorkspace()
    notice = Notice(kind: .success, text: "环境配置已保存")
  }

  func deleteEnvironmentProfile(_ id: UUID) {
    terminalWorkspace.environmentProfiles.removeAll { $0.id == id }
    syncTerminalWorkspace()
  }

  func reconnectInteractiveTerminal(_ id: UUID) {
    guard let tab = terminalWorkspace.tabs.first(where: { $0.id == id }), tab.kind == .ssh,
          let profileID = tab.sshProfileID,
          let profile = terminalWorkspace.sshProfiles.first(where: { $0.id == profileID }) else { return }
    terminalPTYHandles[id]?.terminate()
    terminalReconnectTasks[id]?.cancel()
    terminalReconnectTasks.removeValue(forKey: id)
    terminalReconnectAttempts[id] = 0
    terminalWorkspace.updateTab(id, status: .running)
    syncTerminalWorkspace()
    startPTYTab(tab, command: TerminalSSHAdapter.command(for: profile, recovery: .tmux(sessionName: "kimi-\(id.uuidString.prefix(8))")), cwd: URL(fileURLWithPath: state.workspacePath ?? FileManager.default.currentDirectoryPath), interactive: false)
  }

  func configureTerminalSplit(with tabID: UUID, orientation: TerminalPaneOrientation) {
    guard let activeID = terminalWorkspace.activeTabID, activeID != tabID,
          terminalWorkspace.tabs.contains(where: { $0.id == tabID }) else { return }
    var layout = terminalWorkspace.paneLayout ?? .single(activeID)
    layout.split(orientation, with: tabID)
    terminalWorkspace.paneLayout = layout
    syncTerminalWorkspace()
  }

  func resetTerminalSplit() {
    guard let activeID = terminalWorkspace.activeTabID else { return }
    terminalWorkspace.paneLayout = .single(activeID)
    syncTerminalWorkspace()
  }

  func clearInteractiveTerminalOutput(_ id: UUID? = nil) {
    let resolvedID = id ?? terminalWorkspace.activeTabID
    guard let resolvedID, let index = terminalWorkspace.tabs.firstIndex(where: { $0.id == resolvedID }) else { return }
    terminalWorkspace.tabs[index].output = ""
    terminalWorkspace.tabs[index].updatedAt = .now
    syncTerminalWorkspace()
  }

  func exportInteractiveTerminal(_ id: UUID? = nil, asHTML: Bool) {
    let resolvedID = id ?? terminalWorkspace.activeTabID
    guard let resolvedID, let tab = terminalWorkspace.tabs.first(where: { $0.id == resolvedID }) else { return }
    let panel = NSSavePanel()
    panel.title = "导出终端输出"
    panel.nameFieldStringValue = "\(tab.title)-terminal.\(asHTML ? "html" : "txt")"
    panel.allowedContentTypes = asHTML ? [.html] : [.plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let content = asHTML ? TerminalTranscriptExporter.html(tab.output) : TerminalTranscriptExporter.plainText(tab.output)
      try content.write(to: url, atomically: true, encoding: .utf8)
      notice = Notice(kind: .success, text: "终端输出已导出")
    } catch {
      notice = Notice(kind: .error, text: "导出失败：\(error.localizedDescription)")
    }
  }

  func discoverTmuxSessions(for profile: SSHProfile) {
    let cwd = URL(fileURLWithPath: state.workspacePath ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        try TerminalCommandRunner.run(command: TerminalSSHAdapter.tmuxListCommand(for: profile), cwd: cwd)
      }.result
      guard let self else { return }
      switch result {
      case .success(let commandResult):
        tmuxSessions[profile.id] = TmuxSessionRecord.parse(commandResult.standardOutput)
        notice = Notice(kind: .success, text: tmuxSessions[profile.id]?.isEmpty == true ? "没有可恢复的 tmux 会话" : "已发现 \(tmuxSessions[profile.id]?.count ?? 0) 个 tmux 会话")
      case .failure(let error):
        notice = Notice(kind: .error, text: "读取 tmux 会话失败：\(error.localizedDescription)")
      }
    }
  }

  private func startPTYTab(
    _ tab: TerminalTabRecord,
    command: String,
    cwd: URL,
    interactive: Bool,
    environmentProfile: TerminalEnvironmentProfile? = nil,
    runtimeEnvironment: [String: String] = [:]
  ) {
    do {
      let handle = try TerminalPTYRunner.start(
        configuration: TerminalPTYConfiguration(
          command: command,
          cwd: cwd,
          shellPath: environmentProfile?.shellPath ?? tab.shellPath,
          environment: (environmentProfile?.resolvedEnvironment() ?? [:]).merging(runtimeEnvironment, uniquingKeysWith: { _, new in new }),
          rows: tab.rows,
          columns: tab.columns,
          interactive: interactive
        ),
        onOutput: { [weak self] output in
          Task { @MainActor in
            guard let self else { return }
            self.terminalWorkspace.appendOutput(tabID: tab.id, text: output.text)
            self.syncTerminalWorkspace()
          }
        }
      )
      terminalPTYHandles[tab.id] = handle
      terminalPTYWaitTasks[tab.id] = Task { [weak self] in
        let result = await Task.detached(priority: .utility) { handle.wait() }.value
        await MainActor.run {
          guard let self else { return }
          self.terminalPTYWaitTasks.removeValue(forKey: tab.id)
          self.terminalPTYHandles.removeValue(forKey: tab.id)
          guard self.terminalWorkspace.tabs.contains(where: { $0.id == tab.id }) else { return }
          let currentStatus = self.terminalWorkspace.tabs.first(where: { $0.id == tab.id })?.status
          guard currentStatus == .running else { return }
          self.terminalWorkspace.updateTab(tab.id, status: result.exitCode == 0 ? .idle : .disconnected)
          self.syncTerminalWorkspace()
          if result.exitCode != 0, tab.kind == .ssh {
            self.scheduleSSHReconnect(tabID: tab.id)
          }
        }
      }
    } catch {
      terminalWorkspace.updateTab(tab.id, status: .failed)
      syncTerminalWorkspace()
      notice = Notice(kind: .error, text: "交互式终端启动失败：\(error.localizedDescription)")
    }
  }

  func selectInteractiveTerminalTab(_ id: UUID) {
    terminalWorkspace.selectTab(id)
    syncTerminalWorkspace()
  }

  func closeInteractiveTerminalTab(_ id: UUID) {
    terminalPTYHandles[id]?.terminate()
    terminalPTYWaitTasks[id]?.cancel()
    terminalPTYWaitTasks.removeValue(forKey: id)
    terminalReconnectTasks[id]?.cancel()
    terminalReconnectTasks.removeValue(forKey: id)
    terminalReconnectAttempts.removeValue(forKey: id)
    terminalPTYHandles.removeValue(forKey: id)
    terminalWorkspace.closeTab(id)
    syncTerminalWorkspace()
  }

  func sendInteractiveTerminalInput(_ input: String) {
    guard let tabID = terminalWorkspace.activeTabID,
          let data = input.data(using: .utf8) else { return }
    routeInteractiveTerminalInput(tabID: tabID, data: data)
  }

  func sendInteractiveTerminalData(tabID: UUID, data: Data) {
    routeInteractiveTerminalInput(tabID: tabID, data: data)
  }

  private func routeInteractiveTerminalInput(tabID: UUID, data: Data) {
    guard let handle = terminalPTYHandles[tabID] else { return }
    // SwiftTerm sends ordinary keystrokes as one-byte chunks. Only inspect multi-byte input for paste risk so typing
    // a command such as `sudo ...` does not interrupt the user before they press Enter.
    guard data.count > 1,
          let text = String(data: data, encoding: .utf8),
          TerminalPasteSafety.requiresApproval(for: text) else {
      handle.write(data)
      return
    }
    pendingInteractiveTerminalPaste = PendingInteractiveTerminalPaste(tabID: tabID, text: text, data: data)
  }

  func resolveInteractiveTerminalPaste(_ approved: Bool) {
    guard let pending = pendingInteractiveTerminalPaste else { return }
    pendingInteractiveTerminalPaste = nil
    guard approved, let handle = terminalPTYHandles[pending.tabID] else { return }
    handle.write(pending.data)
  }

  func sendInteractiveTerminalControl(_ byte: UInt8) {
    guard let tabID = terminalWorkspace.activeTabID,
          let handle = terminalPTYHandles[tabID] else { return }
    handle.sendControl(byte)
  }

  func stopInteractiveTerminal() {
    guard let tabID = terminalWorkspace.activeTabID else { return }
    terminalPTYHandles[tabID]?.terminate()
    terminalPTYWaitTasks[tabID]?.cancel()
    terminalPTYWaitTasks.removeValue(forKey: tabID)
    terminalReconnectTasks[tabID]?.cancel()
    terminalReconnectTasks.removeValue(forKey: tabID)
    terminalReconnectAttempts.removeValue(forKey: tabID)
    terminalWorkspace.updateTab(tabID, status: .interrupted)
    syncTerminalWorkspace()
  }

  private func scheduleSSHReconnect(tabID: UUID) {
    guard terminalReconnectTasks[tabID] == nil,
          let tab = terminalWorkspace.tabs.first(where: { $0.id == tabID }),
          let profileID = tab.sshProfileID,
          let profile = terminalWorkspace.sshProfiles.first(where: { $0.id == profileID }) else { return }
    let policy = profile.reconnectPolicy
    let attempt = (terminalReconnectAttempts[tabID] ?? 0) + 1
    guard attempt <= policy.maximumAttempts else {
      terminalWorkspace.appendOutput(tabID: tabID, text: "\nSSH 自动重连已停止，请检查网络或认证配置。\n")
      syncTerminalWorkspace()
      return
    }
    terminalReconnectAttempts[tabID] = attempt
    let delay = policy.delay(forAttempt: attempt)
    terminalWorkspace.appendOutput(tabID: tabID, text: "\nSSH 已断开，\(delay) 秒后第 \(attempt)/\(policy.maximumAttempts) 次自动重连。\n")
    syncTerminalWorkspace()
    terminalReconnectTasks[tabID] = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
      guard !Task.isCancelled, let self else { return }
      self.terminalReconnectTasks.removeValue(forKey: tabID)
      guard self.terminalWorkspace.tabs.contains(where: { $0.id == tabID }),
            self.terminalWorkspace.tabs.first(where: { $0.id == tabID })?.status == .disconnected else { return }
      self.terminalWorkspace.updateTab(tabID, status: .running)
      self.syncTerminalWorkspace()
      self.startPTYTab(
        tab,
        command: TerminalSSHAdapter.command(for: profile, recovery: .tmux(sessionName: "kimi-\(tabID.uuidString.prefix(8))")),
        cwd: URL(fileURLWithPath: self.state.workspacePath ?? FileManager.default.currentDirectoryPath, isDirectory: true),
        interactive: false,
        runtimeEnvironment: self.sshAskPassEnvironment(for: profile)
      )
    }
  }

  private func sshCredentialKey(profileID: UUID) -> String {
    "ssh.askpass.\(profileID.uuidString)"
  }

  private func sshAskPassEnvironment(for profile: SSHProfile) -> [String: String] {
    guard case .keychain? = profile.credentialReference,
          let secret = try? credentialVault.read(key: sshCredentialKey(profileID: profile.id)),
          !secret.isEmpty else { return [:] }
    let scriptURL = applicationSupportDirectory.appendingPathComponent("ssh-askpass.sh")
    let script = "#!/bin/sh\nprintf '%s' \"$KIMI_SSH_ASKPASS_SECRET\"\n"
    if !FileManager.default.fileExists(atPath: scriptURL.path) {
      try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }
    return [
      "SSH_ASKPASS": scriptURL.path,
      "SSH_ASKPASS_REQUIRE": "force",
      "DISPLAY": "1",
      "KIMI_SSH_ASKPASS_SECRET": secret
    ]
  }

  func resizeInteractiveTerminal(rows: Int, columns: Int) {
    guard let tabID = terminalWorkspace.activeTabID else { return }
    resizeInteractiveTerminal(tabID: tabID, rows: rows, columns: columns)
  }

  func resizeInteractiveTerminal(tabID: UUID, rows: Int, columns: Int) {
    guard let tab = terminalWorkspace.tabs.first(where: { $0.id == tabID }),
          tab.rows != max(2, rows) || tab.columns != max(20, columns) else { return }
    terminalPTYHandles[tabID]?.resize(rows: rows, columns: columns)
    terminalWorkspace.updateTab(tabID, rows: rows, columns: columns)
    syncTerminalWorkspace()
  }

  func stopTerminalCommand(for taskID: AgentTask.ID) {
    guard let task = state.tasks.first(where: { $0.id == taskID }),
          let commandID = task.terminalSession?.history.last(where: { $0.status == .running })?.id else {
      return
    }
    cancelledTerminalCommands.insert(commandID)
    runningTerminalCommands[commandID]?.terminate()
    terminalTimeoutTasks[commandID]?.cancel()
    terminalTimeoutTasks.removeValue(forKey: commandID)
    appendTerminalOutput(taskID: taskID, commandID: commandID, stream: .standardError, text: "\n已请求停止命令。\n")
  }

  func resolvePendingTerminalApproval(_ response: TerminalApprovalResponse) {
    guard let approval = pendingTerminalApproval else { return }
    pendingTerminalApproval = nil
    guard let task = state.tasks.first(where: { $0.id == approval.taskID }) else { return }

    switch response {
    case .reject:
      updateTerminalSession(for: task.id) { session in
        session.deny(commandID: approval.commandID)
      }
      appendEvent("已拒绝终端命令：\(approval.command)", kind: .permissionDenied, for: task.id, payload: ["command": approval.command])
      if let jobID = terminalJobIDs[approval.commandID] {
        terminalWorkspace.updateJob(jobID, status: .cancelled)
        syncTerminalWorkspace()
      }
    case .approveOnce, .approveForSession:
      if response == .approveForSession {
        terminalApprovalMemory.remember(taskID: task.id, fingerprint: approval.fingerprint)
      }
      updateTerminalSession(for: task.id) { session in
        session.approve(commandID: approval.commandID, forSession: response == .approveForSession)
      }
      appendEvent("已批准终端命令：\(approval.command)", kind: .commandApproved, for: task.id, payload: ["command": approval.command])
      startTerminalCommand(taskID: task.id, commandID: approval.commandID)
    }
  }

  private func requestTerminalCommand(_ command: String, for task: AgentTask, actor: TerminalActor) {
    let cwd = task.worktreePath ?? task.workspacePath
    let evaluation = TerminalCommandPolicy().evaluate(command: command, actor: actor)
    let record = TerminalCommandRecord(
      command: command,
      cwd: cwd,
      requestedBy: actor,
      approval: evaluation.decision == .ask ? .awaitingApproval : .notRequired,
      status: evaluation.decision == .ask ? .awaitingApproval : evaluation.decision == .deny ? .denied : .queued
    )

    updateTerminalSession(for: task.id, cwd: cwd) { session in
      session.append(command: record)
      if evaluation.decision == .ask {
        session.awaitApproval(commandID: record.id)
      } else if evaluation.decision == .deny {
        session.deny(commandID: record.id)
      }
    }
    let queueSessionID = terminalWorkspace.activeTabID ?? task.terminalSession?.id ?? task.id
    let job = terminalWorkspace.enqueue(
      command: command,
      sessionID: queueSessionID,
      timeoutSeconds: 300,
      requiresApproval: evaluation.decision == .ask
    )
    terminalJobIDs[record.id] = job.id
    syncTerminalWorkspace()
    appendEvent(
      "终端请求：\(command)",
      kind: .commandRequested,
      for: task.id,
      payload: ["command": command, "risk": evaluation.risk.rawValue, "actor": actor.rawValue],
      requiresApproval: evaluation.decision == .ask
    )

    switch evaluation.decision {
    case .deny:
      appendTerminalOutput(taskID: task.id, commandID: record.id, stream: .standardError, text: "已阻止：\(evaluation.reason)\n")
      appendEvent("终端命令已阻止：\(evaluation.reason)", kind: .permissionDenied, for: task.id, payload: ["command": command])
    case .allow:
      startTerminalCommand(taskID: task.id, commandID: record.id)
    case .ask:
      if evaluation.allowSession,
         terminalApprovalMemory.contains(taskID: task.id, fingerprint: evaluation.fingerprint) {
        updateTerminalSession(for: task.id) { session in
          session.approve(commandID: record.id, forSession: true)
        }
        appendEvent("已按本会话权限自动批准终端命令：\(command)", kind: .commandApproved, for: task.id, payload: ["command": command, "remember": "task"])
        startTerminalCommand(taskID: task.id, commandID: record.id)
      } else {
        pendingTerminalApproval = PendingTerminalApproval(
          taskID: task.id,
          commandID: record.id,
          command: command,
          risk: evaluation.risk,
          reason: evaluation.reason,
          allowSession: evaluation.allowSession,
          fingerprint: evaluation.fingerprint
        )
      }
    }
  }

  private func startTerminalCommand(taskID: AgentTask.ID, commandID: UUID) {
    guard let task = state.tasks.first(where: { $0.id == taskID }),
          let record = task.terminalSession?.history.first(where: { $0.id == commandID }) else {
      return
    }
    if runningTerminalCommands[commandID] != nil { return }
    guard let jobID = terminalJobIDs[commandID],
          let job = terminalWorkspace.queuedJobs.first(where: { $0.id == jobID }) else { return }
    let runningJobs = terminalWorkspace.queuedJobs.filter { $0.status == .running }
    let startable = terminalQueueScheduler.startableJobs(from: terminalWorkspace.queuedJobs)
    guard startable.contains(where: { $0.id == job.id }) || runningJobs.contains(where: { $0.id == job.id }) else { return }

    let cwd = URL(fileURLWithPath: record.cwd, isDirectory: true)
    updateTerminalSession(for: taskID) { session in
      session.start(commandID: commandID)
    }
    terminalWorkspace.updateJob(jobID, status: .running)
    runningTerminalSessionIDs[commandID] = job.sessionID
    syncTerminalWorkspace()
    appendEvent("终端开始：\(record.command)", kind: .commandStarted, for: taskID, payload: ["command": record.command, "cwd": record.cwd])

    do {
      // Queued task commands are Agent effects, not the user's unrestricted
      // interactive terminal. Keep them inside the Worktree at the OS layer
      // even after the higher-level approval has been granted.
      let sandbox = TerminalSandboxConfiguration.strict(
        workspaceURL: URL(fileURLWithPath: task.worktreePath ?? task.workspacePath, isDirectory: true),
        scratchURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("kimi-agent-terminal-\(taskID.uuidString)-\(commandID.uuidString)", isDirectory: true)
      )
      let handle = try TerminalCommandRunner.start(
        command: record.command,
        cwd: cwd,
        sandbox: sandbox,
        onOutput: { [weak self] output in
          Task { @MainActor in
            self?.appendTerminalOutput(taskID: taskID, commandID: commandID, stream: output.stream, text: output.text)
          }
        }
      )
      runningTerminalCommands[commandID] = handle
      terminalTimeoutTasks[commandID] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 300_000_000_000)
        guard !Task.isCancelled, let self, self.runningTerminalCommands[commandID]?.isRunning == true else { return }
        self.cancelledTerminalCommands.insert(commandID)
        self.appendTerminalOutput(taskID: taskID, commandID: commandID, stream: .standardError, text: "\n命令超时（5 分钟），已停止。\n")
        self.runningTerminalCommands[commandID]?.terminate()
      }
      Task { [weak self] in
        let result = await Task.detached(priority: .userInitiated) { handle.wait() }.value
        await MainActor.run {
          self?.finishTerminalCommand(taskID: taskID, commandID: commandID, result: result)
        }
      }
    } catch {
      updateTerminalSession(for: taskID) { session in
        session.appendOutput(commandID: commandID, stream: .standardError, text: error.localizedDescription)
        session.finish(commandID: commandID, exitCode: 1)
      }
      appendEvent("终端启动失败：\(error.localizedDescription)", kind: .commandFinished, for: taskID, payload: ["command": record.command, "exitCode": "1"])
    }
  }

  private func finishTerminalCommand(taskID: AgentTask.ID, commandID: UUID, result: TerminalCommandResult) {
    let wasCancelled = cancelledTerminalCommands.remove(commandID) != nil
    terminalTimeoutTasks[commandID]?.cancel()
    terminalTimeoutTasks.removeValue(forKey: commandID)
    runningTerminalCommands.removeValue(forKey: commandID)
    runningTerminalSessionIDs.removeValue(forKey: commandID)
    if let jobID = terminalJobIDs.removeValue(forKey: commandID) {
      terminalWorkspace.updateJob(jobID, status: wasCancelled ? .cancelled : result.exitCode == 0 ? .completed : .failed)
      syncTerminalWorkspace()
    }
    updateTerminalSession(for: taskID) { session in
      session.finish(commandID: commandID, exitCode: result.exitCode, cancelled: wasCancelled)
    }
    let task = state.tasks.first(where: { $0.id == taskID })
    let command = task?.terminalSession?.history.first(where: { $0.id == commandID })?.command ?? "终端命令"
    appendEvent(
      "终端结束：\(command)（exit \(result.exitCode)）",
      kind: .commandFinished,
      for: taskID,
      payload: ["command": command, "exitCode": String(result.exitCode), "cancelled": wasCancelled ? "true" : "false"]
    )
    drainTerminalQueue()
  }

  private func drainTerminalQueue() {
    let startable = terminalQueueScheduler.startableJobs(from: terminalWorkspace.queuedJobs)
    for job in startable {
      guard let commandID = terminalJobIDs.first(where: { $0.value == job.id })?.key,
            let task = state.tasks.first(where: { $0.terminalSession?.history.contains(where: { $0.id == commandID }) == true }) else { continue }
      startTerminalCommand(taskID: task.id, commandID: commandID)
    }
  }

  private func appendTerminalOutput(taskID: AgentTask.ID, commandID: UUID, stream: TerminalOutputStream, text: String) {
    updateTerminalSession(for: taskID) { session in
      session.appendOutput(commandID: commandID, stream: stream, text: text)
    }
  }

  private func updateTerminalSession(
    for taskID: AgentTask.ID,
    cwd: String? = nil,
    update: (inout TerminalSession) -> Void
  ) {
    updateTask(taskID) { task in
      let resolvedCWD = cwd ?? task.worktreePath ?? task.workspacePath
      if task.terminalSession == nil {
        task.terminalSession = TerminalSession(taskID: task.id, cwd: resolvedCWD)
      }
      task.terminalSession?.cwd = resolvedCWD
      if var session = task.terminalSession {
        update(&session)
        task.terminalSession = session
      }
      task.updatedAt = .now
    }
  }

  func resolvePendingToolApproval(_ response: AgentHostApprovalResponse) {
    guard let approval = pendingToolApproval else { return }
    defer { pendingToolApproval = nil }
    if response == .approveForSession {
      approvalMemory.remember(taskID: approval.taskID, fingerprint: approval.fingerprint)
    }
    if let continuation = nativeToolApprovalContinuations.removeValue(forKey: approval.requestID) {
      if response != .reject {
        updateTask(approval.taskID) { task in
          task.status = .running
          if let turnID = task.activeTurnID,
             let index = task.turns.firstIndex(where: { $0.id == turnID }) {
            task.turns[index].status = .running
            task.turns[index].updatedAt = .now
          }
          task.updatedAt = .now
        }
      }
      appendEvent(
        response == .reject ? "已拒绝工具请求：\(approval.action)" : "已批准工具请求：\(approval.action)",
        kind: response == .reject ? .permissionDenied : .permissionApproved,
        for: approval.taskID,
        payload: ["id": approval.requestID, "authority": HarnessExecutionAuthority.harnessNative.rawValue]
      )
      continuation.resume(returning: response == .reject ? .deny : .allow)
      return
    }
    respondToApproval(
      approval,
      response: response,
      autoApproved: false,
      reason: approval.allowSession ? "本任务允许复用该审批。" : "已响应工具请求。"
    )
  }

  private func requestNativeToolApproval(
    request: ToolExecutionRequest,
    definition: ToolDefinition,
    workspacePath: String
  ) async -> PermissionDecision {
    let policy = PermissionPolicy(workspacePath: workspacePath)
    let action = definition.title
    let description = request.command ?? request.resource ?? definition.description
    let evaluation = policy.approvalEvaluation(action: action, description: description, workspacePath: workspacePath)
    if evaluation.decision == .deny { return .deny }

    // Web Search / Fetch are read-only. Remember them at the provider/domain
    // level instead of the full URL, otherwise every article on the same site
    // would open another approval dialog.
    let webApprovalKey = WebToolApprovalPolicy.approvalKey(toolID: definition.id, input: request.input)
    let configuredDomain = WebToolApprovalPolicy.host(in: request.input)
    let configuredWebDomain = configuredDomain.map { WebToolApprovalPolicy.matchesConfiguredDomain(host: $0, domains: activeNetworkDomains) } ?? false
    let providerSearchIsReady = definition.id.lowercased() == "web.search" && webResearchSettings.isReady
    let automaticPublicWebRead = WebToolApprovalPolicy.canAutoApprovePublicRead(toolID: definition.id, input: request.input)
    let approvalFingerprint = webApprovalKey ?? evaluation.fingerprint
    let remembered = approvalMemory.contains(taskID: request.taskID, fingerprint: approvalFingerprint)
    if evaluation.decision == .allow || remembered || configuredWebDomain || providerSearchIsReady || automaticPublicWebRead {
      if webApprovalKey != nil || evaluation.remember == .task || configuredWebDomain || providerSearchIsReady || automaticPublicWebRead {
        approvalMemory.remember(taskID: request.taskID, fingerprint: approvalFingerprint)
      }
      return .allow
    }
    updateTask(request.taskID) { task in
      task.status = .waitingForApproval
      if let turnID = task.activeTurnID,
         let index = task.turns.firstIndex(where: { $0.id == turnID }) {
        task.turns[index].status = .waitingForApproval
        task.turns[index].updatedAt = .now
      }
      task.updatedAt = .now
    }
    appendEvent("等待工具审批：\(action)", kind: .permissionRequested, for: request.taskID, payload: [
      "id": request.id.uuidString,
      "action": action,
      "description": description,
      "authority": HarnessExecutionAuthority.harnessNative.rawValue
    ], requiresApproval: true)
    return await withCheckedContinuation { continuation in
      nativeToolApprovalContinuations[request.id.uuidString] = continuation
      pendingToolApproval = PendingToolApproval(
        taskID: request.taskID,
        requestID: request.id.uuidString,
        action: action,
        description: description,
        allowSession: webApprovalKey != nil || evaluation.remember == .task,
        fingerprint: approvalFingerprint
      )
    }
  }

  private func cancelNativeToolApproval(for taskID: AgentTask.ID) {
    guard let approval = pendingToolApproval, approval.taskID == taskID else { return }
    pendingToolApproval = nil
    if let continuation = nativeToolApprovalContinuations.removeValue(forKey: approval.requestID) {
      continuation.resume(returning: .deny)
    }
  }

  private func handlePermissionRequest(_ event: AgentEvent, taskID: AgentTask.ID) {
    let requestID = event.payload["id"] ?? event.id.uuidString
    let action = event.payload["action"] ?? "工具操作"
    let description = event.payload["description"] ?? "Kimi 请求执行一个需要确认的操作。"
    let workspacePath = state.tasks.first(where: { $0.id == taskID })?.worktreePath
      ?? state.tasks.first(where: { $0.id == taskID })?.workspacePath
      ?? state.workspacePath
      ?? FileManager.default.currentDirectoryPath
    let policy = PermissionPolicy(workspacePath: workspacePath)
    let evaluation = policy.approvalEvaluation(action: action, description: description, workspacePath: workspacePath)

    if evaluation.decision == .deny {
      let approval = PendingToolApproval(
        taskID: taskID,
        requestID: requestID,
        action: action,
        description: description,
        allowSession: false,
        fingerprint: evaluation.fingerprint
      )
      respondToApproval(
        approval,
        response: .reject,
        autoApproved: true,
        reason: evaluation.reason
      )
      return
    }

    if evaluation.decision == .allow || approvalMemory.contains(taskID: taskID, fingerprint: evaluation.fingerprint) {
      approvalMemory.remember(taskID: taskID, fingerprint: evaluation.fingerprint)
      let approval = PendingToolApproval(
        taskID: taskID,
        requestID: requestID,
        action: action,
        description: description,
        allowSession: true,
        fingerprint: evaluation.fingerprint
      )
      respondToApproval(
        approval,
        response: .approveForSession,
        autoApproved: true,
        reason: evaluation.reason
      )
      return
    }

    updateTask(taskID) { task in
      task.status = .waitingForApproval
      if let turnID = task.activeTurnID,
         let index = task.turns.firstIndex(where: { $0.id == turnID }) {
        task.turns[index].status = .waitingForApproval
        task.turns[index].updatedAt = .now
      }
      task.updatedAt = .now
    }

    pendingToolApproval = PendingToolApproval(
      taskID: taskID,
      requestID: requestID,
      action: action,
      description: description,
      allowSession: evaluation.remember == .task,
      fingerprint: evaluation.fingerprint
    )
  }

  private func respondToApproval(
    _ approval: PendingToolApproval,
    response: AgentHostApprovalResponse,
    autoApproved: Bool,
    reason: String
  ) {
    do {
      try runningAgentHosts[approval.taskID]?.approve(id: approval.requestID, response: response)
      if response != .reject {
        updateTask(approval.taskID) { task in
          task.status = .running
          if let turnID = task.activeTurnID,
             let index = task.turns.firstIndex(where: { $0.id == turnID }) {
            task.turns[index].status = .running
            task.turns[index].updatedAt = .now
          }
        }
      }
      appendEvent(
        autoApproved
          ? "已自动批准工具请求：\(approval.action)"
          : response == .reject ? "已拒绝工具请求：\(approval.action)" : "已批准工具请求：\(approval.action)",
        kind: response == .reject ? .permissionDenied : .permissionApproved,
        for: approval.taskID,
        payload: [
          "id": approval.requestID,
          "action": approval.action,
          "description": approval.description,
          "reason": reason,
          "autoApproved": autoApproved ? "true" : "false",
          "remember": approval.allowSession ? "task" : "never"
        ]
      )
    } catch {
      appendEvent("无法响应工具审批：\(error.localizedDescription)", kind: .error, for: approval.taskID)
      notice = Notice(kind: .error, text: "无法响应工具审批：\(error.localizedDescription)")
    }
  }

  func runDiagnostics() {
    let result = NativeRuntimeLocator.diagnostics()
    let identity = kimiRuntimeIdentity
    let identityMessage: String
    switch identity.mode {
    case .apiKey:
      identityMessage = identity.isAPIConfigured
        ? "连接：API Key 模式 · \(identity.modelID) · \(identity.baseURL) · \(kimiAvailableModels.count) 个模型"
        : "连接：API Key 模式尚未保存 Key"
    case .kimiCode:
      identityMessage = "连接：Kimi Code 登录模式 · 使用本机隔离配置目录"
    }
    let ready = result.isReady && (identity.mode != .apiKey || identity.isAPIConfigured)
    notice = Notice(kind: ready ? .success : .error, text: "\(result.message)\n\(identityMessage)")
  }

  func openKimiConnectionSettings() {
    refreshKimiRuntimeIdentity()
    refreshKimiModelsIfNeeded()
    showLoginSheet = true
  }

  func refreshKimiModels() {
    refreshKimiModelsIfNeeded(force: true)
  }

  func selectKimiRuntimeMode(_ mode: KimiRuntimeIdentityMode) {
    do {
      switch mode {
      case .kimiCode:
        try kimiRuntimeIdentityStore.useKimiCode()
      case .apiKey:
        try kimiRuntimeIdentityStore.useAPIKey()
      }
      refreshKimiRuntimeIdentity()
      refreshKimiModelsIfNeeded()
      notice = Notice(kind: .success, text: mode == .apiKey ? "已切换到 API Key 模式。" : "已切换到 Kimi Code 登录模式。")
    } catch {
      refreshKimiRuntimeIdentity()
      notice = Notice(kind: .error, text: error.localizedDescription)
    }
  }

  func saveKimiAPIConnection(apiKey: String, baseURL: String, modelID: String) {
    do {
      let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let keyToSave = trimmedKey.isEmpty ? (try kimiRuntimeIdentityStore.apiKey() ?? "") : trimmedKey
      try kimiRuntimeIdentityStore.connectAPI(apiKey: keyToSave, baseURL: baseURL, modelID: modelID)
      refreshKimiRuntimeIdentity()
      if selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        selectedModelID = kimiRuntimeIdentity.modelID
      }
      refreshKimiModelsIfNeeded()
      notice = Notice(kind: .success, text: "API Key 已保存，Kimi Runtime 会使用你的 API 额度。")
    } catch {
      refreshKimiRuntimeIdentity()
      notice = Notice(kind: .error, text: "无法保存 API 配置：\(error.localizedDescription)")
    }
  }

  func disconnectKimiAPIConnection() {
    do {
      try kimiRuntimeIdentityStore.disconnectAPI(applicationSupportDirectory: applicationSupportDirectory)
      refreshKimiRuntimeIdentity()
      notice = Notice(kind: .success, text: "已清除 API Key，并切回 Kimi Code 登录模式。")
    } catch {
      notice = Notice(kind: .error, text: "无法清除 API Key：\(error.localizedDescription)")
    }
  }

  func saveWebResearchSettings(
    provider: WebSearchProvider,
    apiKey: String,
    endpoint: String,
    allowedDomains: String,
    defaultResultLimit: Int
  ) {
    do {
      let domains = allowedDomains
        .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " || $0 == ";" })
        .map(String.init)
      try webResearchSettingsStore.save(
        provider: provider,
        apiKey: apiKey,
        endpoint: endpoint,
        allowedDomains: domains,
        defaultResultLimit: defaultResultLimit
      )
      invalidateWebResearchBridge()
      webResearchCapability = .notTested
      refreshWebResearchSettings()
      notice = Notice(kind: .success, text: provider == .kimiOfficial
        ? "Kimi 官方联网已启用，将复用当前 Kimi API Key。"
        : "\(provider.title) 已启用。搜索结果可继续使用 Web Fetch 读取；直接抓取仅允许已授权域名。")
    } catch {
      refreshWebResearchSettings()
      notice = Notice(kind: .error, text: "无法保存 Web Search 配置：\(error.localizedDescription)")
    }
  }

  func disconnectWebResearch() {
    do {
      try webResearchSettingsStore.disconnect()
      invalidateWebResearchBridge()
      webResearchCapability = .notTested
      refreshWebResearchSettings()
      notice = Notice(kind: .success, text: "已关闭 Web Search，并清除保存的搜索 API Key。")
    } catch {
      notice = Notice(kind: .error, text: "无法关闭 Web Search：\(error.localizedDescription)")
    }
  }

  func testWebResearchConnection() {
    guard !webResearchSettings.provider.usesKimiAPIKey || (kimiRuntimeIdentity.mode == .apiKey && kimiRuntimeIdentity.isAPIConfigured) else {
      notice = Notice(kind: .error, text: "请先在 API Key 模式保存 Kimi API Key，再测试官方联网。")
      return
    }
    webResearchCapability = .checking
    guard let apiKey = try? kimiRuntimeIdentityStore.apiKey(), !apiKey.isEmpty,
          let baseURL = URL(string: kimiRuntimeIdentity.baseURL) else {
      webResearchCapability = .unavailable("Kimi API Key 或 Base URL 未配置。")
      notice = Notice(kind: .error, text: "请先保存 Kimi API Key 和 Base URL。")
      return
    }
    let modelID = KimiRuntimeIdentityStore.resolvedModelID(taskModelID: nil, fallbackModelID: kimiRuntimeIdentity.modelID)
    Task { [weak self] in
      do {
        guard let self else { return }
        let runtime = try await self.makeNativeWebRuntime(modelID: modelID, baseURL: baseURL, apiKey: apiKey)
        let result = try await runtime.search(WebSearchRequest(query: "Kimi 官方联网连接测试", maxResults: 1))
        guard !result.sources.isEmpty else {
          throw WebRuntimeError.providerFailure("联网服务已连接，但没有返回可验证来源。")
        }
        self.webResearchCapability = .available
        self.notice = Notice(kind: .success, text: "\(self.webResearchSettings.provider.title)测试通过，返回 \(result.sources.count) 个来源。")
      } catch {
        guard let self else { return }
        self.webResearchCapability = .unavailable(error.localizedDescription)
        self.notice = Notice(kind: .error, text: "联网测试失败：\(error.localizedDescription)")
      }
    }
  }

  func retryWebResearchSource(_ source: WebResearchSource, for task: AgentTask) {
    guard task.status != .running else {
      notice = Notice(kind: .error, text: "当前会话正在运行，等待本轮完成后再重试来源。")
      return
    }
    let prompt = "请重新抓取并核验这个来源：\(source.title)（\(source.url)）。若无法读取，请说明具体原因；完成后在回答里引用该来源。"
    appendEvent("正在重试来源：\(source.domain)", kind: .toolProgress, for: task.id, payload: ["url": source.url, "retry": "webResearch"])
    startTask(task, permission: .interactive, promptOverride: prompt)
  }

  func startKimiLogin() {
    guard let runtimeURL = NativeRuntimeLocator.runtimeURL(), let nodePath = NativeRuntimeLocator.nodePath() else {
      notice = Notice(kind: .error, text: "未找到内置 Kimi Runtime 或 Node，无法登录。")
      return
    }
    guard loginProcess == nil else {
      showLoginSheet = true
      return
    }

    do {
      try kimiRuntimeIdentityStore.useKimiCode()
      refreshKimiRuntimeIdentity()
    } catch {
      notice = Notice(kind: .error, text: "无法切换到 Kimi Code 登录模式：\(error.localizedDescription)")
      return
    }

    let runtimeEnvironment: [String: String]
    do {
      runtimeEnvironment = try runtimeEnvironmentForCurrentIdentity()
    } catch {
      notice = Notice(kind: .error, text: "无法准备登录环境：\(error.localizedDescription)")
      return
    }

    loginOutput = "正在启动 Kimi Code device-code 登录…\n配置目录：\(runtimeEnvironment["KIMI_SHARE_DIR"] ?? "默认")\n"
    showLoginSheet = true
    do {
      let handle = try KimiProcessRunner.start(
        KimiCommandBuilder.makeLoginCommand(runtimePath: runtimeURL.path, nodeExecutable: nodePath),
        environment: runtimeEnvironment,
        onOutput: { [weak self] output in
          Task { @MainActor in
            self?.loginOutput += output.text
          }
        }
      )
      loginProcess = handle
      Task { [weak self] in
        let result = await Task.detached(priority: .userInitiated) { handle.wait() }.value
        guard let self else { return }
        self.loginProcess = nil
        if !result.standardError.isEmpty {
          self.loginOutput += result.standardError
        }
        if result.exitCode == 0 {
          self.loginOutput += "\n登录流程已完成。"
          self.notice = Notice(kind: .success, text: "Kimi 登录流程已完成。")
        } else {
          self.loginOutput += "\n登录流程结束，退出码：\(result.exitCode)。"
          self.notice = Notice(kind: .error, text: "Kimi 登录未完成，请查看登录输出。")
        }
      }
    } catch {
      loginOutput += "启动登录失败：\(error.localizedDescription)"
      loginProcess = nil
    }
  }

  func stopKimiLogin() {
    loginProcess?.terminate()
  }

  func runComputerUseDiagnostics() {
    let result = ComputerUseController.diagnostics(promptForAccessibility: true)
    notice = Notice(kind: result.isReady ? .success : .error, text: result.message)
  }

  func connectIntegration(provider: IntegrationProvider, accountName: String, credential: String, defaultRepository: String) {
    do {
      try integrationStore.connect(
        provider: provider,
        accountName: accountName,
        credential: credential,
        defaultRepository: defaultRepository
      )
      refreshIntegrationAccounts()
      notice = Notice(kind: .success, text: "\(provider.title) 已连接。")
    } catch {
      notice = Notice(kind: .error, text: "无法连接 \(provider.title)：\(error.localizedDescription)")
    }
  }

  func disconnectIntegration(provider: IntegrationProvider) {
    do {
      try integrationStore.disconnect(provider: provider)
      refreshIntegrationAccounts()
      notice = Notice(kind: .success, text: "\(provider.title) 已断开。")
    } catch {
      notice = Notice(kind: .error, text: "无法断开 \(provider.title)：\(error.localizedDescription)")
    }
  }

  func openIntegrationAuthorization(provider: IntegrationProvider) {
    let url: URL
    switch provider {
    case .github:
      url = URL(string: "https://github.com/settings/tokens/new")!
    case .gitlab:
      url = URL(string: "https://gitlab.com/-/user_settings/personal_access_tokens")!
    }
    NSWorkspace.shared.open(url)
  }

  func handleComposerContextAction(_ action: ComposerContextChipAction) {
    switch action {
    case .runDiagnostics:
      runDiagnostics()
    case .runComputerUseDiagnostics:
      runComputerUseDiagnostics()
    case let .revealWorkspace(path):
      revealInFinder(path: path, successMessage: "已在 Finder 中显示项目。")
    case let .copyText(text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      notice = Notice(kind: .success, text: "已复制 “\(text)”。")
    case let .revealWorktree(path):
      guard let path else {
        notice = Notice(kind: .success, text: "运行 Edit / Agent 后会自动创建隔离 Worktree。")
        return
      }
      revealInFinder(path: path, successMessage: "已在 Finder 中显示隔离 Worktree。")
    }
  }

  func runVerificationForSelectedTask() {
    guard let task = selectedTask else { return }
    beginVerification(for: task, showNotice: true)
  }

  func addWorkspacePane(_ pane: WorkspacePaneKind, beside target: WorkspacePaneKind = .chat) {
    guard let taskID = selectedTaskID else { return }
    updateTask(taskID) { task in
      let current = task.workspaceLayout ?? WorkspaceLayout.defaultLayout()
      task.workspaceLayout = current.splitting(pane, beside: target, orientation: .horizontal)
      task.updatedAt = .now
    }
  }

  func resetWorkspaceLayout() {
    guard let taskID = selectedTaskID else { return }
    updateTask(taskID) { task in
      task.workspaceLayout = WorkspaceLayout.defaultLayout()
      task.updatedAt = .now
    }
  }

  private func revealInFinder(path: String, successMessage: String) {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([url])
    notice = Notice(kind: .success, text: successMessage)
  }

  private func refreshExtensionRuntime() {
    guard let workspacePath = state.workspacePath else {
      extensionRuntime?.stop()
      extensionRuntime = nil
      extensionRuntimeWorkspacePath = nil
      extensionHookResults.removeAll()
      extensionMCPStatuses = []
      extensionMCPTools = []
      extensionConfiguration = nil
      extensionSkills = []
      extensionPlugins = []
      pluginWorkerStatuses = []
      extensionAgents = []
      return
    }
    let workspaceURL = restoreWorkspaceAccess(path: workspacePath)
      ?? URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL

    let needsNewRuntime = extensionRuntime == nil || extensionRuntimeWorkspacePath != workspaceURL.path
    if needsNewRuntime {
      extensionRuntime?.stop()
      extensionRuntime = ProjectExtensionRuntime(projectDirectory: workspaceURL)
      extensionRuntimeWorkspacePath = workspaceURL.path
    }
    guard let runtime = extensionRuntime else { return }
    extensionRuntime = runtime
    extensionConfiguration = try? runtime.loadConfiguration()
    extensionSkills = (try? runtime.discoverSkills()) ?? SkillRegistry.discover(
      projectDirectory: workspaceURL,
      additionalDirectories: extensionConfiguration?.skillsDirectories.map {
        URL(fileURLWithPath: $0, relativeTo: workspaceURL).standardizedFileURL
      } ?? []
    )
    extensionPlugins = KimiPluginRegistry.discover(projectDirectory: workspaceURL)
    refreshPluginWorkers()
    extensionAgents = AgentDefinitionRegistry.discover(projectDirectory: workspaceURL)
    extensionMCPStatuses = (try? runtime.refreshMCPStatuses()) ?? []
    extensionMCPTools = []
    for status in extensionMCPStatuses {
      let serverID = status.id.uuidString
      if status.state == .running {
        Task { await mcpWorkerSupervisor.markHealthy(serverID: serverID) }
        let tools = (try? runtime.listMCPTools(serverID: status.id)) ?? []
        mcpToolCatalog.register(serverID: serverID, status: .healthy, tools: tools)
        extensionMCPTools.append(contentsOf: mcpToolCatalog.search(query: "", serverID: serverID))
      } else {
        Task { _ = await mcpWorkerSupervisor.markFailure(serverID: serverID, message: status.message) }
        mcpToolCatalog.setStatus(serverID: serverID, status: status.state == .disabled ? .unavailable : .degraded)
      }
    }
    extensionMCPTools.sort { $0.id < $1.id }
  }

  private func refreshPluginWorkers() {
    let plugins = extensionPlugins
    let nodePath = NativeRuntimeLocator.nodePath() ?? "node"
    Task { [weak self] in
      guard let self else { return }
      for plugin in plugins {
        await pluginWorkerSupervisor.register(plugin)
        guard plugin.isEnabled else { continue }
        do {
          try await pluginWorkerSupervisor.start(pluginID: plugin.id, nodeExecutable: nodePath)
        } catch {
          // A plugin without a worker is still a valid manifest-only plugin.
          // Keep its failure visible without preventing the main runtime.
        }
      }
      let statuses = await pluginWorkerSupervisor.snapshot()
      await MainActor.run { self.pluginWorkerStatuses = statuses }
    }
  }

  private func recordExtensionResults(_ results: [HookResult], for taskID: AgentTask.ID) {
    guard !results.isEmpty else { return }
    extensionHookResults[taskID, default: []].append(contentsOf: results)
    if extensionHookResults[taskID, default: []].count > maximumPersistedEvents {
      extensionHookResults[taskID]?.removeFirst(extensionHookResults[taskID, default: []].count - maximumPersistedEvents)
    }

    for result in results {
      let baseMessage = result.decision == .block
        ? "Hook 阻断：\(result.command)"
        : "Hook 已执行：\(result.command)"
      let detail: String
      if result.timedOut {
        detail = "\(baseMessage)（超时）"
      } else if let exitCode = result.exitCode, exitCode != 0 {
        detail = "\(baseMessage)（exit \(exitCode)）"
      } else {
        detail = baseMessage
      }
      appendEvent(detail, kind: result.decision == .block ? .permissionDenied : .toolFinished, for: taskID, payload: ["hook": result.hookID.uuidString])
    }
  }

  private func runLifecycleHooks(_ event: HookEvent, taskID: AgentTask.ID) {
    guard let runtime = extensionRuntime,
          let task = state.tasks.first(where: { $0.id == taskID }) else {
      return
    }
    do {
      let results = try runtime.runHooks(event: event, task: task)
      recordExtensionResults(results, for: taskID)
    } catch {
      appendEvent("扩展 hook 执行失败：\(error.localizedDescription)", kind: .error, for: taskID)
    }
  }

  private func refreshMCPStatuses() {
    guard let runtime = extensionRuntime else {
      extensionMCPStatuses = []
      return
    }
    extensionMCPStatuses = (try? runtime.refreshMCPStatuses()) ?? []
  }

  private func refreshIntegrationAccounts() {
    integrationAccounts = (try? integrationStore.accounts()) ?? IntegrationProvider.allCases.map { AccountRecord(provider: $0) }
  }

  private func refreshKimiRuntimeIdentity() {
    kimiRuntimeIdentity = (try? kimiRuntimeIdentityStore.record()) ?? KimiRuntimeIdentityRecord()
  }

  private func refreshWebResearchSettings() {
    webResearchSettings = (try? webResearchSettingsStore.record()) ?? WebResearchSettingsRecord()
  }

  private func refreshKimiModelsIfNeeded(force: Bool = false) {
    guard kimiRuntimeIdentity.mode == .apiKey, kimiRuntimeIdentity.isAPIConfigured else {
      kimiAvailableModels = KimiModelCatalogClient.fallbackModels()
      kimiModelRefreshError = nil
      lastKimiModelRefreshAt = nil
      if selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         let firstModel = kimiAvailableModels.first?.id {
        selectedModelID = firstModel
      }
      return
    }
    guard force || !isRefreshingKimiModels else { return }
    isRefreshingKimiModels = true
    kimiModelRefreshError = nil

    Task { [weak self] in
      guard let self else { return }
      do {
        let apiKey = try self.kimiRuntimeIdentityStore.apiKey() ?? ""
        let models = try await KimiModelCatalogClient.fetchModels(
          baseURL: self.kimiRuntimeIdentity.baseURL,
          apiKey: apiKey
        )
        await MainActor.run {
          let resolvedModels = models.isEmpty ? KimiModelCatalogClient.fallbackModels() : models
          self.kimiAvailableModels = resolvedModels
          self.lastKimiModelRefreshAt = .now
          self.isRefreshingKimiModels = false
          self.kimiModelRefreshError = models.isEmpty ? "模型列表为空，已显示本地默认模型。" : nil
          if self.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
             let firstModel = resolvedModels.first?.id {
            self.selectedModelID = firstModel
          }
        }
      } catch {
        await MainActor.run {
          self.kimiAvailableModels = KimiModelCatalogClient.fallbackModels()
          self.isRefreshingKimiModels = false
          self.kimiModelRefreshError = error.localizedDescription
          self.lastKimiModelRefreshAt = .now
          if self.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
             let firstModel = self.kimiAvailableModels.first?.id {
            self.selectedModelID = firstModel
          }
        }
      }
    }
  }

  private func integrationRuntimeEnvironment() -> [String: String] {
    (try? integrationStore.runtimeEnvironment()) ?? [:]
  }

  private var activeNetworkDomains: [String] {
    Array(Set((extensionConfiguration?.allowedDomains ?? []) + webResearchSettings.allowedDomains)).sorted()
  }

  private func runtimeEnvironmentForCurrentIdentity(additionalModelIDs: [String] = []) throws -> [String: String] {
    var environment = try kimiRuntimeIdentityStore.runtimeEnvironment(
      applicationSupportDirectory: applicationSupportDirectory,
      additionalModelIDs: additionalModelIDs
    )
    environment.merge(integrationRuntimeEnvironment(), uniquingKeysWith: { _, new in new })
    if webResearchSettings.isEnabled,
       (!webResearchSettings.provider.usesKimiAPIKey || kimiRuntimeIdentity.mode == .apiKey && kimiRuntimeIdentity.isAPIConfigured) {
      environment.merge(try webResearchSettingsStore.runtimeEnvironment(), uniquingKeysWith: { _, new in new })
      if webResearchSettings.provider.usesKimiAPIKey,
         let kimiAPIBaseURL = environment["KIMI_BASE_URL"],
         !kimiAPIBaseURL.isEmpty {
        environment["KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL"] = kimiAPIBaseURL
      }
    }
    return environment
  }

  private func startWebResearchBridgeIfNeeded(nodePath: String, environment: [String: String]) throws -> String? {
    guard environment["KIMI_AGENT_WEB_SEARCH_PROVIDER"] != nil else { return nil }
    let configurationFingerprint = webResearchBridgeFingerprint(environment: environment)
    if let bridge = webResearchBridge,
       bridge.isRunning,
       webResearchBridgeConfigurationFingerprint == configurationFingerprint,
       let webResearchBridgeURL,
       isWebResearchBridgeHealthy(webResearchBridgeURL) {
      return webResearchBridgeURL
    }
    invalidateWebResearchBridge()
    guard let bridgeScriptURL = NativeRuntimeLocator.webResearchBridgeURL() else {
      throw NSError(domain: "WebResearchBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到内置 Web Search Bridge。请重新构建原生安装包。"])
    }

    terminateOrphanedWebResearchBridges(scriptURL: bridgeScriptURL)

    let bridge = try KimiProcessRunner.start(
      KimiCommand(
        executableURL: URL(fileURLWithPath: nodePath),
        arguments: [bridgeScriptURL.path, "--port", "0"]
      ),
      environment: environment
    )
    guard bridge.waitForStandardOutput(containing: "\"type\":\"ready\"", timeout: 2.0),
          let bridgeURL = parseWebResearchBridgeURL(from: bridge.standardOutputSnapshot),
          isWebResearchBridgeHealthy(bridgeURL) else {
      let output = bridge.standardOutputSnapshot
      bridge.terminate()
      _ = bridge.wait()
      throw NSError(
        domain: "WebResearchBridge",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Web Search Bridge 启动或健康检查失败。\(output.isEmpty ? "" : " 输出：\(output)")"]
      )
    }
    webResearchBridge = bridge
    webResearchBridgeURL = bridgeURL
    webResearchBridgeConfigurationFingerprint = configurationFingerprint
    return bridgeURL
  }

  /// Deliberately excludes credentials. The bridge process must be restarted
  /// when its provider, endpoint, selected research model, or result limit
  /// changes, but a key value must never be copied into UI state or logs.
  private func webResearchBridgeFingerprint(environment: [String: String]) -> String {
    [
      environment["KIMI_AGENT_WEB_SEARCH_PROVIDER"] ?? "",
      environment["KIMI_AGENT_WEB_SEARCH_ENDPOINT"] ?? "",
      environment["KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL"] ?? "",
      environment["KIMI_AGENT_OFFICIAL_TOOLS_MODEL"] ?? "",
      environment["KIMI_AGENT_WEB_SEARCH_DEFAULT_RESULTS"] ?? ""
    ].joined(separator: "\u{1F}")
  }

  private func terminateOrphanedWebResearchBridges(scriptURL: URL) {
    let probe = Process()
    let output = Pipe()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    probe.arguments = ["-f", "\(scriptURL.path) --port 0"]
    probe.standardOutput = output
    probe.standardError = Pipe()
    do {
      try probe.run()
      probe.waitUntilExit()
      guard let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return }
      for line in text.split(whereSeparator: \ .isNewline) {
        guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { continue }
        if kill(pid, SIGTERM) == 0 {
          appendEvent("已清理上次异常退出遗留的 Web Search Bridge。", kind: .toolProgress, for: selectedTaskID ?? UUID())
        }
      }
    } catch {
      // Cleanup is best-effort; inability to inspect processes must not block a task.
    }
  }

  private func parseWebResearchBridgeURL(from output: String) -> String? {
    for line in output.split(whereSeparator: \ .isNewline).reversed() {
      guard let data = String(line).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "ready",
            let url = object["url"] as? String,
            URL(string: url) != nil else { continue }
      return url
    }
    return nil
  }

  private func isWebResearchBridgeHealthy(_ searchURL: String) -> Bool {
    guard let searchURL = URL(string: searchURL) else { return false }
    let healthURL = searchURL.deletingLastPathComponent().appendingPathComponent("health")
    guard let data = try? Data(contentsOf: healthURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return object["ok"] as? Bool == true
  }

  private func invalidateWebResearchBridge() {
    webResearchBridge?.terminate()
    webResearchBridge = nil
    webResearchBridgeURL = nil
    webResearchBridgeConfigurationFingerprint = nil
  }

  private func beginVerification(for task: AgentTask, showNotice: Bool) {
    guard task.status == .reviewReady || task.status == .failed || task.status == .mergeReady else {
      if showNotice { notice = Notice(kind: .error, text: "任务当前状态不能开始验证。") }
      return
    }
    _ = beginTaskWorkspaceAccess(for: task)
    let workingDirectory = URL(fileURLWithPath: task.worktreePath ?? task.workspacePath, isDirectory: true)
    let plan = VerificationPlanner.defaultPlan(for: workingDirectory)
    guard !plan.steps.isEmpty else {
      endTaskWorkspaceAccess(for: task.id)
      if showNotice { notice = Notice(kind: .error, text: "没有检测到可执行的测试或构建脚本。") }
      return
    }

    verificationInProgress.insert(task.id)
    activateAgentRun(taskID: task.id, kind: .test)
    updateTask(task.id) { current in
      current.status = .verifying
      current.updatedAt = .now
    }
    appendEvent("开始自动验证（\(plan.steps.count) 步）…", kind: .verificationStarted, for: task.id)

    Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) { () -> (VerificationResult?, String?) in
        do {
          let result = try VerificationRunner.run(plan, workingDirectory: workingDirectory)
          return (result, nil as String?)
        } catch {
          return (nil, error.localizedDescription)
        }
      }.value
      guard let self else { return }
      defer { self.endTaskWorkspaceAccess(for: task.id) }
      self.verificationInProgress.remove(task.id)
      if let result = outcome.0 {
        self.updateTask(task.id) { current in
          current.verificationResult = result
          current.updatedAt = .now
        }
        if result.passed {
          self.completeAgentRun(taskID: task.id, kind: .test, summary: "测试和构建步骤全部通过")
          if let browserResult = await self.runBrowserVerificationIfConfigured(for: task) {
            self.updateTask(task.id) { current in
              current.browserVerificationResult = browserResult
              current.updatedAt = .now
            }
            if !browserResult.passed {
              let failed = VerificationResult(
                passed: false,
                steps: [
                  VerificationStepResult(
                    stepID: UUID(),
                    kind: .browser,
                    passed: false,
                    exitCode: 1,
                    standardOutput: "",
                    standardError: browserResult.repairSummary,
                    duration: 0
                  )
                ]
              )
              let failurePack = self.recordFailureContext(taskID: task.id, stage: .browser, result: failed)
              let latestTask = self.state.tasks.first(where: { $0.id == task.id })
              if let latestTask,
                 VerificationRepairPlanner.shouldAutoRepair(task: latestTask, result: failed, maxRepairRounds: plan.maxRepairRounds) {
                let round = latestTask.structuredEvents.filter { $0.kind == .verificationFailed }.count + 1
                let prompt = VerificationRepairPlanner.repairPrompt(for: latestTask, result: failed, maxRepairRounds: plan.maxRepairRounds) + "\n\n失败上下文：\n" + failurePack.promptText
                self.appendEvent(
                  "浏览器验证失败，自动修复第 \(round) 轮。",
                  kind: .verificationFailed,
                  for: task.id,
                  payload: ["browser": "failed"]
                )
                self.startTask(latestTask, permission: .automatic, promptOverride: prompt)
                return
              }
              self.failActiveAgentRuns(taskID: task.id, message: "浏览器验证失败")
              self.updateTask(task.id) { current in
                current.status = .failed
                current.updatedAt = .now
              }
              self.appendEvent("浏览器验证失败，请查看截图和 console 错误。", kind: .verificationFailed, for: task.id)
              return
            }
            self.appendEvent("浏览器验证通过。", kind: .verificationPassed, for: task.id, payload: ["browser": "passed"])
          }
          self.completeAgentRun(taskID: task.id, kind: .review, summary: "Diff、测试和浏览器验证已通过")
          self.updateTask(task.id) { current in
            current.status = .mergeReady
            current.updatedAt = .now
          }
          self.appendEvent(
            "自动验证通过。",
            kind: .verificationPassed,
            for: task.id,
            payload: ["passed": "true"]
          )
          return
        }

        let failurePack = self.recordFailureContext(taskID: task.id, stage: .test, result: result)
        let latestTask = self.state.tasks.first(where: { $0.id == task.id })
        if let latestTask,
           VerificationRepairPlanner.shouldAutoRepair(task: latestTask, result: result, maxRepairRounds: plan.maxRepairRounds) {
          let round = latestTask.structuredEvents.filter { $0.kind == .verificationFailed }.count + 1
          let prompt = VerificationRepairPlanner.repairPrompt(for: latestTask, result: result, maxRepairRounds: plan.maxRepairRounds) + "\n\n失败上下文：\n" + failurePack.promptText
          self.appendEvent(
            "自动修复第 \(round) 轮：正在基于验证失败重新执行任务。",
            kind: .toolProgress,
            for: task.id,
            payload: ["round": String(round)]
          )
          self.startTask(latestTask, permission: .automatic, promptOverride: prompt)
          return
        }

        self.updateTask(task.id) { current in
          current.status = .failed
          current.updatedAt = .now
        }
        self.appendEvent(
          "自动验证失败，请查看验证日志。",
          kind: .verificationFailed,
          for: task.id,
          payload: ["passed": "false"]
        )
      } else {
        self.failActiveAgentRuns(taskID: task.id, message: "验证步骤失败")
        let message = outcome.1 ?? "未知错误"
        _ = self.recordFailureContext(taskID: task.id, stage: .test, message: message)
        self.updateTask(task.id) { current in
          current.status = .failed
          current.updatedAt = .now
        }
        self.appendEvent("验证执行失败：\(message)", kind: .verificationFailed, for: task.id)
      }
    }
  }

  @discardableResult
  private func recordFailureContext(
    taskID: AgentTask.ID,
    stage: AgentKind,
    result: VerificationResult? = nil,
    message: String? = nil
  ) -> FailureContextPack {
    let task = state.tasks.first(where: { $0.id == taskID })
    let failedStep = result?.steps.first(where: { !$0.passed })
    let pack = FailureContextPack(
      operationID: UUID(),
      taskID: taskID,
      stage: stage,
      command: failedStep.map { "\($0.kind.rawValue)" },
      exitCode: failedStep?.exitCode ?? 1,
      stderr: failedStep?.standardError.isEmpty == false ? failedStep!.standardError : (message ?? failedStep?.standardOutput ?? "验证失败"),
      relatedFiles: task?.diffSnapshot?.files.map(\.path) ?? [],
      diffArtifactID: task?.diffSnapshot.map { "diff-\($0.id.uuidString)" },
      attempt: (task?.failureContextPacks.count ?? 0) + 1
    )
    updateTask(taskID) { current in
      current.failureContextPacks.append(pack)
      if current.failureContextPacks.count > 5 {
        current.failureContextPacks.removeFirst(current.failureContextPacks.count - 5)
      }
      current.updatedAt = .now
    }
    appendEvent("已保存失败上下文，可从 Debug 阶段继续。", kind: .toolProgress, for: taskID, payload: ["failureContextID": pack.id.uuidString])
    return pack
  }

  func mergeSelectedTask() {
    guard let task = selectedTask else { return }
    guard task.status == .mergeReady, let worktreePath = task.worktreePath, let branch = task.branch else {
      notice = Notice(kind: .error, text: "只有验证通过且存在隔离 Worktree 的任务才能合并。")
      return
    }
    _ = beginTaskWorkspaceAccess(for: task)
    defer { endTaskWorkspaceAccess(for: task.id) }
    let worktree = GitWorktree(
      repositoryPath: task.workspacePath,
      path: URL(fileURLWithPath: worktreePath, isDirectory: true),
      branch: branch,
      baseCommit: task.diffSnapshot?.baseCommit ?? "HEAD"
    )
    do {
      try GitWorktreeManager.merge(worktree, into: URL(fileURLWithPath: task.workspacePath, isDirectory: true), message: "Kimi Agent: \(task.title)")
      updateTask(task.id) { current in
        current.status = .merged
        current.updatedAt = .now
      }
      completeAllAgentRuns(taskID: task.id, summary: "变更已合并到主分支")
      appendEvent("变更已合并到主工作区。", kind: .sessionCompleted, for: task.id)
      notice = Notice(kind: .success, text: "任务变更已合并。")
    } catch {
      updateTask(task.id) { current in
        current.status = .failed
        current.updatedAt = .now
      }
      appendEvent("合并失败：\(error.localizedDescription)", kind: .error, for: task.id)
      runLifecycleHooks(.taskFailed, taskID: task.id)
      notice = Notice(kind: .error, text: "合并失败：\(error.localizedDescription)")
    }
  }

  private func runBrowserVerificationIfConfigured(for task: AgentTask) async -> BrowserVerificationResult? {
    guard var plan = extensionConfiguration?.browserVerification, !plan.steps.isEmpty else {
      return nil
    }
    plan.allowedDomains = Array(Set(plan.allowedDomains + (extensionConfiguration?.allowedDomains ?? []))).sorted()
    appendEvent("开始浏览器验证（\(plan.steps.count) 步）…", kind: .browserOpened, for: task.id)
    let controller = BrowserVerificationController()
    let artifactsDirectory = applicationSupportDirectory
      .appendingPathComponent("browser-artifacts", isDirectory: true)
      .appendingPathComponent(task.id.uuidString, isDirectory: true)
    let result = await controller.run(plan: plan, artifactsDirectory: artifactsDirectory)
    for trace in result.timeline {
      appendEvent("浏览器：\(trace.message)", kind: eventKind(for: trace.stepKind), for: task.id)
    }
    if !result.passed {
      appendEvent(result.repairSummary, kind: .browserConsoleError, for: task.id)
    }
    return result
  }

  private func eventKind(for stepKind: BrowserVerificationStepKind) -> AgentEventKind {
    switch stepKind {
    case .open, .navigate:
      .browserOpened
    case .click:
      .browserClicked
    case .typeText, .pressKey:
      .browserTyped
    case .screenshot:
      .browserScreenshot
    case .collectConsole:
      .browserConsoleError
    case .inspect, .scroll, .collectNetwork:
      .toolProgress
    }
  }

  func acceptDiffFile(_ path: String) {
    guard let task = selectedTask else { return }
    updateTask(task.id) { current in
      current.reviewState.acceptFile(path)
      current.updatedAt = .now
    }
    appendEvent("已接受文件变更：\(path)", kind: .hunkAccepted, for: task.id, payload: ["path": path])
  }

  func acceptDiffHunk(_ id: String) {
    guard let task = selectedTask else { return }
    updateTask(task.id) { current in
      current.reviewState.acceptHunk(id)
      current.updatedAt = .now
    }
    appendEvent("已接受 Hunk：\(id)", kind: .hunkAccepted, for: task.id, payload: ["hunk": id])
  }

  func rejectDiffHunk(_ id: String) {
    guard let task = selectedTask else { return }
    updateTask(task.id) { current in
      current.reviewState.rejectHunk(id)
      current.updatedAt = .now
    }
    appendEvent("已拒绝 Hunk：\(id)", kind: .hunkRejected, for: task.id, payload: ["hunk": id])
  }

  func rejectDiffFile(_ path: String) {
    guard let task = selectedTask,
          let worktreePath = task.worktreePath,
          let baseCommit = task.diffSnapshot?.baseCommit else {
      notice = Notice(kind: .error, text: "当前任务没有可恢复的 Worktree 变更。")
      return
    }
    _ = beginTaskWorkspaceAccess(for: task)
    defer { endTaskWorkspaceAccess(for: task.id) }
    let worktree = GitWorktree(
      repositoryPath: task.workspacePath,
      path: URL(fileURLWithPath: worktreePath, isDirectory: true),
      branch: task.branch ?? "",
      baseCommit: baseCommit
    )
    do {
      try GitWorktreeManager.restoreFile(path, in: worktree, baseCommit: baseCommit)
      let updatedDiff = try DiffEngine.snapshot(baseDirectory: worktree.path, taskID: task.id, baseCommit: baseCommit)
      updateTask(task.id) { current in
        current.reviewState.rejectFile(path)
        current.diffSnapshot = updatedDiff
        current.updatedAt = .now
      }
      appendEvent("已拒绝并恢复文件：\(path)", kind: .hunkRejected, for: task.id, payload: ["path": path])
    } catch {
      notice = Notice(kind: .error, text: "无法恢复文件：\(error.localizedDescription)")
      appendEvent("恢复文件失败：\(error.localizedDescription)", kind: .error, for: task.id)
    }
  }

  func addDiffComment(filePath: String, line: Int, text: String) {
    guard let task = selectedTask else { return }
    let comment = DiffComment(filePath: filePath, line: line, text: text)
    updateTask(task.id) { current in
      current.reviewState.addComment(comment)
      current.updatedAt = .now
    }
    appendEvent("已添加审阅评论：\(filePath):\(line)", kind: .diffCommented, for: task.id, payload: ["path": filePath, "line": String(line), "comment": text])
  }

  func events(for task: AgentTask) -> [String] {
    eventLog[task.id] ?? task.events
  }

  func structuredEvents(for task: AgentTask) -> [AgentEvent] {
    task.structuredEvents
  }

  private func updateTask(_ id: AgentTask.ID, update: (inout AgentTask) -> Void) {
    guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
    update(&state.tasks[index])
    schedulePersistence()
  }

  private func activateFirstReadyAgentRun(taskID: AgentTask.ID, worktreePath: String) {
    updateTask(taskID) { task in
      let completedIDs = Set(task.agentRuns.filter { $0.state == .completed }.map(\.id))
      guard let index = task.agentRuns.firstIndex(where: {
        $0.state == .queued && Set($0.dependencies).isSubset(of: completedIDs)
      }) else { return }
      task.agentRuns[index].state = .running
      task.agentRuns[index].progress = 0.05
      task.agentRuns[index].worktreePath = worktreePath
      task.agentRuns[index].updatedAt = .now
      task.agentRuns = task.agentRuns.map { run in
        var run = run
        if run.worktreePath == nil && run.definition.isolation == .worktree {
          run.worktreePath = worktreePath
        }
        return run
      }
    }
  }

  private func activateAgentRun(taskID: AgentTask.ID, kind: AgentKind) {
    updateTask(taskID) { task in
      guard let index = task.agentRuns.firstIndex(where: { $0.definition.kind == kind && !$0.state.isTerminal }) else { return }
      task.agentRuns[index].state = .running
      task.agentRuns[index].progress = max(task.agentRuns[index].progress, 0.1)
      task.agentRuns[index].updatedAt = .now
    }
  }

  private func completeAgentRun(taskID: AgentTask.ID, kind: AgentKind, summary: String) {
    updateTask(taskID) { task in
      guard let index = task.agentRuns.firstIndex(where: { $0.definition.kind == kind }) else { return }
      task.agentRuns[index].state = .completed
      task.agentRuns[index].progress = 1
      task.agentRuns[index].result = AgentResult(summary: summary)
      task.agentRuns[index].updatedAt = .now
    }
  }

  private func completeAgentRunsAfterExecution(taskID: AgentTask.ID) {
    updateTask(taskID) { task in
      for index in task.agentRuns.indices {
        switch task.agentRuns[index].definition.kind {
        case .explore, .plan, .implement:
          task.agentRuns[index].state = .completed
          task.agentRuns[index].progress = 1
          task.agentRuns[index].result = AgentResult(summary: "Runtime 已完成该阶段")
        case .review:
          task.agentRuns[index].state = task.mode.isReadOnly ? .completed : .awaitingApproval
          task.agentRuns[index].progress = task.mode.isReadOnly ? 1 : 0.75
        case .test, .browser, .browserVerification, .computerUse, .webResearch, .debug:
          break
        }
        task.agentRuns[index].updatedAt = .now
      }
    }
  }

  private func failActiveAgentRuns(taskID: AgentTask.ID, message: String) {
    updateTask(taskID) { task in
      for index in task.agentRuns.indices where !task.agentRuns[index].state.isTerminal {
        task.agentRuns[index].state = .failed
        task.agentRuns[index].errorMessage = message
        task.agentRuns[index].updatedAt = .now
      }
    }
  }

  private func completeAllAgentRuns(taskID: AgentTask.ID, summary: String) {
    updateTask(taskID) { task in
      for index in task.agentRuns.indices {
        task.agentRuns[index].state = .completed
        task.agentRuns[index].progress = 1
        task.agentRuns[index].result = AgentResult(summary: summary)
        task.agentRuns[index].updatedAt = .now
      }
    }
  }

  private func syncTerminalWorkspace() {
    state.terminalWorkspace = terminalWorkspace
    schedulePersistence()
  }

  private func seedSessionJournal(for task: AgentTask) {
    guard let sessionID = UUID(uuidString: task.sessionID ?? "") else { return }
    let session = SessionRecord(
      id: sessionID,
      taskID: task.id,
      parentID: nil,
      agentID: task.mode == .plan ? "plan" : "build",
      modelID: task.modelID,
      status: .idle,
      worktreePath: task.worktreePath
    )
    enqueueSessionKernelEvent(
      RuntimeEvent(
        sessionID: sessionID,
        taskID: task.id,
        sequence: 1,
        kind: .sessionCreated,
        payload: try? JSONEncoder().encode(session)
      )
    )
    enqueueSessionKernelEvent(
      RuntimeEvent(
        sessionID: sessionID,
        taskID: task.id,
        sequence: 2,
        kind: .messagePartAppended,
        payload: try? JSONEncoder().encode(MessagePart.text(sessionID: sessionID, role: .user, text: task.title))
      )
    )
  }

  private func enqueueSessionKernelEvent(_ event: RuntimeEvent) {
    let previous = sessionEventWriteTails[event.sessionID]
    let store = sessionEventStore
    let write = Task { [previous] in
      await previous?.value
      _ = try? await store.appendNext(event)
    }
    sessionEventWriteTails[event.sessionID] = write
  }

  /// Reconciles the compatibility snapshot with the append-only session journal
  /// after launch. Running work is intentionally marked interrupted because no
  /// child process survives an application restart; the message history remains
  /// available for a user-directed resume.
  private func restoreSessionSnapshots() {
    let store = sessionEventStore
    Task { [weak self, store] in
      let snapshots = await store.snapshots()
      self?.applySessionSnapshots(snapshots)
    }
  }

  /// Rehydrates the Core-owned Supervisor from persisted AgentRun snapshots.
  /// Nothing is replayed on launch: running/approval nodes become
  /// `interrupted`, and execution only resumes after the user explicitly asks
  /// to continue the task.
  private func restoreAgentGraphSupervisors() {
    for task in state.tasks where !task.agentRuns.isEmpty && task.agentRuns.contains(where: { !$0.state.isTerminal }) {
      let taskID = task.id
      let sessionID = UUID(uuidString: task.sessionID ?? "") ?? task.id
      let taskPrompt = task.turns.first(where: { $0.id == task.activeTurnID })?.userMessage ?? task.title
      let decision = TaskIntentRouter.decide(for: taskPrompt)
      // Historical migration may have synthesized a default AgentRun graph
      // for records that predate intent routing. Do not resurrect that graph
      // for ordinary conversation or direct Web/Browser requests.
      guard AgentGraphRecoveryPolicy.shouldRestoreGraph(decision: decision, runs: task.agentRuns) else { continue }
      let contract = TaskContract.make(prompt: taskPrompt, decision: decision, mode: task.mode)
      let parentSession = SessionRecord(
        id: sessionID,
        taskID: taskID,
        agentID: "supervisor",
        modelID: task.modelID,
        status: .interrupted,
        worktreePath: task.worktreePath
      )
      let restoredRuns = task.agentRuns.map { original -> AgentRun in
        var run = original
        if run.worktreePath == nil, run.definition.isolation == .worktree {
          run.worktreePath = task.worktreePath ?? task.workspacePath
        }
        return run
      }
      let supervisor = AgentGraphSupervisor(
        parent: parentSession,
        snapshot: AgentRunSchedulerSnapshot(
          runs: restoredRuns,
          maxConcurrent: extensionConfiguration?.maxConcurrentWorkers ?? 8
        ),
        prompt: { run in
          "父任务：\(task.title)\n请继续执行你的阶段：\(run.definition.description)"
        },
        onEvent: { [weak self] event in
          Task { @MainActor [weak self] in
            self?.consumeAgentGraphEvent(event, taskID: taskID)
          }
        },
        onSessionEvent: { [weak self] event in
          Task { @MainActor [weak self] in
            self?.enqueueSessionKernelEvent(event)
          }
        },
        onChildCancellation: { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.cancelNativeToolApproval(for: taskID)
          }
        },
        executor: { [weak self] run, session, childPrompt, tools in
          try await Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            guard self.usesNativeHarnessProvider() else {
              throw NSError(
                domain: "HarnessChild",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Child Agent 缺少 Kimi API 连接；ACP/CLI 子执行已禁用，避免绕过统一 Tool Runtime。"]
              )
            }
            return try await self.executeNativeChildAgent(
              parentTaskID: taskID,
              session: session,
              prompt: childPrompt,
              tools: tools,
              agentDefinition: run.definition
            )
          }.value
        }
      )
      agentGraphSupervisors[taskID] = supervisor
      graphContracts[taskID] = contract
      Task { @MainActor [weak self, supervisor] in
        let snapshot = await supervisor.snapshot()
        self?.updateTask(taskID) { current in
          current.agentRuns = snapshot.runs
          if current.status == .running || current.status == .planning {
            current.status = .waitingForUser
          }
          current.updatedAt = .now
        }
      }
    }
  }

  private func importLegacyHarnessState(_ legacyState: AppState) {
    let store = harnessEventStore
    Task {
      guard let sessions = try? await HarnessLegacyMigrator.import(state: legacyState) else { return }
      for session in sessions {
        let existing = await store.events(sessionID: session.id)
        guard existing.isEmpty else { continue }
        for entry in session.entries {
          _ = try? await store.append(HarnessEvent(
            sessionID: session.id,
            lane: .main,
            sequence: 0,
            kind: .entryAppended,
            payload: try? JSONEncoder().encode(entry)
          ))
        }
      }
    }
  }

  private func applySessionSnapshots(_ snapshots: [UUID: SessionSnapshot]) {
    var changed = false
    for (sessionID, snapshot) in snapshots {
      guard let taskIndex = state.tasks.firstIndex(where: { $0.sessionID == sessionID.uuidString }) else { continue }
      guard let session = snapshot.session else { continue }

      if let assistantText = snapshot.parts.reversed().first(where: {
        $0.role == .assistant && $0.kind == .text && !($0.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      })?.text,
      let turnIndex = state.tasks[taskIndex].turns.indices.last {
        state.tasks[taskIndex].turns[turnIndex].assistantMessage = assistantText
        state.tasks[taskIndex].turns[turnIndex].updatedAt = .now
        changed = true
      }

      if session.status == .running || session.status == .awaitingApproval {
        state.tasks[taskIndex].status = .waitingForUser
        state.tasks[taskIndex].events.append("应用重启后已恢复会话；上一次运行已中断，可继续执行。")
        state.tasks[taskIndex].updatedAt = .now
        changed = true
      }
    }
    if changed {
      eventLog = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0.events) })
      schedulePersistence()
    }
  }

  private func enqueueSessionKernelEvent(_ event: AgentEvent) {
    let kind: RuntimeEventKind
    switch event.kind {
    case .sessionCreated:
      kind = .sessionCreated
    case .sessionResumed:
      kind = .sessionResumed
    case .sessionPaused:
      kind = .sessionPaused
    case .sessionCompleted:
      kind = .sessionCompleted
    case .taskFailed, .verificationFailed, .error:
      kind = .sessionFailed
    case .permissionRequested:
      kind = .permissionRequested
    case .permissionApproved, .permissionDenied:
      kind = .permissionResolved
    case .output:
      kind = .messagePartAppended
    default:
      kind = .artifactCreated
    }

    let payload: Data?
    if event.kind == .output, let text = event.payload["text"] {
      let role: MessagePartRole = event.payload["role"] == "user" ? .user : .assistant
      payload = try? JSONEncoder().encode(MessagePart.text(sessionID: event.sessionID, role: role, text: text))
    } else {
      payload = try? JSONSerialization.data(withJSONObject: event.payload, options: [.sortedKeys])
    }

    enqueueSessionKernelEvent(
      RuntimeEvent(
        id: event.id,
        sessionID: event.sessionID,
        taskID: event.taskID,
        sequence: event.sequence,
        kind: kind,
        payload: payload,
        timestamp: event.timestamp
      )
    )
  }

  private func appendEvent(_ text: String, for taskID: AgentTask.ID) {
    appendEvent(text, kind: .output, for: taskID)
  }

  private func appendEvent(
    _ text: String,
    kind: AgentEventKind,
    for taskID: AgentTask.ID,
    payload: [String: String] = [:],
    requiresApproval: Bool = false,
    turnID: UUID? = nil
  ) {
    appendEvents([text], for: taskID)
    guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
    let sessionID = UUID(uuidString: state.tasks[index].sessionID ?? "") ?? UUID()
    let resolvedTurnID = turnID ?? activeTurnIDs[taskID] ?? state.tasks[index].activeTurnID
    let structuredPayload = payload.merging(["text": text], uniquingKeysWith: { existing, _ in existing })
    let event = AgentEvent(
      sessionID: sessionID,
      taskID: taskID,
      turnID: resolvedTurnID,
      sequence: Int64(state.tasks[index].structuredEvents.count + 1),
      actor: "desktop",
      kind: kind,
      payload: structuredPayload,
      requiresApproval: requiresApproval
    )
    state.tasks[index].structuredEvents.append(event)
    if state.tasks[index].structuredEvents.count > maximumPersistedEvents {
      state.tasks[index].structuredEvents.removeFirst(state.tasks[index].structuredEvents.count - maximumPersistedEvents)
    }
    enqueueSessionKernelEvent(event)
    schedulePersistence()
  }

  private func appendEvents(_ events: [String], for taskID: AgentTask.ID) {
    guard !events.isEmpty else { return }
    eventLog[taskID, default: []].append(contentsOf: events)
    if eventLog[taskID, default: []].count > maximumPersistedEvents {
      eventLog[taskID]?.removeFirst(eventLog[taskID, default: []].count - maximumPersistedEvents)
    }
    guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
    state.tasks[index].events.append(contentsOf: events)
    if state.tasks[index].events.count > maximumPersistedEvents {
      state.tasks[index].events.removeFirst(state.tasks[index].events.count - maximumPersistedEvents)
    }
    state.tasks[index].updatedAt = .now
    schedulePersistence()
  }

  private func enqueue(_ output: KimiProcessOutput, for taskID: AgentTask.ID) {
    var buffers = streamBuffers[taskID] ?? TaskStreamBuffers()
    var parser = streamParsers[taskID] ?? KimiStreamEventParser(
      sessionID: UUID(uuidString: state.tasks.first(where: { $0.id == taskID })?.sessionID ?? "") ?? UUID(),
      taskID: taskID,
      turnID: activeTurnIDs[taskID] ?? state.tasks.first(where: { $0.id == taskID })?.activeTurnID,
      sequence: Int64(state.tasks.first(where: { $0.id == taskID })?.structuredEvents.count ?? 0)
    )
    let lines: [String]
    var structuredEvents: [AgentEvent] = []
    switch output.stream {
    case .standardOutput:
      lines = buffers.stdout.append(output.text)
      for line in lines {
        let parsed = parser.parse(line: line)
        if parsed.isEmpty {
          structuredEvents.append(parser.event(kind: .output, payload: ["text": line]))
        } else {
          structuredEvents.append(contentsOf: parsed)
        }
      }
    case .standardError:
      lines = buffers.stderr.append(output.text).map { "错误：\($0)" }
      for line in lines {
        structuredEvents.append(parser.event(kind: .error, payload: ["text": line]))
      }
    }
    streamBuffers[taskID] = buffers
    streamParsers[taskID] = parser
    pendingStructuredEvents[taskID, default: []].append(contentsOf: structuredEvents)
    pendingOutputEvents[taskID, default: []].append(contentsOf: structuredEvents.map(eventPresentation).isEmpty ? lines : structuredEvents.map(eventPresentation))
    for event in structuredEvents {
      triggerLifecycleHooks(for: event, taskID: taskID)
    }
    scheduleOutputFlush()
  }

  private func scheduleOutputFlush() {
    guard outputFlushTask == nil else { return }
    outputFlushTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 80_000_000)
      guard !Task.isCancelled else { return }
      self?.flushPendingOutputEvents()
    }
  }

  private func flushPendingOutputEvents() {
    outputFlushTask?.cancel()
    outputFlushTask = nil
    let pending = pendingOutputEvents
    let structured = pendingStructuredEvents
    pendingOutputEvents.removeAll()
    pendingStructuredEvents.removeAll()
    for (taskID, events) in pending {
      appendEvents(events, for: taskID)
    }
    for (taskID, events) in structured {
      appendStructuredEvents(events, for: taskID)
    }
  }

  private func flushStreamingBuffers(for taskID: AgentTask.ID) {
    guard var buffers = streamBuffers[taskID] else { return }
    let stdout = buffers.stdout.flush()
    let stderr = buffers.stderr.flush().map { "错误：\($0)" }
    streamBuffers[taskID] = buffers
    var parser = streamParsers[taskID] ?? KimiStreamEventParser(
      sessionID: UUID(uuidString: state.tasks.first(where: { $0.id == taskID })?.sessionID ?? "") ?? UUID(),
      taskID: taskID,
      turnID: activeTurnIDs[taskID] ?? state.tasks.first(where: { $0.id == taskID })?.activeTurnID,
      sequence: Int64(state.tasks.first(where: { $0.id == taskID })?.structuredEvents.count ?? 0)
    )
    let stdoutEvents = stdout.flatMap { line -> [AgentEvent] in
      let parsed = parser.parse(line: line)
      return parsed.isEmpty ? [parser.event(kind: .output, payload: ["text": line])] : parsed
    }
    let stderrEvents = stderr.map { line in parser.event(kind: .error, payload: ["text": line]) }
    streamParsers[taskID] = parser
    let events = stdoutEvents + stderrEvents
    pendingStructuredEvents[taskID, default: []].append(contentsOf: events)
    pendingOutputEvents[taskID, default: []].append(contentsOf: events.map(eventPresentation))
    flushPendingOutputEvents()
    streamBuffers.removeValue(forKey: taskID)
    streamParsers.removeValue(forKey: taskID)
  }

  private func appendStructuredEvents(_ events: [AgentEvent], for taskID: AgentTask.ID) {
    guard !events.isEmpty, let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
    let turnID = activeTurnIDs[taskID] ?? state.tasks[index].activeTurnID
    let assignedEvents = events.map { $0.turnID == nil ? $0.assigningTurn(turnID) : $0 }
    let existingIDs = Set(state.tasks[index].structuredEvents.map(\ .id))
    let newEvents = assignedEvents.filter { !existingIDs.contains($0.id) }
    state.tasks[index].structuredEvents.append(contentsOf: newEvents)
    for event in newEvents {
      recordAgentTerminalTool(event, taskID: taskID)
    }
    if let turnID,
       let turnIndex = state.tasks[index].turns.firstIndex(where: { $0.id == turnID }) {
      let transcript = state.tasks[index].structuredEvents
        .filter { event in
          event.turnID == turnID &&
            event.kind == .output &&
            event.actor != "desktop" &&
            event.payload["role"] != "user" &&
            event.payload["contentType"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "thinking"
        }
        .compactMap { $0.payload["text"] }
        .joined()
      if let assistantText = AssistantReplySanitizer.finalConversationText(from: transcript),
         !assistantText.isEmpty,
         !assistantText.contains("正在思考") {
        state.tasks[index].turns[turnIndex].assistantMessage = assistantText
        state.tasks[index].turns[turnIndex].updatedAt = .now
      }
    }
    if state.tasks[index].structuredEvents.count > maximumPersistedEvents {
      state.tasks[index].structuredEvents.removeFirst(state.tasks[index].structuredEvents.count - maximumPersistedEvents)
    }
    state.tasks[index].updatedAt = .now
    schedulePersistence()
  }

  private func recordAgentTerminalTool(_ event: AgentEvent, taskID: AgentTask.ID) {
    guard let task = state.tasks.first(where: { $0.id == taskID }) else { return }
    let cwd = task.worktreePath ?? task.workspacePath
    updateTerminalSession(for: taskID, cwd: cwd) { session in
      _ = session.recordAgentToolEvent(event, cwd: cwd)
    }
  }

  private func triggerLifecycleHooks(for event: AgentEvent, taskID: AgentTask.ID) {
    switch event.kind {
    case .sessionCreated:
      runLifecycleHooks(.sessionStart, taskID: taskID)
      runLifecycleHooks(.taskCreated, taskID: taskID)
    case .sessionCompleted, .sessionCancelled:
      runLifecycleHooks(.sessionEnd, taskID: taskID)
    case .toolRequested, .commandRequested:
      runLifecycleHooks(.beforeTool, taskID: taskID)
      if event.payload["name"]?.lowercased().hasPrefix("mcp.") == true || event.payload["id"]?.lowercased().hasPrefix("mcp.") == true {
        runLifecycleHooks(.mcpToolCall, taskID: taskID)
      }
    case .permissionRequested:
      runLifecycleHooks(.permissionRequest, taskID: taskID)
    case .permissionDenied:
      runLifecycleHooks(.permissionDenied, taskID: taskID)
    case .toolFinished, .commandFinished:
      runLifecycleHooks(.afterTool, taskID: taskID)
    case .error, .verificationFailed, .taskFailed:
      runLifecycleHooks(.postToolUseFailure, taskID: taskID)
    default:
      break
    }
  }

  private func eventPresentation(_ event: AgentEvent) -> String {
    switch event.kind {
    case .output:
      event.payload["text"] ?? event.payload["version"] ?? "Kimi 输出"
    case .toolRequested:
      "请求工具：\(event.payload["name"] ?? "unknown")"
    case .toolFinished:
      "工具完成：\(event.payload["id"] ?? "")"
    case .error:
      "错误：\(event.payload["text"] ?? event.payload["message"] ?? "未知错误")"
    case .sessionResumed:
      "已恢复 Kimi 会话"
    default:
      event.kind.rawValue
    }
  }

  private func schedulePersistence() {
    persistenceRevision += 1
    let revision = persistenceRevision
    let snapshot = state
    let writer = persistenceWriter
    persistenceTask?.cancel()
    persistenceTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 350_000_000)
      guard !Task.isCancelled, self?.persistenceRevision == revision else { return }
      do {
        try await writer.save(snapshot)
      } catch {
        self?.notice = Notice(kind: .error, text: "无法保存本地状态：\(error.localizedDescription)")
      }
    }
  }

  func flushPendingState() {
    persistenceTask?.cancel()
    let snapshot = state
    let writer = persistenceWriter
    Task { [weak self] in
      do {
        try await writer.save(snapshot)
      } catch {
        self?.notice = Notice(kind: .error, text: "无法保存本地状态：\(error.localizedDescription)")
      }
    }
  }

  private func observeProcessOutput(_ output: KimiProcessOutput, for taskID: AgentTask.ID) {
    Task { @MainActor [weak self] in
      self?.enqueue(output, for: taskID)
    }
  }

  private func observeHostEnvelope(_ envelope: AgentHostEnvelope, for taskID: AgentTask.ID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let event = envelope.event {
        let assignedEvent = event.turnID == nil
          ? event.assigningTurn(self.activeTurnIDs[taskID] ?? self.state.tasks.first(where: { $0.id == taskID })?.activeTurnID)
          : event
        self.recordWebResearchEvidence(from: assignedEvent, for: taskID)
        self.pendingStructuredEvents[taskID, default: []].append(assignedEvent)
        self.pendingOutputEvents[taskID, default: []].append(self.eventPresentation(assignedEvent))
        self.recordAgentTerminalTool(assignedEvent, taskID: taskID)
        self.scheduleOutputFlush()
        self.triggerLifecycleHooks(for: assignedEvent, taskID: taskID)
        if assignedEvent.kind == .permissionRequested {
          self.handlePermissionRequest(assignedEvent, taskID: taskID)
        }
      } else if envelope.type == "ready", let runtimeSessionID = envelope.runtimeSessionID, !runtimeSessionID.isEmpty {
        self.updateTask(taskID) { task in
          task.runtimeSessionID = runtimeSessionID
          task.updatedAt = .now
        }
        self.appendEvent("已连接 Kimi ACP 会话，可在重启后恢复。", kind: .sessionResumed, for: taskID, payload: ["runtimeSessionID": runtimeSessionID])
      } else if envelope.type == "error" {
        self.appendEvent(envelope.message ?? "Native Agent Host 发生未知错误。", kind: .error, for: taskID)
      }
    }
  }

  /// Routes every session through the durable Harness. Legacy records are
  /// imported as history but use the same execution authority when resumed.
  private func startTask(_ task: AgentTask, permission: KimiPermissionMode, promptOverride: String? = nil) {
    let rawPrompt = (promptOverride ?? task.title).trimmingCharacters(in: .whitespacesAndNewlines)
    let taskSkills = extensionSkills.isEmpty
      ? SkillRegistry.discover(projectDirectory: URL(fileURLWithPath: task.workspacePath, isDirectory: true))
      : extensionSkills
    if let invocation = SkillInvocationParser.parse(rawPrompt, skills: taskSkills) {
      appendEvent("已调用 Skill：/\(invocation.skill.name)", kind: .toolProgress, for: task.id, payload: ["skill": invocation.skill.name])
      startHarnessTask(task, permission: permission, promptOverride: invocation.prompt)
      return
    }
    let intent = TaskIntentRouter.decide(for: rawPrompt)
    // A declarative Skill may enrich an ordinary low-latency conversation,
    // but planning graphs keep their own isolated prompts and therefore do
    // not silently preload a Skill into only one of several Child Sessions.
    if !intent.requiresPlanning,
       let invocation = SkillInvocationParser.automaticInvocation(prompt: rawPrompt, skills: taskSkills) {
      appendEvent("已自动匹配 Skill：/\(invocation.skill.name)", kind: .toolProgress, for: task.id, payload: ["skill": invocation.skill.name, "automatic": "true"])
      startHarnessTask(task, permission: permission, promptOverride: invocation.prompt)
      return
    }
    let resolvedPrompt = rawPrompt
    if intent.requiresPlanning {
      startAutomatedAgentGraph(task, prompt: resolvedPrompt)
      return
    }
    startHarnessTask(task, permission: permission, promptOverride: promptOverride)
  }

  /// Runs the compiled TaskGraph through real Child Sessions. This is the
  /// supervisor path for planning/implementation tasks; ordinary conversation
  /// remains on the low-latency single-session path above.
  private func startAutomatedAgentGraph(_ task: AgentTask, prompt: String) {
    automatedGraphTasks[task.id]?.cancel()
    let sessionID = UUID(uuidString: task.sessionID ?? "") ?? task.id
    let decision = TaskIntentRouter.decide(for: prompt)
    let contract = TaskContract.make(prompt: prompt, decision: decision, mode: task.mode)
    let graph = TaskGraphCompiler.compile(taskID: task.id, sessionID: sessionID, contract: contract, model: task.modelID)
    let graphPlan = TaskGraphCompiler.plan(from: graph)
    let initialWorktreePath = task.worktreePath ?? task.workspacePath
    let scheduledRuns = graphPlan.runs.map { run in
      var run = run
      if run.definition.isolation == .worktree {
        run.worktreePath = initialWorktreePath
      }
      return run
    }
    let parentSession = SessionRecord(
      id: sessionID,
      taskID: task.id,
      agentID: "supervisor",
      modelID: task.modelID,
      status: .running,
      worktreePath: task.worktreePath
    )
    let taskID = task.id
    let taskTitle = task.title
    let supervisor = AgentGraphSupervisor(
      parent: parentSession,
      runs: scheduledRuns,
      maxConcurrent: self.extensionConfiguration?.maxConcurrentWorkers ?? 8,
      prompt: { run in
        "父任务：\(taskTitle)\n请执行你的阶段：\(run.definition.description)"
      },
      onEvent: { [weak self] event in
        Task { @MainActor [weak self] in
          self?.consumeAgentGraphEvent(event, taskID: taskID)
        }
      },
      onSessionEvent: { [weak self] event in
        Task { @MainActor [weak self] in
          self?.enqueueSessionKernelEvent(event)
        }
      },
      onChildCancellation: { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.cancelNativeToolApproval(for: taskID)
        }
      },
      executor: { [weak self] run, session, childPrompt, tools in
        try await Task { @MainActor [weak self] in
          guard let self else { throw CancellationError() }
          guard self.usesNativeHarnessProvider() else {
            throw NSError(
              domain: "HarnessChild",
              code: 401,
              userInfo: [NSLocalizedDescriptionKey: "Child Agent 缺少 Kimi API 连接；ACP/CLI 子执行已禁用，避免绕过统一 Tool Runtime。"]
            )
          }
          return try await self.executeNativeChildAgent(
            parentTaskID: taskID,
            session: session,
            prompt: childPrompt,
            tools: tools,
            agentDefinition: run.definition
          )
        }.value
      }
    )
    agentGraphSupervisors[task.id] = supervisor
    graphContracts[task.id] = contract
    updateTask(task.id) { current in
      current.agentRuns = scheduledRuns.map { run in
        var run = run
        if run.state == .paused || run.state == .interrupted { run.state = .queued }
        return run
      }
      current.status = .running
      current.updatedAt = .now
      if let turnID = current.activeTurnID, let index = current.turns.firstIndex(where: { $0.id == turnID }) {
        current.turns[index].status = .running
        current.turns[index].errorMessage = nil
        current.turns[index].updatedAt = .now
      }
    }
    appendEvent("已建立 (graph.nodes.count) 个可恢复阶段。", kind: .taskPlanned, for: task.id, payload: [
      "graphID": graph.id.uuidString,
      "stages": graph.nodes.map(\.stage.title).joined(separator: " → ")
    ])
    startAgentGraphDriver(taskID: taskID)
  }

  /// Projects Core-owned graph snapshots into the persisted task record. The
  /// event never decides scheduling; it only updates the SwiftUI projection.
  private func consumeAgentGraphEvent(_ event: AgentGraphSupervisorEvent, taskID: AgentTask.ID) {
    switch event {
    case let .schedulerSnapshot(snapshot):
      updateTask(taskID) { current in
        current.agentRuns = snapshot.runs
        current.updatedAt = .now
      }
      schedulePersistence()
    case let .childSessionCreated(runID, session):
      guard let run = state.tasks.first(where: { $0.id == taskID })?.agentRuns.first(where: { $0.id == runID }) else { return }
      appendEvent(
        "Child Agent \(run.definition.kind.title) 已启动。",
        kind: .toolStarted,
        for: taskID,
        payload: ["runID": runID.uuidString, "childSessionID": session.id.uuidString]
      )
    case .graphFinished:
      break
    }
  }

  /// Starts one Core-owned drive pass. There is no UI timer or manual
  /// scheduleReady polling: the Supervisor releases dependent nodes itself.
  private func startAgentGraphDriver(taskID: AgentTask.ID) {
    guard automatedGraphTasks[taskID] == nil,
          let supervisor = agentGraphSupervisors[taskID],
          let contract = graphContracts[taskID] else { return }
    automatedGraphTasks[taskID] = Task { @MainActor [weak self] in
      defer { self?.automatedGraphTasks.removeValue(forKey: taskID) }
      do {
        let runs = try await supervisor.run()
        guard let self else { return }
        self.updateTask(taskID) { current in
          current.agentRuns = runs
          current.updatedAt = .now
        }
        self.finishAutomatedAgentGraph(taskID: taskID, contract: contract)
      } catch is CancellationError {
        // User cancellation is already reflected by the Supervisor snapshot.
      } catch {
        guard let self else { return }
        self.updateTask(taskID) { $0.status = .failed; $0.updatedAt = .now }
        self.appendEvent("Agent Graph 失败：\(error.localizedDescription)", kind: .error, for: taskID)
      }
    }
  }

  private func finishAutomatedAgentGraph(taskID: AgentTask.ID, contract: TaskContract) {
    guard let task = state.tasks.first(where: { $0.id == taskID }) else { return }
    let aggregation = AgentResultMerger.merge(runs: task.agentRuns, contract: contract, requestedLanguage: .chinese)
    let turnID = task.activeTurnID ?? task.turns.last?.id
    updateTask(taskID) { current in
      if let turnID, let index = current.turns.firstIndex(where: { $0.id == turnID }) {
        current.turns[index].assistantMessage = aggregation.finalAnswer
        switch aggregation.outcome {
        case .completed:
          current.turns[index].status = .completed
          current.turns[index].errorMessage = nil
        case .partial:
          current.turns[index].status = .paused
          current.turns[index].errorMessage = aggregation.unresolved.joined(separator: "；")
        case .failed:
          current.turns[index].status = .failed
          current.turns[index].errorMessage = aggregation.unresolved.joined(separator: "；")
        }
        current.turns[index].updatedAt = .now
      }
      switch aggregation.outcome {
      case .completed:
        current.status = current.mode.isReadOnly ? .completed : .reviewReady
      case .partial:
        current.status = .waitingForUser
      case .failed:
        current.status = .failed
      }
      current.updatedAt = .now
    }
    appendEvent(aggregation.finalAnswer, kind: .output, for: taskID, payload: [
      "role": "assistant",
      "source": "final-answer-composer",
      "outcome": aggregation.outcome.rawValue
    ], turnID: turnID)
    if aggregation.outcome == .completed {
      appendEvent("所有阶段已完成，等待人工审阅。", kind: .toolFinished, for: taskID)
    } else {
      appendEvent("阶段执行未完成，可从失败节点继续。", kind: .error, for: taskID)
    }
    schedulePersistence()
  }

  private func startHarnessTask(_ task: AgentTask, permission: KimiPermissionMode, promptOverride: String?) {
    let sessionID = UUID(uuidString: task.sessionID ?? "") ?? task.id
    let harness: AgentHarness
    if let existing = harnesses[task.id] {
      harness = existing
    } else {
      let taskID = task.id
      harness = AgentHarness(sessionID: sessionID, store: harnessEventStore) { [weak self] context, emit in
        guard let self else { throw CancellationError() }
        if await self.usesNativeHarnessProvider() {
          do {
            try await self.runNativeHarnessOperation(taskID: taskID, context: context, emit: emit)
          } catch let error as KimiHTTPProviderError {
            // Do not silently switch execution authority after a native
            // Provider failure. A compatibility runtime can have its own
            // tool side effects and would break Intent/Receipt guarantees.
            await emit(.artifact("nativeProvider=failed; fallback=disabled"))
            throw error
          }
        } else {
          await emit(.artifact("nativeProvider=unavailable; compatibilityExecution=disabled"))
          throw NSError(
            domain: "Harness",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Harness 执行需要已配置的 Kimi API Key；ACP/CLI 兼容执行已禁用，避免绕过统一 Tool Runtime。"]
          )
        }
      }
      harnesses[task.id] = harness
      attachHarnessEvents(for: task.id, harness: harness)
    }

    let prompt: String
    if let override = promptOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
      prompt = override
    } else {
      prompt = task.title
    }
    Task { [weak self] in
      do {
        try await harness.restore()
        let restored = await harness.snapshot()
        let restoredOperation = restored.lanes[.main]?.activeOperation.flatMap { restored.operations[$0] }
        let operationID: OperationID
        if promptOverride == nil, let restoredOperation, restoredOperation.state == .suspended {
          operationID = restoredOperation.id
          try await harness.resume(.main)
        } else {
          operationID = try await harness.prompt(PromptInput(text: prompt), lane: .main)
        }
        guard let self else { return }
        self.harnessOperationIDs[task.id] = operationID
        self.appendEvent(restoredOperation != nil && promptOverride == nil ? "Harness 已恢复任务。" : "Harness 已接收任务。", kind: .taskStarted, for: task.id, payload: [
          "operationID": operationID.uuidString,
          "authority": HarnessExecutionAuthority.harnessNative.rawValue
        ])
      } catch {
        guard let self else { return }
        self.harnessOperationIDs.removeValue(forKey: task.id)
        self.updateTask(task.id) { current in
          current.status = .failed
          current.updatedAt = .now
          if let turnID = current.activeTurnID,
             let index = current.turns.firstIndex(where: { $0.id == turnID }) {
            current.turns[index].status = .failed
            current.turns[index].errorMessage = error.localizedDescription
            current.turns[index].updatedAt = .now
          }
        }
        self.appendEvent("Harness 无法启动任务：\(error.localizedDescription)", kind: .error, for: task.id)
      }
    }
  }

  private func attachHarnessEvents(for taskID: AgentTask.ID, harness: AgentHarness) {
    guard harnessEventTasks[taskID] == nil else { return }
    harnessEventTasks[taskID] = Task { [weak self] in
      let stream = await harness.events()
      for await event in stream {
        guard let self else { return }
        self.consumeHarnessEvent(event, taskID: taskID)
      }
    }
  }

  private func consumeHarnessEvent(_ event: HarnessEvent, taskID: AgentTask.ID) {
    guard let task = state.tasks.first(where: { $0.id == taskID }) else { return }
    switch event.kind {
    case .operationAccepted:
      if let payload = event.payload,
         let operation = try? JSONDecoder().decode(HarnessOperation.self, from: payload) {
        appendEvent("Harness 已接收请求。", kind: .taskStarted, for: taskID, payload: [
          "operationID": operation.id.uuidString,
          "sequence": String(event.sequence)
        ])
      }
    case .operationStateChanged:
      guard let payload = event.payload,
            let operation = try? JSONDecoder().decode(HarnessOperation.self, from: payload) else { return }
      switch operation.state {
      case .running where task.status == .planning:
        updateTask(taskID) { $0.status = .running; $0.updatedAt = .now }
      case .suspended:
        updateTask(taskID) { current in
          if current.status == .running { current.status = .waitingForUser }
          current.updatedAt = .now
        }
      case .failed where task.status == .planning || task.status == .running:
        updateTask(taskID) { $0.status = .failed; $0.updatedAt = .now }
      default:
        break
      }
    case .effectIntentWritten:
      guard let payload = event.payload,
            let intent = try? JSONDecoder().decode(HarnessEffectIntent.self, from: payload) else { return }
      appendEvent(
        "准备执行：\(intent.subject)",
        kind: .toolRequested,
        for: taskID,
        payload: [
          "effectID": intent.effectID.uuidString,
          "tool": intent.subject,
          "risk": intent.risk.rawValue,
          "authority": HarnessExecutionAuthority.harnessNative.rawValue
        ]
      )
    case .permissionSettled:
      guard let payload = event.payload,
            let receipt = try? JSONDecoder().decode(HarnessPermissionReceipt.self, from: payload) else { return }
      appendEvent(
        receipt.decision == .allow ? "已批准工具请求：(receipt.toolID)" : "已拒绝工具请求：(receipt.toolID)",
        kind: receipt.decision == .allow ? .permissionApproved : .permissionDenied,
        for: taskID,
        payload: [
          "requestID": receipt.requestID.uuidString,
          "tool": receipt.toolID,
          "decision": receipt.decision.rawValue,
          "authority": HarnessExecutionAuthority.harnessNative.rawValue
        ]
      )
    case .effectStarted:
      guard let payload = event.payload,
            let intent = try? JSONDecoder().decode(HarnessEffectIntent.self, from: payload) else { return }
      appendEvent(
        "正在执行：\(intent.subject)",
        kind: .toolStarted,
        for: taskID,
        payload: ["effectID": intent.effectID.uuidString, "tool": intent.subject]
      )
    case .effectSettled:
      guard let payload = event.payload,
            let receipt = try? JSONDecoder().decode(HarnessEffectReceipt.self, from: payload) else { return }
      let succeeded = receipt.outcome == .success
      appendEvent(
        succeeded ? "工具执行完成。" : "工具执行失败：\(receipt.errorMessage ?? receipt.output ?? "未知错误")",
        kind: succeeded ? .toolFinished : .error,
        for: taskID,
        payload: [
          "effectID": receipt.effectID.uuidString,
          "outcome": receipt.outcome.rawValue,
          "output": receipt.output ?? "",
          "error": receipt.errorMessage ?? ""
        ]
      )
    // Model stream blocks and canonical intermediate messages are durable
    // replay facts, not chat transcript rows.  User-facing activity remains
    // driven by the corresponding Intent/Permission/Receipt events below so
    // reasoning text and raw tool JSON can never leak into the main chat.
    case .turnStarted,
         .stepStarted,
         .requestHeader,
         .modelChunk,
         .assistantMessage,
         .toolCallDeclared,
         .toolResultRecorded,
         .stepEnded,
         .turnEnded,
         .entryAppended,
         .queueEnqueued,
         .snapshotPublished:
      break
    }
  }

  private func runCompatibilityOperation(
    taskID: AgentTask.ID,
    context: HarnessOperationContext,
    permission: KimiPermissionMode,
    emit: @escaping AgentHarness.DriverEventSink
  ) async throws {
    guard let task = state.tasks.first(where: { $0.id == taskID }) else {
      throw NSError(domain: "Harness", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到任务。"])
    }
    await emit(.artifact("executionAuthority=compatibilityACP"))
    startCompatibilityTask(task, permission: permission, promptOverride: context.prompt.text)

    while true {
      try Task.checkCancellation()
      guard let current = state.tasks.first(where: { $0.id == taskID }) else {
        throw NSError(domain: "Harness", code: 404, userInfo: [NSLocalizedDescriptionKey: "任务已被删除。"])
      }
      switch current.status {
      case .running, .planning, .verifying:
        try await Task.sleep(nanoseconds: 50_000_000)
      case .waitingForUser:
        throw NSError(domain: "Harness", code: 409, userInfo: [NSLocalizedDescriptionKey: "任务等待用户审批。"])
      case .failed, .cancelled, .blocked:
        throw NSError(domain: "Harness", code: 1, userInfo: [NSLocalizedDescriptionKey: "任务执行失败或已取消。"])
      default:
        let reply = current.turns.last?.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reply, !reply.isEmpty {
          await emit(.assistantText(reply))
        }
        await emit(.artifact("operation=\(context.operationID.uuidString) completed"))
        return
      }
    }
  }

  private func runNativeHarnessOperation(
    taskID: AgentTask.ID,
    context: HarnessOperationContext,
    emit: @escaping AgentHarness.DriverEventSink
  ) async throws {
    guard let task = state.tasks.first(where: { $0.id == taskID }) else {
      throw NSError(domain: "Harness", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到任务。"])
    }
    guard let apiKey = try kimiRuntimeIdentityStore.apiKey(), !apiKey.isEmpty,
          let baseURL = URL(string: kimiRuntimeIdentity.baseURL) else {
      throw NSError(domain: "Harness", code: 401, userInfo: [NSLocalizedDescriptionKey: "Kimi API Key 或 Base URL 未配置。"])
    }

    let workspaceURL = beginTaskWorkspaceAccess(for: task)
    let turnID = activeTurnIDs[task.id] ?? task.activeTurnID ?? task.turns.last?.id
    if let turnID {
      activeTurnIDs[task.id] = turnID
      updateTask(task.id) { current in
        current.activeTurnID = turnID
        if let index = current.turns.firstIndex(where: { $0.id == turnID }) {
          current.turns[index].status = .running
          current.turns[index].attempt += 1
          current.turns[index].errorMessage = nil
          current.turns[index].updatedAt = .now
        }
      }
    }

    var workingDirectory = workspaceURL
    var baseCommit: String?
    if !task.mode.isReadOnly {
      if let existingPath = task.worktreePath, FileManager.default.fileExists(atPath: existingPath) {
        workingDirectory = URL(fileURLWithPath: existingPath, isDirectory: true)
        baseCommit = task.diffSnapshot?.baseCommit
      } else if GitWorktreeManager.hasUsableHEAD(workspaceURL) {
        let worktreeRoot = applicationSupportDirectory.appendingPathComponent("worktrees", isDirectory: true)
        let worktree = try GitWorktreeManager.create(for: workspaceURL, taskID: task.id, rootDirectory: worktreeRoot)
        workingDirectory = worktree.path
        baseCommit = worktree.baseCommit
        updateTask(task.id) { current in
          current.worktreePath = worktree.path.path
          current.branch = worktree.branch
          current.updatedAt = .now
        }
        appendEvent("已创建隔离 Worktree：\(worktree.branch)", kind: .toolFinished, for: task.id, payload: ["path": worktree.path.path, "branch": worktree.branch])
      } else {
        appendEvent("当前项目没有可用 Git HEAD，Harness 将在当前工作区执行。", kind: .toolProgress, for: task.id, payload: ["worktreeFallback": "workspace"])
      }
    }

    updateTask(task.id) { current in
      current.status = .running
      current.updatedAt = .now
    }
    appendEvent("Harness 正在通过 Kimi API 执行任务。", kind: .taskStarted, for: task.id, payload: ["authority": HarnessExecutionAuthority.harnessNative.rawValue])

    let modelID = KimiRuntimeIdentityStore.resolvedModelID(taskModelID: task.modelID, fallbackModelID: kimiRuntimeIdentity.modelID)
    let intentDecision = TaskIntentRouter.decide(for: context.prompt.text)
    let webToolExecutor: WebRuntimeToolExecutor?
    if webResearchSettings.isEnabled {
      do {
        webToolExecutor = WebRuntimeToolExecutor(runtime: try await makeNativeWebRuntime(modelID: modelID, baseURL: baseURL, apiKey: apiKey))
        appendEvent("联网研究已就绪：Swift 原生 Search / Fetch 将自动读取公开来源。", kind: .toolProgress, for: taskID, payload: ["provider": webResearchSettings.provider.runtimeIdentifier, "runtime": "swift"])
      } catch {
        if intentDecision.intent == .webResearch { throw error }
        webToolExecutor = nil
        appendEvent("Swift 原生 Web Runtime 未启用：\(error.localizedDescription)", kind: .toolProgress, for: taskID, payload: ["runtime": "swift", "available": "false"])
      }
    } else {
      if intentDecision.intent == .webResearch {
        throw NSError(domain: "WebResearch", code: 20, userInfo: [NSLocalizedDescriptionKey: "联网研究已关闭。请在设置中启用 Web Search。"])
      }
      webToolExecutor = nil
    }
    let taskContract = TaskContract.make(prompt: context.prompt.text, decision: intentDecision, mode: task.mode)
    let taskBudget = TaskBudget.standard
    let accumulatedCost = usageLedger.totalCost(operationID: context.operationID)
    switch CostBudgetGate.decision(spent: accumulatedCost, budget: taskBudget.maxCost) {
    case .exceeded:
      throw NSError(
        domain: "HarnessBudget",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "当前任务已超过成本预算；请提高预算或继续使用更低成本模型。"]
      )
    case .warning:
      appendEvent("当前任务已使用超过 80% 的模型预算。", kind: .toolProgress, for: taskID, payload: ["budget": "warning"])
    case .allowed:
      break
    }
    let modelRoute = ModelRouter.route(
      intent: intentDecision.intent,
      promptLength: context.prompt.text.count,
      budget: taskBudget
    )
    let usageStage = intentDecision.recommendedAgents.last ?? (task.mode.isReadOnly ? .explore : .implement)
    let memoryRules = memories(for: task).map { "[\($0.scope.rawValue)] \($0.content)" }
    let verifiedContext = task.verificationResult?.steps.filter(\.passed).map { step in
      "\(step.kind.rawValue) 通过"
    } ?? []
    let unresolvedContext = task.agentRuns.compactMap { run -> String? in
      guard !run.state.isTerminal else { return nil }
      return "\(run.definition.kind.title)：\(run.errorMessage ?? "尚未完成")"
    }
    let contextProjection = ContextProjector.project(
      turns: task.turns.filter { $0.id != turnID },
      contract: taskContract,
      rules: memoryRules,
      verifiedResults: verifiedContext,
      unresolved: unresolvedContext
    )
    let effectiveConversationContext = contextProjection.promptText
    appendEvent(
      "策略已选择：\(intentDecision.intent.rawValue)。",
      kind: .taskPlanned,
      for: taskID,
      payload: [
        "intent": intentDecision.intent.rawValue,
        "agents": intentDecision.recommendedAgents.map(\.rawValue).joined(separator: ","),
        "requiresPlanning": intentDecision.requiresPlanning ? "true" : "false",
        "modelTier": modelRoute.tier.rawValue,
        "maximumOutputTokens": String(modelRoute.maximumOutputTokens)
      ]
    )
    let taskPrompt = TaskPromptComposer.compose(
      prompt: context.prompt.text,
      mode: task.mode,
      workspacePath: task.workspacePath,
      worktreePath: workingDirectory.path,
      branch: task.branch,
      modelID: modelID,
      skillsDirectories: task.skillsDirectories,
      allowedDomains: activeNetworkDomains,
      terminalContext: task.terminalSession?.agentContextSummary,
      rules: task.ruleSet.effectiveRules,
      conversationContext: effectiveConversationContext,
      intentDecision: intentDecision,
      taskContract: taskContract
    )

    let configuredBrowserDomains = Array(Set(activeNetworkDomains + (extensionConfiguration?.allowedDomains ?? []))).sorted()
    let promptURL = BrowserHarnessRequestDecoder.firstHTTPURL(in: context.prompt.text)
    let browserArtifactsDirectory = applicationSupportDirectory
      .appendingPathComponent("browser-artifacts", isDirectory: true)
      .appendingPathComponent(taskID.uuidString, isDirectory: true)
    let browserHandler: NativeHarnessToolRuntime.SpecializedToolHandler = { request in
      var plan = try BrowserHarnessRequestDecoder.plan(from: request, fallbackURL: promptURL)
      plan.allowedDomains = Array(Set(plan.allowedDomains + configuredBrowserDomains)).sorted()
      // A Browser tool call has already crossed the unified permission gate.
      // Bind explicitly requested external hosts to this one plan so the
      // controller does not ask a second, disconnected approval dialog.
      for step in plan.steps {
        if let host = step.url?.host?.lowercased(), !BrowserDomainPolicy.isLocal(host: host) {
          plan.allowedDomains.append(host)
        }
      }
      plan.allowedDomains = Array(Set(plan.allowedDomains)).sorted()
      let controller = await MainActor.run { BrowserVerificationController() }
      let result = await controller.run(plan: plan, artifactsDirectory: browserArtifactsDirectory)
      let artifactSummary = result.artifacts.compactMap { artifact in
        [artifact.name, artifact.path ?? artifact.text ?? ""].joined(separator: ": ")
      }.joined(separator: "\n")
      return ToolExecutionResult(
        output: result.passed ? "浏览器验证通过。\n\(result.repairSummary)" : "浏览器验证失败。\n\(result.repairSummary)",
        metadata: [
          "adapter": "browser",
          "passed": result.passed ? "true" : "false",
          "url": result.currentURL?.absoluteString ?? "",
          "artifacts": artifactSummary
        ],
        exitCode: result.passed ? 0 : 1
      )
    }
    let computerUseHandler: NativeHarnessToolRuntime.SpecializedToolHandler = { request in
      try await ComputerUseController.executeHarnessRequest(request)
    }
    let mcpExecutor = extensionRuntime.map { MCPHarnessToolExecutor(runtime: $0, workerSupervisor: self.mcpWorkerSupervisor) }
    let mcpHandler: NativeHarnessToolRuntime.SpecializedToolHandler?
    if let mcpExecutor {
      mcpHandler = { request in try await mcpExecutor.execute(request) }
    } else {
      mcpHandler = nil
    }
    let runtime = NativeHarnessToolRuntime(
      workspaceURL: workingDirectory,
      browserHandler: browserHandler,
      computerUseHandler: computerUseHandler,
      mcpHandler: mcpHandler
    )
    var nativeToolIDs: Set<String> = [
      "read", "search", "write", "shell", "browser",
      "computer_use.inspect", "computer_use.screenshot", "computer_use.click",
      "computer_use.click_element", "computer_use.type_text", "computer_use.press_key"
    ]
    if webToolExecutor != nil {
      nativeToolIDs.formUnion(["web.search", "web.fetch"])
    }
    if mcpExecutor != nil {
      nativeToolIDs.insert("mcp")
    }
    let definitions = ToolCatalog.defaultDefinitions.filter { nativeToolIDs.contains($0.id) }
    let registry = ToolRegistry(definitions: definitions)
    for definition in definitions {
      await registry.register(definition, executor: runtime)
    }
    if let webToolExecutor {
      for id in ["web.search", "web.fetch"] {
        if let definition = definitions.first(where: { $0.id == id }) {
          await registry.register(definition, executor: webToolExecutor)
        }
      }
    }

    if let mcpExecutor, let mcpDefinitions = try? mcpExecutor.discoverDefinitions() {
      let selectedMCPIDs = Set(
        mcpToolCatalog.relevant(query: context.prompt.text, limit: 12).map(\.id)
      )
      let relevantDefinitions = mcpDefinitions.filter { definition in
        guard !selectedMCPIDs.isEmpty else { return true }
        return selectedMCPIDs.contains { selectedID in
          guard let toolName = selectedID.split(separator: ":").last.map(String.init) else { return false }
          return definition.id.hasSuffix(".\(toolName)")
        }
      }
      let definitionsToRegister = relevantDefinitions.isEmpty ? Array(mcpDefinitions.prefix(12)) : relevantDefinitions
      for definition in definitionsToRegister {
        await registry.register(definition, executor: mcpExecutor)
      }
      if !definitionsToRegister.isEmpty {
        appendEvent("MCP Tool Search 已选择 \(definitionsToRegister.count) 个相关工具。", kind: .toolProgress, for: taskID, payload: ["authority": HarnessExecutionAuthority.harnessNative.rawValue, "toolSearch": "true"])
      }
    }

    let toolWorkspacePath = workingDirectory.path
    let journal = ToolEffectJournal(
      store: harnessEventStore,
      sessionID: context.sessionID,
      lane: context.lane,
      eventSink: emit
    )
    let coordinator = ToolExecutionCoordinator(
      registry: registry,
      permissionResolver: StaticToolPermissionResolver(decision: .ask),
      approvalHandler: { [weak self] request, definition in
        guard let self else { return .deny }
        return await self.requestNativeToolApproval(request: request, definition: definition, workspacePath: toolWorkspacePath)
      },
      hookResolver: { [weak self] request in
        await MainActor.run {
          self?.resolveHarnessHooks(request, taskID: taskID)
        }
      },
      journal: journal
    )
    let provider = KimiHTTPModelProvider(
      baseURL: baseURL,
      apiKey: apiKey,
      modelID: modelID,
      maximumOutputTokens: modelRoute.maximumOutputTokens,
      traceRecorder: providerTraceRecorder
    )
    let providerStartedAt = Date()
    let loop = HarnessConversationLoop(
      provider: provider,
      maxRounds: 8,
      executeTool: { call, _ in
        let request = ToolExecutionRequest(
          taskID: taskID,
          sessionID: context.sessionID,
          operationID: context.operationID,
          agentID: "main",
          toolID: call.name,
          inputJSON: Self.nativeToolInputJSON(from: call.argumentsJSON),
          resource: Self.nativeToolResource(from: call.argumentsJSON),
          command: Self.nativeToolCommand(from: call.argumentsJSON)
        )
        await emit(.artifact("tool=\(call.name) requested"))
        do {
          let result = try await coordinator.execute(request)
          await emit(.artifact("tool=\(call.name) settled"))
          return HarnessToolResult(callID: call.id, toolName: call.name, output: result.output, isError: result.exitCode.map { $0 != 0 } ?? false)
        } catch {
          await emit(.artifact("tool=\(call.name) failed"))
          return HarnessToolResult(callID: call.id, toolName: call.name, output: error.localizedDescription, isError: true)
        }
      },
      executeBatch: { calls, _ in
        let requests = calls.map { call in
          ToolExecutionRequest(
            taskID: taskID,
            sessionID: context.sessionID,
            operationID: context.operationID,
            agentID: "main",
            toolID: call.name,
            inputJSON: Self.nativeToolInputJSON(from: call.argumentsJSON),
            resource: Self.nativeToolResource(from: call.argumentsJSON),
            command: Self.nativeToolCommand(from: call.argumentsJSON)
          )
        }
        let outcomes = await coordinator.executeBatch(requests)
        var results: [HarnessToolResult] = []
        results.reserveCapacity(calls.count)
        for index in calls.indices {
          let call = calls[index]
          switch outcomes[index] {
          case let .success(result):
            await emit(.artifact("tool=\(call.name) settled"))
            results.append(HarnessToolResult(callID: call.id, toolName: call.name, output: result.output, isError: result.exitCode.map { $0 != 0 } ?? false))
          case let .failure(error):
            await emit(.artifact("tool=\(call.name) failed"))
            results.append(HarnessToolResult(callID: call.id, toolName: call.name, output: error.localizedDescription, isError: true))
          }
        }
        return results
      },
      maximumOutputTokens: modelRoute.maximumOutputTokens,
      eventSink: { event in await emit(event) },
      nextStepInput: context.takeSteering
    )

    do {
      let result = try await loop.run(
        request: HarnessConversationRequest(modelID: modelID, messages: [.user(taskPrompt)]),
        tools: await registry.all()
      )
      let reportedUsage = result.usage ?? HarnessModelUsage(
        inputTokens: max(1, taskPrompt.count / 3),
        outputTokens: max(0, result.text.count / 3)
      )
      let pricedUsage = ModelPriceCatalog.cost(
        provider: "kimi",
        model: modelID,
        inputTokens: reportedUsage.inputTokens,
        outputTokens: reportedUsage.outputTokens,
        cachedTokens: reportedUsage.cachedTokens
      )
      try? usageLedger.append(UsageLedgerEntry(
        operationID: context.operationID,
        stage: usageStage,
        provider: "kimi",
        model: modelID,
        inputTokens: reportedUsage.inputTokens,
        outputTokens: reportedUsage.outputTokens,
        cachedTokens: reportedUsage.cachedTokens,
        latencyMS: Int(Date().timeIntervalSince(providerStartedAt) * 1_000),
        estimatedCost: pricedUsage.value,
        qualityScore: nil,
        pricingStatus: pricedUsage.status
      ))
      appendNativeAssistantReply(result.text, taskID: taskID, turnID: turnID)
      await emit(.assistantText(result.text))
      let blockedError = result.blockedByToolFailure ? result.text : ""
      finishTask(
        taskID,
        result: KimiProcessResult(
          standardOutput: result.text,
          standardError: blockedError,
          exitCode: result.blockedByToolFailure ? 1 : 0
        ),
        workingDirectory: workingDirectory,
        baseCommit: baseCommit
      )
    } catch {
      if error is KimiHTTPProviderError {
        appendEvent("Kimi API Provider 不可用：\(error.localizedDescription)，准备回退兼容执行器。", kind: .toolProgress, for: taskID, payload: ["fallback": "compatibilityACP", "providerError": error.localizedDescription])
        endTaskWorkspaceAccess(for: taskID)
        throw error
      }
      appendEvent("Harness 原生执行失败：\(error.localizedDescription)", kind: .error, for: taskID)
      finishTask(taskID, result: KimiProcessResult(standardOutput: "", standardError: error.localizedDescription, exitCode: 1), workingDirectory: workingDirectory, baseCommit: baseCommit)
      throw error
    }
  }

  private func appendNativeAssistantReply(_ text: String, taskID: AgentTask.ID, turnID: UUID?) {
    let clean = ResponseQualityGate.enforce(text, outcome: .completed)
    guard !clean.isEmpty, let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
    appendEvents([clean], for: taskID)
    let sessionID = UUID(uuidString: state.tasks[index].sessionID ?? "") ?? UUID()
    let event = AgentEvent(
      sessionID: sessionID,
      taskID: taskID,
      turnID: turnID,
      sequence: Int64(state.tasks[index].structuredEvents.count + 1),
      actor: "harness",
      kind: .output,
      payload: ["role": "assistant", "text": clean, "authority": HarnessExecutionAuthority.harnessNative.rawValue]
    )
    state.tasks[index].structuredEvents.append(event)
    if let turnID, let turnIndex = state.tasks[index].turns.firstIndex(where: { $0.id == turnID }) {
      state.tasks[index].turns[turnIndex].assistantMessage = clean
      state.tasks[index].turns[turnIndex].updatedAt = .now
    }
    enqueueSessionKernelEvent(event)
    schedulePersistence()
  }

  private func resolveHarnessHooks(_ request: HarnessHookRequest, taskID: AgentTask.ID) -> HarnessHookResolution? {
    guard let runtime = extensionRuntime,
          let task = state.tasks.first(where: { $0.id == taskID }) else {
      return HarnessHookResolution(
        isAllowed: true,
        arguments: request.arguments,
        context: [],
        auditHookIDs: []
      )
    }
    do {
      let results = try runtime.runHooks(event: request.event, task: task)
      recordExtensionResults(results, for: taskID)
      if let blocked = results.first(where: { $0.decision == .block }) {
        return HarnessHookResolution(
          isAllowed: false,
          denialReason: "Hook 阻断：\(blocked.command)",
          arguments: request.arguments,
          context: [],
          auditHookIDs: results.map(\.hookID)
        )
      }
      return HarnessHookResolution(
        isAllowed: true,
        arguments: request.arguments,
        context: results.compactMap { result in
          let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
          return output.isEmpty ? nil : output
        },
        auditHookIDs: results.map(\.hookID)
      )
    } catch {
      appendEvent("Harness Hook 执行失败：\(error.localizedDescription)", kind: .error, for: taskID)
      return HarnessHookResolution(
        isAllowed: false,
        denialReason: "Hook 执行失败",
        arguments: request.arguments,
        context: [],
        auditHookIDs: []
      )
    }
  }

  private func nativeWebSearchURL() -> URL? {
    guard let rawURL = webResearchBridgeURL, let url = URL(string: rawURL), isWebResearchBridgeHealthy(rawURL) else { return nil }
    return url
  }

  /// Builds the only Web capability used by the native Harness.  The legacy
  /// Node bridge remains available solely for ACP/CLI compatibility and the
  /// settings connection diagnostic; native Kimi API sessions never depend on
  /// a localhost bridge process for Search or Fetch.
  private func makeNativeWebRuntime(modelID: String, baseURL: URL, apiKey: String) async throws -> WebRuntime {
    guard webResearchSettings.isEnabled else {
      throw NSError(domain: "WebResearch", code: 20, userInfo: [NSLocalizedDescriptionKey: "联网研究已关闭。"])
    }
    let selectedID = webResearchSettings.provider.runtimeIdentifier
    var priority = [selectedID]
    if selectedID != "kimi_official", !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      priority.append("kimi_official")
    }
    let runtime = WebRuntime(searchPriority: priority, fetchPriority: ["http"])
    try await runtime.register(fetch: HTTPWebFetchProvider())

    switch webResearchSettings.provider {
    case .kimiOfficial:
      guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NSError(domain: "WebResearch", code: 21, userInfo: [NSLocalizedDescriptionKey: "Kimi 官方联网需要已保存的 Kimi API Key。"])
      }
      let configuredFormulaModel = ProcessInfo.processInfo.environment["KIMI_AGENT_OFFICIAL_TOOLS_MODEL"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let formulaModel = configuredFormulaModel.isEmpty ? modelID : configuredFormulaModel
      try await runtime.register(search: KimiOfficialWebProvider(apiKey: apiKey, baseURL: baseURL, modelID: formulaModel))
    case .brave:
      guard let searchKey = try webResearchSettingsStore.apiKey(), !searchKey.isEmpty,
            let endpoint = URL(string: webResearchSettings.endpoint) else {
        throw NSError(domain: "WebResearch", code: 24, userInfo: [NSLocalizedDescriptionKey: "Brave Search 需要有效的 API Key 和服务地址。"])
      }
      try await runtime.register(search: BraveWebSearchProvider(apiKey: searchKey, endpoint: endpoint))
      if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try await runtime.register(search: KimiOfficialWebProvider(apiKey: apiKey, baseURL: baseURL, modelID: modelID))
      }
    case .searxng:
      guard let endpoint = URL(string: webResearchSettings.endpoint) else {
        throw NSError(domain: "WebResearch", code: 25, userInfo: [NSLocalizedDescriptionKey: "SearxNG 服务地址无效。"])
      }
      try await runtime.register(search: SearxNGWebSearchProvider(endpoint: endpoint))
      if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try await runtime.register(search: KimiOfficialWebProvider(apiKey: apiKey, baseURL: baseURL, modelID: modelID))
      }
    }
    return runtime
  }

  /// Starts the local Web Research bridge before the model receives its tool
  /// schema. Previously the native API path only registered `web.search` if a
  /// bridge happened to have been started elsewhere, so the model frequently
  /// never saw a search tool at all. A research task is now explicit: either
  /// the bridge is ready and the tool is registered, or the user gets the
  /// concrete connection error instead of an invented offline answer.
  private func startNativeWebResearchBridge(modelID: String) throws -> URL {
    guard webResearchSettings.isEnabled else {
      throw NSError(
        domain: "WebResearch",
        code: 20,
        userInfo: [NSLocalizedDescriptionKey: "联网研究已关闭。请在设置中启用 Kimi 官方联网或配置其他搜索服务。"]
      )
    }
    if webResearchSettings.provider.usesKimiAPIKey,
       !(kimiRuntimeIdentity.mode == .apiKey && kimiRuntimeIdentity.isAPIConfigured) {
      throw NSError(
        domain: "WebResearch",
        code: 21,
        userInfo: [NSLocalizedDescriptionKey: "Kimi 官方联网需要已保存的 Kimi API Key。"]
      )
    }
    guard let nodePath = NativeRuntimeLocator.nodePath() else {
      throw NSError(
        domain: "WebResearch",
        code: 22,
        userInfo: [NSLocalizedDescriptionKey: "未找到 Node，无法启动内置 Web Search Bridge。请重新安装应用或设置 KIMI_NODE_PATH。"]
      )
    }

    var environment = try runtimeEnvironmentForCurrentIdentity(additionalModelIDs: [modelID])
    // Keep web research on Kimi's official-tools default model unless the user
    // explicitly overrides it in the process environment. Coding models can be
    // excellent at implementation while still being less stable as Formula
    // search orchestrators.
    if let override = ProcessInfo.processInfo.environment["KIMI_AGENT_OFFICIAL_TOOLS_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty {
      environment["KIMI_AGENT_OFFICIAL_TOOLS_MODEL"] = override
    } else {
      environment.removeValue(forKey: "KIMI_AGENT_OFFICIAL_TOOLS_MODEL")
    }
    guard let rawURL = try startWebResearchBridgeIfNeeded(nodePath: nodePath, environment: environment),
          let url = URL(string: rawURL) else {
      throw NSError(
        domain: "WebResearch",
        code: 23,
        userInfo: [NSLocalizedDescriptionKey: "Web Search Bridge 没有返回可用地址。"]
      )
    }
    return url
  }

  private func executeNativeWebSearch(_ request: ToolExecutionRequest, endpoint: URL) async throws -> ToolExecutionResult {
    guard let query = request.input["query"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
      throw NativeHarnessToolError.missingInput("query")
    }
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: ["text_query": query])
    let (data, response) = try await URLSession.shared.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      throw NSError(domain: "NativeWebSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Web Search 请求失败：没有收到 HTTP 响应。"])
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw NSError(
        domain: "NativeWebSearch",
        code: http.statusCode,
        userInfo: [
          NSLocalizedDescriptionKey: "Web Search 请求失败：" + WebResearchConnectionPresentation.bridgeFailureMessage(statusCode: http.statusCode, body: body)
        ]
      )
    }
    return ToolExecutionResult(output: String(data: data, encoding: .utf8) ?? "{}", metadata: ["query": query, "status": String(http.statusCode)])
  }

  private func usesNativeHarnessProvider() -> Bool {
    kimiRuntimeIdentity.mode == .apiKey && kimiRuntimeIdentity.isAPIConfigured
  }

  private nonisolated static func nativeToolInputJSON(from argumentsJSON: String) -> HarnessJSONValue {
    guard let data = argumentsJSON.data(using: .utf8),
          case let .object(decoded) = try? JSONDecoder().decode(HarnessJSONValue.self, from: data) else {
      return .object([:])
    }
    // Some Kimi-compatible tool streams wrap their argument object. Unwrap
    // only that top-level envelope; nested values remain JSON-native instead
    // of being flattened into lossy strings.
    var values = decoded.reduce(into: [String: HarnessJSONValue]()) { result, element in
      let key = element.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      result[key] = element.value
    }
    for wrapper in ["arguments", "input", "parameters"] {
      guard case let .object(nested)? = values.removeValue(forKey: wrapper) else { continue }
      for (key, value) in nested {
        values[key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = value
      }
    }
    if values["query"] == nil, let text = values["text_query"] { values["query"] = text }
    if values["url"] == nil, let target = values["target_url"] { values["url"] = target }
    return .object(values)
  }

  private nonisolated static func nativeToolInput(from argumentsJSON: String) -> [String: String] {
    nativeToolInputJSON(from: argumentsJSON).compatibilityObject()
  }

  private nonisolated static func nativeToolResource(from argumentsJSON: String) -> String? {
    let input = nativeToolInput(from: argumentsJSON)
    return input["path"] ?? input["url"] ?? input["cwd"]
  }

  private nonisolated static func nativeToolCommand(from argumentsJSON: String) -> String? {
    nativeToolInput(from: argumentsJSON)["command"]
  }

  private func startCompatibilityTask(_ task: AgentTask, permission: KimiPermissionMode, promptOverride: String? = nil) {
    let workspaceURL = beginTaskWorkspaceAccess(for: task)
    let turnID = activeTurnIDs[task.id] ?? task.activeTurnID ?? task.turns.last?.id
    if let turnID {
      activeTurnIDs[task.id] = turnID
      updateTask(task.id) { current in
        current.activeTurnID = turnID
        if let index = current.turns.firstIndex(where: { $0.id == turnID }) {
          current.turns[index].status = .running
          current.turns[index].attempt += 1
          current.turns[index].errorMessage = nil
          current.turns[index].updatedAt = .now
        }
      }
    }
    guard let runtimeURL = NativeRuntimeLocator.runtimeURL(),
          let nodePath = NativeRuntimeLocator.nodePath() else {
      updateTask(task.id) { current in
        current.status = .failed
        current.updatedAt = .now
      }
      appendEvent("未找到 Node 或 Kimi Runtime。请运行原生构建脚本，或配置 KIMI_NODE_PATH / KIMI_RUNTIME_PATH。", for: task.id)
      runLifecycleHooks(.taskFailed, taskID: task.id)
      return
    }

    var runtimeEnvironment: [String: String]
    do {
      runtimeEnvironment = try runtimeEnvironmentForCurrentIdentity(
        additionalModelIDs: [task.modelID].compactMap { $0 }
      )
    } catch {
      updateTask(task.id) { current in
        current.status = .failed
        current.updatedAt = .now
      }
      appendEvent("无法准备 Kimi 连接：\(error.localizedDescription)", kind: .error, for: task.id)
      showLoginSheet = true
      runLifecycleHooks(.taskFailed, taskID: task.id)
      return
    }

    // Compatibility ACP/CLI may provide model text only. It must never gain a
    // second, Node-owned web execution path that bypasses Swift Harness
    // permission, Intent/Receipt, source registration, or private-network
    // blocking. Native Kimi API sessions use WebRuntime above instead.
    for key in [
      "KIMI_WEB_SEARCH_BASE_URL",
      "KIMI_WEB_SEARCH_API_KEY",
      "KIMI_AGENT_WEB_SEARCH_PROVIDER",
      "KIMI_AGENT_WEB_SEARCH_API_KEY",
      "KIMI_AGENT_WEB_SEARCH_ENDPOINT",
      "KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL",
      "KIMI_AGENT_OFFICIAL_TOOLS_MODEL"
    ] {
      runtimeEnvironment.removeValue(forKey: key)
    }
    appendEvent("兼容执行器已禁用 Node Web Bridge；联网工具仅由 Swift Harness 执行。", kind: .toolProgress, for: task.id)

    var workingDirectory = workspaceURL
    var baseCommit: String?
    if !task.mode.isReadOnly {
      if let existingWorktreePath = task.worktreePath,
         FileManager.default.fileExists(atPath: existingWorktreePath) {
        workingDirectory = URL(fileURLWithPath: existingWorktreePath, isDirectory: true)
        baseCommit = task.diffSnapshot?.baseCommit
      } else if !GitWorktreeManager.hasUsableHEAD(workingDirectory) {
        appendEvent(
          "当前项目没有可用的 Git HEAD，已回退到当前工作区执行。任务仍会保留事件、终端输出和可审阅状态；如需隔离 Worktree，请先创建一次 Git 提交。",
          kind: .toolProgress,
          for: task.id,
          payload: ["worktreeFallback": "workspace", "reason": "missing_head"]
        )
      } else {
        do {
          let worktreeRoot = applicationSupportDirectory.appendingPathComponent("worktrees", isDirectory: true)
          let worktree = try GitWorktreeManager.create(for: workingDirectory, taskID: task.id, rootDirectory: worktreeRoot)
          workingDirectory = worktree.path
          baseCommit = worktree.baseCommit
          updateTask(task.id) { current in
            current.worktreePath = worktree.path.path
            current.branch = worktree.branch
            current.updatedAt = .now
          }
          appendEvent(
            "已创建隔离 Worktree：\(worktree.branch)",
            kind: .toolFinished,
            for: task.id,
            payload: ["path": worktree.path.path, "branch": worktree.branch]
          )
        } catch {
          appendEvent(
            "Git Worktree 创建失败，已回退到当前工作区执行：\(error.localizedDescription)",
            kind: .toolProgress,
            for: task.id,
            payload: ["worktreeFallback": "workspace", "reason": "creation_failed"]
          )
        }
      }
    }

    updateTask(task.id) { current in
      current.status = .running
      current.updatedAt = .now
      current.workItems = current.workItems.map { item in
        var item = item
        if item.role == .analyzer { item.status = .running }
        return item
      }
    }
    activateFirstReadyAgentRun(taskID: task.id, worktreePath: workingDirectory.path)
    appendEvent("正在启动 Kimi Runtime…", kind: .taskStarted, for: task.id)
    runLifecycleHooks(.taskStarted, taskID: task.id)

    let resolvedModelID = KimiRuntimeIdentityStore.resolvedModelID(
      taskModelID: task.modelID,
      fallbackModelID: kimiRuntimeIdentity.modelID
    )
    let resolvedPrompt = promptOverride ?? task.title
    let intentDecision = TaskIntentRouter.decide(for: resolvedPrompt)
    let taskContract = TaskContract.make(prompt: resolvedPrompt, decision: intentDecision, mode: task.mode)
    let contextProjection = ContextProjector.project(
      turns: task.turns.filter { $0.id != turnID },
      contract: taskContract
    )

    let taskPrompt = TaskPromptComposer.compose(
      prompt: resolvedPrompt,
      mode: task.mode,
      workspacePath: task.workspacePath,
      worktreePath: workingDirectory.path,
      branch: task.branch,
      modelID: resolvedModelID,
      skillsDirectories: task.skillsDirectories,
      allowedDomains: activeNetworkDomains,
      terminalContext: task.terminalSession?.agentContextSummary,
      rules: task.ruleSet.effectiveRules,
      conversationContext: contextProjection.promptText,
      intentDecision: intentDecision,
      taskContract: taskContract
    )

    let cliCommand = KimiCommandBuilder.makeCommand(
      runtimePath: runtimeURL.path,
      prompt: taskPrompt,
      mode: task.mode,
      permission: permission,
      nodeExecutable: nodePath,
      modelID: resolvedModelID,
      skillsDirectories: task.skillsDirectories
    )

    if let hostScriptURL = NativeRuntimeLocator.agentHostURL() {
      do {
        let sessionID = state.tasks.first(where: { $0.id == task.id })?.sessionID ?? UUID().uuidString
        let hostHandle = try KimiAgentHostRunner.start(
          configuration: KimiAgentHostConfiguration(
            nodePath: nodePath,
            hostScriptURL: hostScriptURL,
            runtimePath: runtimeURL.path,
            workspacePath: workingDirectory.path,
            sessionID: sessionID,
            runtimeSessionID: task.runtimeSessionID,
            taskID: task.id.uuidString,
            prompt: taskPrompt,
            modelID: resolvedModelID,
            skillsDirectories: task.skillsDirectories,
            allowedDomains: activeNetworkDomains,
            environment: runtimeEnvironment
          ),
          onEnvelope: { [weak self] envelope in
            self?.observeHostEnvelope(envelope, for: task.id)
          }
        )
        runningAgentHosts[task.id] = hostHandle
        Task { [weak self] in
          let result = await Task.detached(priority: .userInitiated) {
            hostHandle.wait(timeout: 120)
          }.value
          guard let self else { return }
          self.runningAgentHosts.removeValue(forKey: task.id)
          let hostResult = KimiProcessResult(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            exitCode: result.exitCode
          )
          if self.shouldFallbackToCLI(after: hostResult) {
            self.appendEvent(
              "Native Agent Host 与当前 Kimi CLI 协议不兼容，已自动切换到流式 CLI 执行。",
              kind: .toolProgress,
              for: task.id
            )
            self.startCLI(
              taskID: task.id,
              command: cliCommand,
              workingDirectory: workingDirectory,
              baseCommit: baseCommit,
              environment: runtimeEnvironment
            )
            return
          }
          self.finishTaskAfterEventDrain(
            task.id,
            result: hostResult,
            workingDirectory: workingDirectory,
            baseCommit: baseCommit
          )
        }
        return
      } catch {
        appendEvent("Native Agent Host 启动失败，已回退到 CLI：\(error.localizedDescription)", kind: .error, for: task.id)
      }
    }

    startCLI(taskID: task.id, command: cliCommand, workingDirectory: workingDirectory, baseCommit: baseCommit, environment: runtimeEnvironment)
  }

  private func recordWebResearchEvidence(from event: AgentEvent, for taskID: AgentTask.ID) {
    let additions = WebResearchEvidence.extractSources(from: event)
    guard !additions.isEmpty || event.payload["webResearchAction"] != nil else { return }
    updateTask(taskID) { task in
      task.webResearchSources = WebResearchEvidence.merging(task.webResearchSources, with: additions)
      task.webResearchUsage = WebResearchEvidence.updatingUsage(
        task.webResearchUsage,
        event: event,
        sourceCount: task.webResearchSources.count
      )
      task.updatedAt = .now
    }
  }

  private func startCLI(
    taskID: AgentTask.ID,
    command: KimiCommand,
    workingDirectory: URL,
    baseCommit: String?,
    environment: [String: String] = [:]
  ) {
    do {
      let handle = try KimiProcessRunner.start(
        command,
        workingDirectory: workingDirectory,
        environment: environment,
        onOutput: { [weak self] output in
          self?.observeProcessOutput(output, for: taskID)
        }
      )
      runningProcesses[taskID] = handle
      Task { [weak self] in
        let result = await Task.detached(priority: .userInitiated) {
          handle.wait()
        }.value
        guard let self else { return }
        self.finishTaskAfterEventDrain(
          taskID,
          result: result,
          workingDirectory: workingDirectory,
          baseCommit: baseCommit
        )
      }
    } catch {
      runLifecycleHooks(.taskFailed, taskID: taskID)
      finishTask(
        taskID,
        result: KimiProcessResult(standardOutput: "", standardError: error.localizedDescription, exitCode: 1),
        workingDirectory: workingDirectory,
        baseCommit: baseCommit
      )
    }
  }

  private func shouldFallbackToCLI(after result: KimiProcessResult) -> Bool {
    let output = "\(result.standardOutput)\n\(result.standardError)"
    return result.exitCode != 0 && output.contains("unknown option '--work-dir'")
  }

  /// Envelope/output callbacks arrive from pipe readability handlers. Give the
  /// MainActor one short turn to commit the final chunks before resolving status.
  private func finishTaskAfterEventDrain(
    _ taskID: AgentTask.ID,
    result: KimiProcessResult,
    workingDirectory: URL,
    baseCommit: String?
  ) {
    Task { @MainActor [weak self] in
      await Task.yield()
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled, let self else { return }
      self.finishTask(taskID, result: result, workingDirectory: workingDirectory, baseCommit: baseCommit)
    }
  }

  private func finishTask(_ taskID: AgentTask.ID, result: KimiProcessResult, workingDirectory: URL, baseCommit: String?) {
    defer { endTaskWorkspaceAccess(for: taskID) }
    runningProcesses.removeValue(forKey: taskID)
    flushStreamingBuffers(for: taskID)
    flushPendingOutputEvents()
    synchronizeWebResearchUsage(for: taskID)
    let currentStatus = state.tasks.first(where: { $0.id == taskID })?.status
    if currentStatus == .cancelled || currentStatus == .waitingForUser {
      appendEvent(currentStatus == .waitingForUser ? "任务已暂停。" : "Kimi Runtime 已停止。", for: taskID)
      return
    }

    if result.standardOutput.isEmpty, result.standardError.isEmpty {
      appendEvent("Kimi Runtime 未返回输出。", for: taskID)
    }
    let turnID = activeTurnIDs[taskID] ?? state.tasks.first(where: { $0.id == taskID })?.activeTurnID
    let pendingEvents = pendingStructuredEvents[taskID] ?? []
    let committedEvents = state.tasks.first(where: { $0.id == taskID })?.structuredEvents ?? []
    let outcome = ConversationExecutionOutcome.resolve(
      exitCode: result.exitCode,
      events: committedEvents + pendingEvents,
      turnID: turnID
    )
    let effectiveExitCode: Int32
    let effectiveError: String?
    switch outcome {
    case .completed:
      effectiveExitCode = 0
      effectiveError = nil
    case .failed(let fallbackError):
      effectiveExitCode = result.exitCode == 0 ? 1 : result.exitCode
      let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      effectiveError = stderr.isEmpty ? fallbackError : stderr
    }

    applyFinalAnswerQualityGate(
      for: taskID,
      turnID: turnID,
      outcome: effectiveExitCode == 0 ? .completed : .failed
    )

    updateTask(taskID) { current in
      if let turnID,
         let index = current.turns.firstIndex(where: { $0.id == turnID }) {
        current.turns[index].status = effectiveExitCode == 0 ? .completed : .failed
        current.turns[index].errorMessage = effectiveExitCode == 0 ? nil : effectiveError
        current.turns[index].updatedAt = .now
      }
    }
    if effectiveExitCode == 0 {
      completeAgentRunsAfterExecution(taskID: taskID)
      runLifecycleHooks(.taskCompleted, taskID: taskID)
      validateWebResearchCitations(for: taskID)
    } else {
      failActiveAgentRuns(taskID: taskID, message: effectiveError ?? "Runtime 执行失败")
      runLifecycleHooks(.taskFailed, taskID: taskID)
    }
    if effectiveExitCode == 0,
       let task = state.tasks.first(where: { $0.id == taskID }),
       !task.mode.isReadOnly {
      do {
        let diff = try DiffEngine.snapshot(baseDirectory: workingDirectory, taskID: taskID, baseCommit: baseCommit)
        updateTask(taskID) { current in
          current.diffSnapshot = diff
          current.status = .reviewReady
          current.workItems = current.workItems.map { item in
            var item = item
            if item.role == .analyzer || item.role == .implementer { item.status = .reviewReady }
            return item
          }
          current.updatedAt = .now
        }
        appendEvent("已生成 Diff，等待审阅。", kind: .diffGenerated, for: taskID, payload: ["files": String(diff.files.count)])
        if let latestTask = state.tasks.first(where: { $0.id == taskID }) {
          beginVerification(for: latestTask, showNotice: false)
        }
        return
      } catch {
        appendEvent("Diff 生成失败：\(error.localizedDescription)", kind: .error, for: taskID)
      }
    }
    updateTask(taskID) { task in
      task.status = effectiveExitCode == 0 ? (task.mode.isReadOnly ? .completed : .reviewReady) : .failed
      task.updatedAt = .now
    }
  }

  private func applyFinalAnswerQualityGate(
    for taskID: AgentTask.ID,
    turnID: UUID?,
    outcome: FinalAnswerOutcome
  ) {
    guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
          let turnID,
          let turnIndex = state.tasks[taskIndex].turns.firstIndex(where: { $0.id == turnID }) else {
      return
    }
    let raw = state.tasks[taskIndex].turns[turnIndex].assistantMessage
    let gated = ResponseQualityGate.enforce(raw, outcome: outcome)
    guard gated != raw else { return }
    state.tasks[taskIndex].turns[turnIndex].assistantMessage = gated
    state.tasks[taskIndex].turns[turnIndex].updatedAt = .now
  }

  private func synchronizeWebResearchUsage(for taskID: AgentTask.ID) {
    guard let bridgeURL = webResearchBridgeURL,
          let searchURL = URL(string: bridgeURL) else { return }
    let usageURL = searchURL.deletingLastPathComponent().appendingPathComponent("usage")
    Task { [weak self] in
      do {
        let (data, response) = try await URLSession.shared.data(from: usageURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        let snapshot = try JSONDecoder().decode(WebResearchUsageSnapshot.self, from: data)
        guard let self else { return }
        await MainActor.run {
          self.updateTask(taskID) { task in
            task.webResearchUsage = WebResearchEvidence.mergingUsage(
              task.webResearchUsage,
              snapshot: snapshot,
              sourceCount: task.webResearchSources.count
            )
          }
        }
      } catch {
        // Structured tool events remain authoritative when usage endpoint is unavailable.
      }
    }
  }

  private func validateWebResearchCitations(for taskID: AgentTask.ID) {
    guard let task = state.tasks.first(where: { $0.id == taskID }), !task.webResearchSources.isEmpty else {
      updateTask(taskID) { $0.webResearchCitationStatus = .notApplicable }
      return
    }
    let answer = WebResearchCitationVerifier.answerText(from: task.structuredEvents)
    let check = WebResearchCitationVerifier.validate(answer: answer, sources: task.webResearchSources)
    updateTask(taskID) { current in
      current.webResearchCitationStatus = check.isValid ? .verified : .needsReview
    }
    if check.isValid {
      appendEvent("联网来源引用已验证。", kind: .toolProgress, for: taskID, payload: ["matchedSources": String(check.matchedSourceCount)])
    } else {
      appendEvent("联网回答缺少可验证来源链接，请在右侧来源区审阅后再继续。", kind: .toolProgress, for: taskID, payload: ["citationReview": "required"])
    }
  }
}

private struct TaskStreamBuffers {
  var stdout = StreamingLineBuffer()
  var stderr = StreamingLineBuffer()
}

private actor StatePersistenceWriter {
  private let repository: TaskRepository

  init(fileURL: URL) {
    repository = TaskRepository(fileURL: fileURL)
  }

  func save(_ state: AppState) throws {
    try repository.save(state)
  }
}

struct Notice: Identifiable {
  enum Kind { case success, error }

  let id = UUID()
  let kind: Kind
  let text: String
}

struct PendingToolApproval: Identifiable {
  let taskID: AgentTask.ID
  let requestID: String
  let action: String
  let description: String
  let allowSession: Bool
  let fingerprint: String

  var id: String { requestID }
}

enum TerminalApprovalResponse {
  case approveOnce
  case approveForSession
  case reject
}

struct PendingTerminalApproval: Identifiable {
  let taskID: AgentTask.ID
  let commandID: UUID
  let command: String
  let risk: TerminalCommandRisk
  let reason: String
  let allowSession: Bool
  let fingerprint: String

  var id: UUID { commandID }
}

struct PendingInteractiveTerminalPaste: Identifiable {
  let tabID: UUID
  let text: String
  let data: Data

  var id: UUID { tabID }
}

enum NativeRuntimeLocator {
  static func runtimeURL() -> URL? {
    if let path = ProcessInfo.processInfo.environment["KIMI_RUNTIME_PATH"], FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    let resourceDirectories = [Bundle.main.resourceURL, Bundle.module.resourceURL].compactMap { $0 }
    return ManagedRuntimeLocator.runtimeURL(in: resourceDirectories)
  }

  static func nodePath() -> String? {
    #if arch(arm64)
    let preferredBundledNodeName = "node-arm64"
    #elseif arch(x86_64)
    let preferredBundledNodeName = "node-x64"
    #else
    let preferredBundledNodeName = "node"
    #endif
    let bundledArchitectureNode = Bundle.main.resourceURL?.appendingPathComponent(preferredBundledNodeName).path
    let bundledFallbackNode = Bundle.main.resourceURL?.appendingPathComponent("node").path
    let candidates = [bundledArchitectureNode, bundledFallbackNode, "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].compactMap { $0 }
    return ManagedRuntimeLocator.nodePath(candidates: candidates)
  }

  static func agentHostURL() -> URL? {
    if let path = ProcessInfo.processInfo.environment["KIMI_AGENT_HOST_PATH"], FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    let resourceDirectories = [Bundle.main.resourceURL, Bundle.module.resourceURL].compactMap { $0 }
    return ManagedRuntimeLocator.resourceURL(named: "agent-host.cjs", in: resourceDirectories)
  }

  static func webResearchBridgeURL() -> URL? {
    if let path = ProcessInfo.processInfo.environment["KIMI_WEB_RESEARCH_BRIDGE_PATH"], FileManager.default.fileExists(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    let resourceDirectories = [Bundle.main.resourceURL, Bundle.module.resourceURL].compactMap { $0 }
    return ManagedRuntimeLocator.resourceURL(named: "web-research-bridge.cjs", in: resourceDirectories)
  }

  static func diagnostics() -> (isReady: Bool, message: String) {
    guard let resource = runtimeURL() else {
      return (false, "尚未找到内置 Kimi Runtime。请重新构建原生安装包。")
    }
    guard let node = nodePath() else {
      return (false, "已找到 Kimi Runtime，但没有找到 Node。请设置 KIMI_NODE_PATH。")
    }
    let host = agentHostURL() == nil ? "Native Agent Host：CLI 回退模式" : "Native Agent Host：已就绪"
    return (true, "Kimi Runtime 已就绪\n\(resource.path)\nNode：\(node)\n\(host)\nWeb Search / Fetch：Swift 原生 Harness")
  }
}
