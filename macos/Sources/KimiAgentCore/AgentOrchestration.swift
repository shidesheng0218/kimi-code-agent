import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
  case explore
  case plan
  case implement
  case test
  case review
  case webResearch
  case browser
  case browserVerification
  case computerUse
  case debug

  public var title: String {
    switch self {
    case .explore: "Explore"
    case .plan: "Plan"
    case .implement: "Implement"
    case .test: "Test"
    case .review: "Review"
    case .webResearch: "Web Research"
    case .browser: "Browser"
    case .browserVerification: "Browser"
    case .computerUse: "Computer Use"
    case .debug: "Debug"
    }
  }
}

public enum AgentPermissionMode: String, Codable, CaseIterable, Sendable {
  case readOnly
  case interactive
  case automatic
}

public enum AgentIsolation: String, Codable, CaseIterable, Sendable {
  case sharedWorkspace
  case worktree
  case readOnlySnapshot
}

public enum AgentRunState: String, Codable, CaseIterable, Sendable {
  case queued
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
    case .queued, .running, .paused, .awaitingApproval, .interrupted: false
    }
  }
}

public struct AgentDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let description: String
  public let kind: AgentKind
  public let model: String?
  public let allowedTools: [String]
  public let deniedTools: [String]
  public let permissionMode: AgentPermissionMode
  public let skills: [String]
  public let mcpServers: [String]
  public let hooks: [String]
  public let isolation: AgentIsolation
  public let maxTurns: Int?

  public init(
    name: String,
    description: String,
    kind: AgentKind,
    model: String? = nil,
    allowedTools: [String] = [],
    deniedTools: [String] = [],
    permissionMode: AgentPermissionMode = .interactive,
    skills: [String] = [],
    mcpServers: [String] = [],
    hooks: [String] = [],
    isolation: AgentIsolation = .readOnlySnapshot,
    maxTurns: Int? = nil
  ) {
    self.name = name
    self.description = description
    self.kind = kind
    self.model = model
    self.allowedTools = allowedTools
    self.deniedTools = deniedTools
    self.permissionMode = permissionMode
    self.skills = skills
    self.mcpServers = mcpServers
    self.hooks = hooks
    self.isolation = isolation
    self.maxTurns = maxTurns
  }
}

public enum AgentResultStatus: String, Codable, CaseIterable, Sendable {
  case completed
  case partial
  case failed
}

public struct AgentEvidence: Codable, Equatable, Sendable {
  public let label: String
  public let value: String
  public let source: String?

  public init(label: String, value: String, source: String? = nil) {
    self.label = label
    self.value = value
    self.source = source
  }
}

public struct AgentResult: Codable, Equatable, Sendable {
  public let summary: String
  public let artifactIDs: [String]
  public let receiptIDs: [UUID]
  public let nextActions: [String]
  public let status: AgentResultStatus
  public let evidence: [AgentEvidence]
  public let verification: [String]
  public let confidence: Double

  public init(
    summary: String,
    artifactIDs: [String] = [],
    receiptIDs: [UUID] = [],
    nextActions: [String] = [],
    status: AgentResultStatus = .completed,
    evidence: [AgentEvidence] = [],
    verification: [String] = [],
    confidence: Double = 1
  ) {
    self.summary = summary
    self.artifactIDs = artifactIDs
    self.receiptIDs = receiptIDs
    self.nextActions = nextActions
    self.status = status
    self.evidence = evidence
    self.verification = verification
    self.confidence = min(max(confidence, 0), 1)
  }

  private enum CodingKeys: String, CodingKey {
    case summary, artifactIDs, receiptIDs, nextActions, status, evidence, verification, confidence
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      summary: try container.decode(String.self, forKey: .summary),
      artifactIDs: try container.decodeIfPresent([String].self, forKey: .artifactIDs) ?? [],
      receiptIDs: try container.decodeIfPresent([UUID].self, forKey: .receiptIDs) ?? [],
      nextActions: try container.decodeIfPresent([String].self, forKey: .nextActions) ?? [],
      status: try container.decodeIfPresent(AgentResultStatus.self, forKey: .status) ?? .completed,
      evidence: try container.decodeIfPresent([AgentEvidence].self, forKey: .evidence) ?? [],
      verification: try container.decodeIfPresent([String].self, forKey: .verification) ?? [],
      confidence: try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
    )
  }
}

