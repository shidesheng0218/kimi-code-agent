import Foundation

public enum ToolRisk: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
  case destructive
}

public enum ToolExecutionMode: String, Codable, CaseIterable, Sendable {
  case parallel
  case sessionSerial
  case worktreeSerial
}

public struct ToolDefinition: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let description: String
  public let permissionScopes: [PermissionScope]
  public let risk: ToolRisk
  public let executionMode: ToolExecutionMode
  public let supportsBackground: Bool
  public let timeoutSeconds: Int
  public let inputSchemaJSON: String?

  private enum CodingKeys: String, CodingKey {
    case id, title, description, permissionScopes, risk, executionMode, supportsBackground, timeoutSeconds, inputSchemaJSON
  }

  public init(
    id: String,
    title: String,
    description: String,
    permissionScopes: [PermissionScope],
    risk: ToolRisk = .low,
    executionMode: ToolExecutionMode? = nil,
    supportsBackground: Bool = false,
    timeoutSeconds: Int = 120,
    inputSchemaJSON: String? = nil
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.permissionScopes = permissionScopes
    self.risk = risk
    self.executionMode = executionMode ?? (risk == .low ? .parallel : .sessionSerial)
    self.supportsBackground = supportsBackground
    self.timeoutSeconds = timeoutSeconds
    self.inputSchemaJSON = inputSchemaJSON
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    let title = try container.decode(String.self, forKey: .title)
    let description = try container.decode(String.self, forKey: .description)
    let scopes = try container.decodeIfPresent([PermissionScope].self, forKey: .permissionScopes) ?? []
    let risk = try container.decodeIfPresent(ToolRisk.self, forKey: .risk) ?? .low
    let mode = try container.decodeIfPresent(ToolExecutionMode.self, forKey: .executionMode)
    let background = try container.decodeIfPresent(Bool.self, forKey: .supportsBackground) ?? false
    let timeout = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 120
    let schema = try container.decodeIfPresent(String.self, forKey: .inputSchemaJSON)
    self.init(id: id, title: title, description: description, permissionScopes: scopes, risk: risk, executionMode: mode, supportsBackground: background, timeoutSeconds: timeout, inputSchemaJSON: schema)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(description, forKey: .description)
    try container.encode(permissionScopes, forKey: .permissionScopes)
    try container.encode(risk, forKey: .risk)
    try container.encode(executionMode, forKey: .executionMode)
    try container.encode(supportsBackground, forKey: .supportsBackground)
    try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    try container.encodeIfPresent(inputSchemaJSON, forKey: .inputSchemaJSON)
  }
}

