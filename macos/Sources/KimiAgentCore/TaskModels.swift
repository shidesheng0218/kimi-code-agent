import Foundation

public enum TaskStatus: String, CaseIterable, Codable, Sendable {
  case draft
  case planning
  case running
  case waitingForApproval
  case waitingForUser
  case reviewReady
  case verifying
  case mergeReady
  case merged
  case completed
  case failed
  case cancelled
  case blocked
}

public struct AgentTask: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var mode: TaskMode
  public var modelID: String?
  public var skillsDirectories: [String]
  public var status: TaskStatus
  public var workspacePath: String
  public var createdAt: Date
  public var updatedAt: Date
  public var sessionID: String?
  public var worktreePath: String?
  public var branch: String?
  public var events: [String]
  public var structuredEvents: [AgentEvent]
  public var workItems: [WorkItem]
  public var agentRuns: [AgentRun]
  public var workspaceLayout: WorkspaceLayout?
  public var ruleSet: AgentRuleSet
  public var diffSnapshot: DiffSnapshot?
  public var reviewState: DiffReviewState
  public var verificationResult: VerificationResult?
  public var browserVerificationResult: BrowserVerificationResult?
  public var failureContextPacks: [FailureContextPack]
  public var runtimeSessionID: String?
  public var webResearchSources: [WebResearchSource]
  public var webResearchUsage: WebResearchUsageRecord
  public var webResearchCitationStatus: WebResearchCitationStatus
  public var turns: [ConversationTurn]
  public var activeTurnID: UUID?
  public var terminalSession: TerminalSession?

  private enum CodingKeys: String, CodingKey {
    case id, title, mode, modelID, skillsDirectories, status, workspacePath, createdAt, updatedAt, sessionID, worktreePath, branch, events
    case structuredEvents, workItems, agentRuns, workspaceLayout, ruleSet, diffSnapshot, reviewState, verificationResult, browserVerificationResult, failureContextPacks
    case runtimeSessionID, webResearchSources, webResearchUsage, webResearchCitationStatus
    case turns, activeTurnID, terminalSession
  }

  public init(
    id: UUID = UUID(),
    title: String,
    mode: TaskMode,
    modelID: String? = nil,
    skillsDirectories: [String] = [],
    status: TaskStatus = .draft,
    workspacePath: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    sessionID: String? = nil,
    worktreePath: String? = nil,
    branch: String? = nil,
    events: [String] = [],
    structuredEvents: [AgentEvent] = [],
    workItems: [WorkItem] = [],
    agentRuns: [AgentRun] = [],
    workspaceLayout: WorkspaceLayout? = nil,
    ruleSet: AgentRuleSet = AgentRuleSet(),
    diffSnapshot: DiffSnapshot? = nil,
    reviewState: DiffReviewState = DiffReviewState(),
    verificationResult: VerificationResult? = nil,
    browserVerificationResult: BrowserVerificationResult? = nil,
    failureContextPacks: [FailureContextPack] = [],
    runtimeSessionID: String? = nil,
    webResearchSources: [WebResearchSource] = [],
    webResearchUsage: WebResearchUsageRecord = WebResearchUsageRecord(),
    webResearchCitationStatus: WebResearchCitationStatus = .notApplicable,
    turns: [ConversationTurn] = [],
    activeTurnID: UUID? = nil,
    terminalSession: TerminalSession? = nil
  ) {
    self.id = id
    self.title = title
    self.mode = mode
    self.modelID = modelID
    self.skillsDirectories = skillsDirectories
    self.status = status
    self.workspacePath = workspacePath
    self.createdAt = createdAt.roundedToMilliseconds
    self.updatedAt = updatedAt.roundedToMilliseconds
    self.sessionID = sessionID
    self.worktreePath = worktreePath
    self.branch = branch
    self.events = events
    self.structuredEvents = structuredEvents
    self.workItems = workItems
    self.agentRuns = agentRuns
    self.workspaceLayout = workspaceLayout
    self.ruleSet = ruleSet
    self.diffSnapshot = diffSnapshot
    self.reviewState = reviewState
    self.verificationResult = verificationResult
    self.browserVerificationResult = browserVerificationResult
    self.failureContextPacks = failureContextPacks
    self.runtimeSessionID = runtimeSessionID
    self.webResearchSources = webResearchSources
    self.webResearchUsage = webResearchUsage
    self.webResearchCitationStatus = webResearchCitationStatus
    self.turns = turns
    self.activeTurnID = activeTurnID
    self.terminalSession = terminalSession
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(UUID.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.mode = try container.decode(TaskMode.self, forKey: .mode)
    self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    self.skillsDirectories = try container.decodeIfPresent([String].self, forKey: .skillsDirectories) ?? []
    self.status = try container.decode(TaskStatus.self, forKey: .status)
    self.workspacePath = try container.decode(String.self, forKey: .workspacePath)
    self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    self.sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
    self.worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
    self.branch = try container.decodeIfPresent(String.self, forKey: .branch)
    self.events = try container.decodeIfPresent([String].self, forKey: .events) ?? []
    self.structuredEvents = try container.decodeIfPresent([AgentEvent].self, forKey: .structuredEvents) ?? []
    self.workItems = try container.decodeIfPresent([WorkItem].self, forKey: .workItems) ?? []
    self.agentRuns = try container.decodeIfPresent([AgentRun].self, forKey: .agentRuns) ?? []
    self.workspaceLayout = try container.decodeIfPresent(WorkspaceLayout.self, forKey: .workspaceLayout)
    self.ruleSet = try container.decodeIfPresent(AgentRuleSet.self, forKey: .ruleSet) ?? AgentRuleSet()
    self.diffSnapshot = try container.decodeIfPresent(DiffSnapshot.self, forKey: .diffSnapshot)
    self.reviewState = try container.decodeIfPresent(DiffReviewState.self, forKey: .reviewState) ?? DiffReviewState()
    self.verificationResult = try container.decodeIfPresent(VerificationResult.self, forKey: .verificationResult)
    self.browserVerificationResult = try container.decodeIfPresent(BrowserVerificationResult.self, forKey: .browserVerificationResult)
    self.failureContextPacks = try container.decodeIfPresent([FailureContextPack].self, forKey: .failureContextPacks) ?? []
    self.runtimeSessionID = try container.decodeIfPresent(String.self, forKey: .runtimeSessionID)
    self.webResearchSources = try container.decodeIfPresent([WebResearchSource].self, forKey: .webResearchSources) ?? []
    self.webResearchUsage = try container.decodeIfPresent(WebResearchUsageRecord.self, forKey: .webResearchUsage) ?? WebResearchUsageRecord()
    self.webResearchCitationStatus = try container.decodeIfPresent(WebResearchCitationStatus.self, forKey: .webResearchCitationStatus) ?? .notApplicable
    self.turns = try container.decodeIfPresent([ConversationTurn].self, forKey: .turns) ?? []
    self.activeTurnID = try container.decodeIfPresent(UUID.self, forKey: .activeTurnID)
    self.terminalSession = try container.decodeIfPresent(TerminalSession.self, forKey: .terminalSession)
  }
}