public struct AgentRun: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let parentSessionID: UUID
  public let taskID: UUID
  public let definition: AgentDefinition
  public var dependencies: [UUID]
  public var childSessionID: UUID?
  public var worktreePath: String?
  public var state: AgentRunState
  public var progress: Double
  public var result: AgentResult?
  public var errorMessage: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    parentSessionID: UUID,
    taskID: UUID,
    definition: AgentDefinition,
    dependencies: [UUID] = [],
    childSessionID: UUID? = nil,
    worktreePath: String? = nil,
    state: AgentRunState = .queued,
    progress: Double = 0,
    result: AgentResult? = nil,
    errorMessage: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.parentSessionID = parentSessionID
    self.taskID = taskID
    self.definition = definition
    self.dependencies = dependencies
    self.childSessionID = childSessionID
    self.worktreePath = worktreePath
    self.state = state
    self.progress = min(max(progress, 0), 1)
    self.result = result
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct AgentOrchestrationPlan: Codable, Equatable, Sendable {
  public let taskID: UUID
  public let sessionID: UUID
  public var runs: [AgentRun]

  public init(taskID: UUID, sessionID: UUID, runs: [AgentRun]) {
    self.taskID = taskID
    self.sessionID = sessionID
    self.runs = runs
  }
}

public enum AgentOrchestrator {
  public static func makePlan(
    taskID: UUID,
    mode: TaskMode,
    sessionID: UUID = UUID(),
    model: String? = nil,
    customDefinitions: [AgentDefinition] = []
  ) -> AgentOrchestrationPlan {
    let explore = makeRun(taskID: taskID, sessionID: sessionID, kind: .explore, model: model)
    let plan = makeRun(taskID: taskID, sessionID: sessionID, kind: .plan, model: model, dependencies: [explore.id])

    guard !mode.isReadOnly else {
      let review = makeRun(taskID: taskID, sessionID: sessionID, kind: .review, model: model, dependencies: [plan.id])
      let customRuns = customDefinitions.map {
        AgentRun(parentSessionID: sessionID, taskID: taskID, definition: $0, dependencies: [plan.id])
      }
      return AgentOrchestrationPlan(taskID: taskID, sessionID: sessionID, runs: [explore, plan, review] + customRuns)
    }

    let implement = makeRun(taskID: taskID, sessionID: sessionID, kind: .implement, model: model, dependencies: [plan.id])
    let test = makeRun(taskID: taskID, sessionID: sessionID, kind: .test, model: model, dependencies: [implement.id])
    let review = makeRun(taskID: taskID, sessionID: sessionID, kind: .review, model: model, dependencies: [implement.id, test.id])
    let customRuns = customDefinitions.map { definition in
      let dependency = definition.isolation == .worktree ? implement.id : plan.id
      return AgentRun(parentSessionID: sessionID, taskID: taskID, definition: definition, dependencies: [dependency])
    }
    return AgentOrchestrationPlan(taskID: taskID, sessionID: sessionID, runs: [explore, plan, implement, test, review] + customRuns)
  }

  public static func readyRuns(in runs: [AgentRun], maxConcurrent: Int = 8) -> [AgentRun] {
    let completedIDs = Set(runs.filter { $0.state == .completed }.map(\.id))
    let runningCount = runs.filter { $0.state == .running || $0.state == .awaitingApproval }.count
    let available = max(0, min(maxConcurrent, 8) - runningCount)
    guard available > 0 else { return [] }
    return runs
      .filter { $0.state == .queued && Set($0.dependencies).isSubset(of: completedIDs) }
      .prefix(available)
      .map { $0 }
  }