public enum ToolCatalog {
  public static let defaultDefinitions: [ToolDefinition] = [
    ToolDefinition(id: "read", title: "读取文件", description: "读取工作区内文件。", permissionScopes: [.readWorkspace], inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#),
    ToolDefinition(id: "search", title: "搜索代码", description: "搜索工作区文件和符号。", permissionScopes: [.readWorkspace], inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"},"path":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
    ToolDefinition(id: "write", title: "写入文件", description: "在 Worktree 中写入文件。", permissionScopes: [.writeWorkspace], risk: .medium, inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#),
    ToolDefinition(id: "shell", title: "运行命令", description: "执行受策略约束的 Shell 命令。", permissionScopes: [.executeCommand], risk: .high, inputSchemaJSON: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"}},"required":["command"],"additionalProperties":false}"#),
    ToolDefinition(id: "web.search", title: "Web Search", description: "搜索已授权网络来源。", permissionScopes: [.network], supportsBackground: true, inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
    ToolDefinition(id: "web.fetch", title: "Web Fetch", description: "抓取已授权网页正文。", permissionScopes: [.network], inputSchemaJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}"#),
    ToolDefinition(id: "WebSearch", title: "Kimi WebSearch", description: "调用 Kimi Runtime 原生搜索工具。", permissionScopes: [.network]),
    ToolDefinition(id: "FetchURL", title: "Kimi FetchURL", description: "调用 Kimi Runtime 原生抓取工具。", permissionScopes: [.network]),
    ToolDefinition(id: "network.fetch", title: "Network Fetch", description: "通过受控网络网关抓取内容。", permissionScopes: [.network]),
    ToolDefinition(id: "browser", title: "浏览器验证", description: "打开并验证本地网页，支持计划、定位、点击、输入和截图。", permissionScopes: [.browser], risk: .medium, executionMode: .sessionSerial, supportsBackground: true, inputSchemaJSON: #"{"type":"object","properties":{"plan":{"type":"string"},"action":{"type":"string","enum":["open","navigate","inspect","click","typeText","pressKey","scroll","screenshot","collectConsole","collectNetwork"]},"url":{"type":"string"},"selector":{"type":"string"},"text":{"type":"string"},"key":{"type":"string"}},"additionalProperties":true}"#),
    ToolDefinition(id: "computer_use.inspect", title: "Computer Use Inspect", description: "读取当前屏幕和窗口状态。", permissionScopes: [.systemComputerUse], risk: .medium),
    ToolDefinition(id: "computer_use.screenshot", title: "Computer Use Screenshot", description: "保存当前屏幕截图作为可审阅产物。", permissionScopes: [.systemComputerUse], risk: .medium),
    ToolDefinition(id: "computer_use.click", title: "Computer Use Click", description: "执行已审批的屏幕点击。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "computer_use.click_element", title: "Computer Use Click Element", description: "按识别元素执行点击。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "computer_use.type_text", title: "Computer Use Type", description: "向已授权目标输入文本。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "computer_use.press_key", title: "Computer Use Key", description: "向已授权目标发送按键。", permissionScopes: [.systemComputerUse], risk: .high),
    ToolDefinition(id: "github.pull_request.create", title: "Create Pull Request", description: "创建 GitHub Pull Request。", permissionScopes: [.network], risk: .high),
    ToolDefinition(id: "task", title: "Subagent", description: "创建独立子 Agent 会话。", permissionScopes: [.readWorkspace], supportsBackground: true),
    ToolDefinition(id: "mcp", title: "MCP Tool", description: "调用已授权 MCP 工具。", permissionScopes: [.network], risk: .medium)
  ]
}

public actor ToolRegistry {
  private var definitions: [String: ToolDefinition]
  private var executors: [String: any ToolExecutor] = [:]

  public init(definitions: [ToolDefinition] = ToolCatalog.defaultDefinitions) {
    self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
  }

  public func register(_ definition: ToolDefinition) {
    definitions[definition.id] = definition
  }

  public func register(_ definition: ToolDefinition, executor: any ToolExecutor) {
    definitions[definition.id] = definition
    executors[definition.id] = executor
  }

  public func remove(id: String) {
    definitions.removeValue(forKey: id)
    executors.removeValue(forKey: id)
  }

  public func all() -> [ToolDefinition] {
    definitions.values.sorted { $0.id < $1.id }
  }

  public func availableTools(for agent: AgentDefinition) -> [ToolDefinition] {
    let allowed = Set(agent.allowedTools)
    let denied = Set(agent.deniedTools)
    return definitions.values
      .filter { definition in
        guard !denied.contains(definition.id) else { return false }
        if allowed.isEmpty { return agent.permissionMode != .readOnly || definition.permissionScopes.allSatisfy { $0 == .readWorkspace } }
        return allowed.contains(definition.id)
      }
      .sorted { $0.id < $1.id }
  }

  public func definition(id: String) -> ToolDefinition? {
    definitions[id]
  }

  public func executor(id: String) -> (any ToolExecutor)? {
    executors[id]
  }
}

public struct ToolExecutionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID
  public let sessionID: UUID
  public let operationID: UUID?
  public let agentID: String
  public let toolID: String
  public let input: [String: String]
  public let resource: String?
  public let command: String?

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    sessionID: UUID,
    operationID: UUID? = nil,
    agentID: String,
    toolID: String,
    input: [String: String] = [:],
    resource: String? = nil,
    command: String? = nil
  ) {
    self.id = id
    self.taskID = taskID
    self.sessionID = sessionID
    self.operationID = operationID
    self.agentID = agentID
    self.toolID = toolID
    self.input = input
    self.resource = resource
    self.command = command
  }
}

public struct ToolExecutionResult: Codable, Equatable, Sendable {
  public let output: String
  public let metadata: [String: String]
  public let exitCode: Int32?

  public init(output: String, metadata: [String: String] = [:], exitCode: Int32? = nil) {
    self.output = output
    self.metadata = metadata
    self.exitCode = exitCode
  }
}

public protocol ToolExecutor: Sendable {
  func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult
}

/// Explicit, test-only effect boundaries used to prove that recovery never
/// invents a receipt after a process crash. Production code leaves the
/// injector unset; tests can interrupt exactly one durable transition.
public enum HarnessEffectBoundary: String, CaseIterable, Sendable {
  case afterPermission
  case afterIntent
  case afterStarted
  case beforeSettled
}

public struct HarnessInjectedCrash: LocalizedError, Equatable, Sendable {
  public let boundary: HarnessEffectBoundary

  public init(boundary: HarnessEffectBoundary) {
    self.boundary = boundary
  }

  public var errorDescription: String? {
    "故障注入：在 \(boundary.rawValue) 中断"
  }
}

public actor HarnessFaultInjector {
  private var failures: [HarnessEffectBoundary: Int]

  public init(failures: [HarnessEffectBoundary: Int] = [:]) {
    self.failures = failures.mapValues { max(0, $0) }
  }

  public func hit(_ boundary: HarnessEffectBoundary) throws {
    guard let remaining = failures[boundary], remaining > 0 else { return }
    failures[boundary] = remaining - 1
    throw HarnessInjectedCrash(boundary: boundary)
  }
}

public actor ToolEffectJournal {
  private let store: HarnessEventStore
  private let sessionID: UUID
  private let lane: LaneID
  private let eventSink: (@Sendable (HarnessDriverEvent) async -> Void)?

  public init(
    store: HarnessEventStore,
    sessionID: UUID,
    lane: LaneID,
    eventSink: (@Sendable (HarnessDriverEvent) async -> Void)? = nil
  ) {
    self.store = store
    self.sessionID = sessionID
    self.lane = lane
    self.eventSink = eventSink
  }

  @discardableResult
  public func writeIntent(request: ToolExecutionRequest, definition: ToolDefinition) async throws -> HarnessEffectIntent? {
    guard let operationID = request.operationID else { return nil }
    let intent = HarnessEffectIntent(
      operationID: operationID,
      kind: .tool,
      subject: request.toolID,
      risk: definition.risk,
      idempotencyKey: request.id.uuidString
    )
    if let eventSink {
      // AgentHarness is the single durable writer in native mode. Publishing
      // through the sink preserves ordering with operation state and avoids a
      // duplicate intent in recovery logs.
      await eventSink(.effectIntentWritten(intent))
    } else {
      _ = try await store.append(HarnessEvent(
        sessionID: sessionID,
        operationID: operationID,
        lane: lane,
        sequence: 0,
        kind: .effectIntentWritten,
        payload: try? JSONEncoder().encode(intent)
      ))
    }
    return intent
  }

  public func writeStarted(_ intent: HarnessEffectIntent) async throws {
    if let eventSink {
      await eventSink(.effectStarted(intent))
    } else {
      _ = try await store.append(HarnessEvent(
        sessionID: sessionID,
        operationID: intent.operationID,
        lane: lane,
        sequence: 0,
        kind: .effectStarted,
        payload: try? JSONEncoder().encode(intent)
      ))
    }
  }

  public func writePermission(request: ToolExecutionRequest, decision: PermissionDecision) async throws {
    guard let operationID = request.operationID else { return }
    let receipt = HarnessPermissionReceipt(
      operationID: operationID,
      requestID: request.id,
      toolID: request.toolID,
      decision: decision
    )
    if let eventSink {
      await eventSink(.permissionSettled(receipt))
    } else {
      _ = try await store.append(HarnessEvent(
        sessionID: sessionID,
        operationID: operationID,
        lane: lane,
        sequence: 0,
        kind: .permissionSettled,
        payload: try? JSONEncoder().encode(receipt)
      ))
    }
  }

  public func writeSettled(_ receipt: HarnessEffectReceipt) async throws {
    if let eventSink {
      await eventSink(.effectSettled(receipt))
    } else {
      _ = try await store.append(HarnessEvent(
        sessionID: sessionID,
        operationID: receipt.operationID,
        lane: lane,
        sequence: 0,
        kind: .effectSettled,
        payload: try? JSONEncoder().encode(receipt)
      ))
    }
  }

  /// Finds a prior successful receipt for the same durable Tool request. This
  /// survives process restart because it reads the append-only event store.
  public func successfulReceipt(for request: ToolExecutionRequest) async -> HarnessEffectReceipt? {
    guard let operationID = request.operationID else { return nil }
    let events = await store.events(operationID: operationID)
    var matchingEffectID: UUID?
    for event in events where event.kind == .effectIntentWritten {
      guard let payload = event.payload,
            let intent = try? JSONDecoder().decode(HarnessEffectIntent.self, from: payload),
            intent.idempotencyKey == request.id.uuidString else { continue }
      matchingEffectID = intent.effectID
    }
    guard let matchingEffectID else { return nil }
    for event in events.reversed() where event.kind == .effectSettled {
      guard let payload = event.payload,
            let receipt = try? JSONDecoder().decode(HarnessEffectReceipt.self, from: payload),
            receipt.effectID == matchingEffectID,
            receipt.outcome == .success else { continue }
      return receipt
    }
    return nil
  }
}

public struct ClosureToolExecutor: ToolExecutor {
  public typealias Handler = @Sendable (ToolExecutionRequest) async throws -> ToolExecutionResult
  private let handler: Handler

  public init(_ handler: @escaping Handler) {
    self.handler = handler
  }

  public func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    try await handler(request)
  }

}

private extension Array where Element == ToolExecutionRequest {
  func asyncAllSatisfy(_ predicate: @escaping @Sendable (Element) async -> Bool) async -> Bool {
    for element in self where !(await predicate(element)) { return false }
    return true
  }
}

public protocol ToolPermissionResolver: Sendable {
  func resolve(request: ToolExecutionRequest, definition: ToolDefinition) async -> PermissionDecision
}

public struct CapabilityToolPermissionResolver: ToolPermissionResolver, Sendable {
  public let grants: [CapabilityGrant]
  public let defaultDecision: PermissionDecision

  public init(grants: [CapabilityGrant], defaultDecision: PermissionDecision = .ask) {
    self.grants = grants
    self.defaultDecision = defaultDecision
  }

  public func resolve(request: ToolExecutionRequest, definition: ToolDefinition) async -> PermissionDecision {
    let subjectIDs = Set([request.taskID, request.sessionID])
    let candidateResource = request.resource ?? ""
    let requiredActions = definition.permissionScopes.map(Self.action(for:))
    guard !requiredActions.isEmpty else { return .allow }
    let granted = requiredActions.allSatisfy { action in
      grants.contains { grant in
        subjectIDs.contains(grant.subjectID) && grant.allows(
          action: action,
          resource: candidateResource.isEmpty ? grant.resource : candidateResource,
          subjectID: grant.subjectID
        )
      }
    }
    return granted ? .allow : defaultDecision
  }

  private static func action(for scope: PermissionScope) -> CapabilityAction {
    switch scope {
    case .readWorkspace: .read
    case .writeWorkspace: .write
    case .executeCommand: .execute
    case .network: .network
    case .browser: .browser
    case .systemComputerUse: .computerUse
    case .destructiveOperation: .destructive
    }
  }
}

public struct StaticToolPermissionResolver: ToolPermissionResolver {
  public let decision: PermissionDecision

  public init(decision: PermissionDecision) {
    self.decision = decision
  }

  public func resolve(request: ToolExecutionRequest, definition: ToolDefinition) async -> PermissionDecision {
    decision
  }
}

/// Permission resolver used by isolated Child Agents.  Read-only agents may
/// inspect the workspace (and inspect-only specialized adapters) without
/// interrupting the user for every individual call.  Anything that can mutate
/// files, run commands, access the network, or control the system keeps the
/// normal approval path.  This keeps the child permission strictly narrower
/// than the parent session while avoiding the repeated `search` prompt that
/// otherwise makes Explore/Browser runs unusable.
public struct ChildAgentToolPermissionResolver: ToolPermissionResolver, Sendable {
  public let definition: AgentDefinition
  public let fallbackDecision: PermissionDecision

  public init(definition: AgentDefinition, fallbackDecision: PermissionDecision = .ask) {
    self.definition = definition
    self.fallbackDecision = fallbackDecision
  }

  public func resolve(request: ToolExecutionRequest, definition tool: ToolDefinition) async -> PermissionDecision {
    guard !definition.deniedTools.contains(tool.id) else { return .deny }

    switch definition.permissionMode {
    case .readOnly:
      // Workspace inspection is intrinsically read-only and is safe to reuse
      // for the lifetime of the child session.
      if tool.id == "read" || tool.id == "search" || tool.id == "diff" {
        return tool.permissionScopes.allSatisfy { $0 == .readWorkspace } ? .allow : fallbackDecision
      }

      // Browser and Computer Use inspection/screenshot calls do not mutate
      // the target.  Navigation to an explicitly requested URL is still
      // checked by the adapter's domain policy; clicks, typing and key presses
      // never qualify here.
      if definition.kind == .browser || definition.kind == .browserVerification || definition.kind == .computerUse {
        if tool.id == "computer_use.inspect" || tool.id == "computer_use.screenshot" {
          return .allow
        }
        if tool.id == "browser" {
          let action = (request.input["action"] ?? "inspect").lowercased()
          let safeActions: Set<String> = ["open", "navigate", "inspect", "screenshot", "collectconsole", "collectnetwork"]
          return safeActions.contains(action) ? .allow : fallbackDecision
        }
      }
      return fallbackDecision

    case .interactive, .automatic:
      if definition.kind == .webResearch {
        // A user explicitly asked for research. Search and HTTPS fetch are
        // read-only effects; the parent task still records the domain and
        // receipt, while writes, shell and other side effects remain gated.
        if tool.id == "web.search" || tool.id == "web_search" || tool.id == "websearch" {
          return .allow
        }
        if tool.id == "web.fetch" || tool.id == "web_fetch" || tool.id == "network.fetch" || tool.id == "fetchurl" {
          let rawURL = ["url", "href", "uri", "link", "sourceid", "source_id"]
            .compactMap { request.input[$0] }
            .first { raw in
              guard let scheme = URL(string: raw)?.scheme?.lowercased() else { return false }
              return scheme == "http" || scheme == "https"
            }
          return rawURL == nil ? fallbackDecision : .allow
        }
      }
      // Browser/Computer Use read operations are safe even when the agent may
      // also perform interactive actions.  Keep mutating actions on approval.
      if definition.kind == .browser || definition.kind == .browserVerification || definition.kind == .computerUse {
        if tool.id == "computer_use.inspect" || tool.id == "computer_use.screenshot" {
          return .allow
        }
        if tool.id == "browser" {
          let action = (request.input["action"] ?? "inspect").lowercased()
          let safeActions: Set<String> = ["open", "navigate", "inspect", "screenshot", "collectconsole", "collectnetwork"]
          return safeActions.contains(action) ? .allow : fallbackDecision
        }
      }
      return fallbackDecision
    }
  }
}

public enum ToolExecutionError: LocalizedError, Equatable {
  case unknownTool(String)
  case missingExecutor(String)
  case denied(String)
  case approvalRequired(String)
  case nonZeroExit(String, Int32)

  public var errorDescription: String? {
    switch self {
    case let .unknownTool(id): "未注册工具：\(id)"
    case let .missingExecutor(id): "工具尚未绑定执行器：\(id)"
    case let .denied(id): "权限策略拒绝了工具：\(id)"
    case let .approvalRequired(id): "工具需要用户审批：\(id)"
    case let .nonZeroExit(output, exitCode): "工具执行失败（exit \(exitCode)）：\(output)"
    }
  }
}

/// The common execution gate for native tools, MCP tools, and plugin tools.
/// It keeps tool availability, permission decisions, and execution result
/// handling on one path instead of letting each UI controller bypass policy.
public actor ToolExecutionCoordinator {
  public typealias ApprovalHandler = @Sendable (ToolExecutionRequest, ToolDefinition) async -> PermissionDecision
  public typealias HookResolver = @Sendable (HarnessHookRequest) async -> HarnessHookResolution?

  private let registry: ToolRegistry
  private let permissionResolver: any ToolPermissionResolver
  private let approvalHandler: ApprovalHandler?
  private let hookResolver: HookResolver?
  private let journal: ToolEffectJournal?
  private let faultInjector: HarnessFaultInjector?

  public init(
    registry: ToolRegistry,
    permissionResolver: any ToolPermissionResolver,
    approvalHandler: ApprovalHandler? = nil,
    hookResolver: HookResolver? = nil,
    journal: ToolEffectJournal? = nil,
    faultInjector: HarnessFaultInjector? = nil
  ) {
    self.registry = registry
    self.permissionResolver = permissionResolver
    self.approvalHandler = approvalHandler
    self.hookResolver = hookResolver
    self.journal = journal
    self.faultInjector = faultInjector
  }

  public func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    guard let definition = await registry.definition(id: request.toolID) else {
      throw ToolExecutionError.unknownTool(request.toolID)
    }
    guard let executor = await registry.executor(id: request.toolID) else {
      throw ToolExecutionError.missingExecutor(request.toolID)
    }

    var effectiveRequest = request
    if let hookResolver,
       let resolution = await hookResolver(HarnessHookRequest(event: .beforeTool, toolID: request.toolID, arguments: request.input)) {
      guard resolution.isAllowed else {
        throw ToolExecutionError.denied(resolution.denialReason ?? request.toolID)
      }
      effectiveRequest = ToolExecutionRequest(
        id: request.id,
        taskID: request.taskID,
        sessionID: request.sessionID,
        operationID: request.operationID,
        agentID: request.agentID,
        toolID: request.toolID,
        input: resolution.arguments,
        resource: resolution.arguments["path"] ?? resolution.arguments["url"] ?? request.resource,
        command: resolution.arguments["command"] ?? request.command
      )
    }

    if let receipt = await journal?.successfulReceipt(for: effectiveRequest) {
      return ToolExecutionResult(
        output: receipt.output ?? "",
        metadata: ["replayed": "true", "effectID": receipt.effectID.uuidString]
      )
    }

    let initialDecision = await permissionResolver.resolve(request: effectiveRequest, definition: definition)
    let finalDecision: PermissionDecision
    switch initialDecision {
    case .deny:
      finalDecision = .deny
    case .ask:
      guard let approvalHandler else {
        try await journal?.writePermission(request: effectiveRequest, decision: .ask)
        throw ToolExecutionError.approvalRequired(request.toolID)
      }
      finalDecision = await approvalHandler(effectiveRequest, definition)
    case .allow:
      finalDecision = .allow
    }
    try await journal?.writePermission(request: effectiveRequest, decision: finalDecision)
    guard finalDecision == .allow else {
      throw ToolExecutionError.denied(request.toolID)
    }
    try await faultInjector?.hit(.afterPermission)
    let intent = try await journal?.writeIntent(request: effectiveRequest, definition: definition)
    try await faultInjector?.hit(.afterIntent)
    if let intent { try await journal?.writeStarted(intent) }
    try await faultInjector?.hit(.afterStarted)
    var didSettle = false
    do {
      let result = try await executor.execute(effectiveRequest)
      try await faultInjector?.hit(.beforeSettled)
      if let exitCode = result.exitCode, exitCode != 0 {
        if let intent {
          try await journal?.writeSettled(HarnessEffectReceipt(
            operationID: intent.operationID,
            effectID: intent.effectID,
            outcome: .failure,
            output: result.output,
            errorMessage: "exit \(exitCode)"
          ))
          didSettle = true
        }
        throw ToolExecutionError.nonZeroExit(result.output, exitCode)
      }
      if let intent {
        try await journal?.writeSettled(HarnessEffectReceipt(
          operationID: intent.operationID,
          effectID: intent.effectID,
          outcome: .success,
          output: result.output
        ))
        didSettle = true
      }
      return result
    } catch {
      // A fault injector represents an abrupt process loss. Persisting a
      // synthetic failure receipt here would mask the exact unknown-effect
      // state that the recovery engine must be able to reason about.
      if error is HarnessInjectedCrash { throw error }
      if let intent, !didSettle {
        try? await journal?.writeSettled(HarnessEffectReceipt(
          operationID: intent.operationID,
          effectID: intent.effectID,
          outcome: error is CancellationError ? .cancelled : .failure,
          errorMessage: error.localizedDescription
        ))
      }
      throw error
    }
  }

  /// Executes a model tool batch while preserving source order. Purely
  /// parallel tools may overlap; any serial tool makes the batch conservative
  /// and sequential so writes, terminals, and browser actions cannot race.
  public func executeBatch(_ requests: [ToolExecutionRequest]) async -> [Result<ToolExecutionResult, Error>] {
    guard !requests.isEmpty else { return [] }
    let canParallel = await requests.asyncAllSatisfy { request in
      guard let definition = await self.registry.definition(id: request.toolID) else { return false }
      return definition.executionMode == .parallel
    }
    if !canParallel {
      var results: [Result<ToolExecutionResult, Error>] = []
      for request in requests {
        do { results.append(.success(try await execute(request))) }
        catch { results.append(.failure(error)) }
      }
      return results
    }
    return await withTaskGroup(of: (Int, Result<ToolExecutionResult, Error>).self, returning: [Result<ToolExecutionResult, Error>].self) { group in
      for (index, request) in requests.enumerated() {
        group.addTask {
          do { return (index, .success(try await self.execute(request))) }
          catch { return (index, .failure(error)) }
        }
      }
      var collected = Array(repeating: Result<ToolExecutionResult, Error>.failure(ToolExecutionError.denied("未执行")), count: requests.count)
      for await (index, result) in group { collected[index] = result }
      return collected
    }
  }
}