private extension Date {
  var roundedToMilliseconds: Date {
    Date(timeIntervalSince1970: (timeIntervalSince1970 * 1_000).rounded() / 1_000)
  }
}

public struct AppState: Codable, Equatable, Sendable {
  public var workspacePath: String?
  public var workspaceBookmarkData: Data?
  public var workspaceBookmarks: [String: Data]
  public var selectedTaskID: UUID?
  public var tasks: [AgentTask]
  public var terminalWorkspace: TerminalWorkspaceState

  private enum CodingKeys: String, CodingKey {
    case workspacePath
    case workspaceBookmarkData
    case workspaceBookmarks
    case selectedTaskID
    case tasks
    case terminalWorkspace
  }

  public init(
    workspacePath: String? = nil,
    workspaceBookmarkData: Data? = nil,
    workspaceBookmarks: [String: Data] = [:],
    selectedTaskID: UUID? = nil,
    tasks: [AgentTask] = [],
    terminalWorkspace: TerminalWorkspaceState = TerminalWorkspaceState()
  ) {
    self.workspacePath = workspacePath
    self.workspaceBookmarkData = workspaceBookmarkData
    self.workspaceBookmarks = workspaceBookmarks
    self.selectedTaskID = selectedTaskID
    self.tasks = tasks
    self.terminalWorkspace = terminalWorkspace
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
    self.workspaceBookmarkData = try container.decodeIfPresent(Data.self, forKey: .workspaceBookmarkData)
    self.workspaceBookmarks = try container.decodeIfPresent([String: Data].self, forKey: .workspaceBookmarks) ?? [:]
    self.selectedTaskID = try container.decodeIfPresent(UUID.self, forKey: .selectedTaskID)
    self.tasks = try container.decodeIfPresent([AgentTask].self, forKey: .tasks) ?? []
    self.terminalWorkspace = try container.decodeIfPresent(TerminalWorkspaceState.self, forKey: .terminalWorkspace) ?? TerminalWorkspaceState()
  }
}