  private static func makeRun(
    taskID: UUID,
    sessionID: UUID,
    kind: AgentKind,
    model: String?,
    dependencies: [UUID] = []
  ) -> AgentRun {
    AgentRun(
      parentSessionID: sessionID,
      taskID: taskID,
      definition: builtInDefinition(for: kind, model: model),
      dependencies: dependencies
    )
  }

  public static func builtInDefinition(for kind: AgentKind, model: String? = nil) -> AgentDefinition {
    switch kind {
    case .explore:
      AgentDefinition(name: "explore", description: "定位代码、依赖与风险。", kind: kind, model: model, allowedTools: ["read", "search"], permissionMode: .readOnly, isolation: .readOnlySnapshot)
    case .plan:
      AgentDefinition(name: "plan", description: "将目标拆成可验证的执行计划。", kind: kind, model: model, allowedTools: ["read", "search"], permissionMode: .readOnly, isolation: .readOnlySnapshot)
    case .implement:
      AgentDefinition(name: "implement", description: "在独立 Worktree 中实现变更。", kind: kind, model: model, allowedTools: ["read", "write", "shell"], permissionMode: .interactive, isolation: .worktree)
    case .test:
      AgentDefinition(name: "test", description: "运行真实测试、构建和验证。", kind: kind, model: model, allowedTools: ["read", "shell", "browser"], permissionMode: .interactive, isolation: .worktree)
    case .review:
      AgentDefinition(name: "review", description: "审查 Diff、安全和回归风险。", kind: kind, model: model, allowedTools: ["read", "diff"], permissionMode: .readOnly, isolation: .readOnlySnapshot)
    case .webResearch:
      AgentDefinition(
        name: "web-research",
        description: "搜索并抓取授权来源，整理可验证引用。",
        kind: kind,
        model: model,
        allowedTools: ["web.search", "web.fetch"],
        permissionMode: .interactive,
        isolation: .sharedWorkspace
      )
    case .browser:
      AgentDefinition(
        name: "browser",
        description: "验证网页行为、控制台和截图，也可执行受审批保护的 Computer Use 操作。",
        kind: kind,
        model: model,
        allowedTools: [
          "browser",
          "computer_use.inspect",
          "computer_use.screenshot",
          "computer_use.click",
          "computer_use.click_element",
          "computer_use.type_text",
          "computer_use.press_key"
        ],
        permissionMode: .interactive,
        isolation: .worktree
      )
    case .browserVerification:
      AgentDefinition(
        name: "browser-verification",
        description: "执行只读网页验证、DOM 检查和截图。",
        kind: kind,
        model: model,
        allowedTools: ["browser"],
        permissionMode: .interactive,
        isolation: .sharedWorkspace
      )
    case .computerUse:
      AgentDefinition(
        name: "computer-use",
        description: "读取当前桌面和窗口状态；高风险操作逐次审批。",
        kind: kind,
        model: model,
        allowedTools: ["computer_use.inspect", "computer_use.screenshot", "computer_use.click", "computer_use.click_element", "computer_use.type_text", "computer_use.press_key"],
        permissionMode: .interactive,
        isolation: .sharedWorkspace
      )
    case .debug:
      AgentDefinition(name: "debug", description: "根据失败上下文修复问题。", kind: kind, model: model, allowedTools: ["read", "write", "shell"], permissionMode: .interactive, isolation: .worktree)
    }
  }
}

public enum AgentDefinitionRegistry {
  public static func discover(projectDirectory: URL, fileManager: FileManager = .default) -> [AgentDefinition] {
    let directories = [
      projectDirectory.appendingPathComponent(".kimi-agent/agents", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi/agents", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi-agent/plugins", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi/plugins", isDirectory: true)
    ]
    var definitions: [AgentDefinition] = []
    for directory in directories {
      guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { continue }
      let files = enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == "json" && $0.deletingLastPathComponent().lastPathComponent == "agents" }
      definitions.append(contentsOf: files.compactMap { url in
          guard let data = try? Data(contentsOf: url) else { return nil }
          return try? JSONDecoder().decode(AgentDefinition.self, from: data)
        })
    }
    return definitions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}
