import Foundation

/// Commands emitted by the native SwiftUI shell. This deliberately uses a
/// distinct name from the legacy `KimiCommand` process-launch value type.
public enum KimiAppCommand: Sendable, Equatable {
  case createSession
  case selectSession(UUID)
  case prompt(PromptInput)
  case steer(PromptInput)
  case followUp(PromptInput)
  case abort(OperationID)
  case approve(UUID)
  case deny(UUID)
  case retry(OperationID)
  case resume(OperationID)
  case openTerminal(UUID)
  case openDiff(UUID)
  case openBrowser(UUID)
  case openFile(String)
  case changeModel(String)
  case restartRuntime

  public enum Kind: String, Codable, Sendable {
    case createSession
    case selectSession
    case prompt
    case steer
    case followUp
    case abort
    case approve
    case deny
    case retry
    case resume
    case openTerminal
    case openDiff
    case openBrowser
    case openFile
    case changeModel
    case restartRuntime
  }

  public var kind: Kind {
    switch self {
    case .createSession: .createSession
    case .selectSession: .selectSession
    case .prompt: .prompt
    case .steer: .steer
    case .followUp: .followUp
    case .abort: .abort
    case .approve: .approve
    case .deny: .deny
    case .retry: .retry
    case .resume: .resume
    case .openTerminal: .openTerminal
    case .openDiff: .openDiff
    case .openBrowser: .openBrowser
    case .openFile: .openFile
    case .changeModel: .changeModel
    case .restartRuntime: .restartRuntime
    }
  }
}

public enum KimiActivePane: String, Codable, Sendable {
  case conversation
  case diff
  case browser
  case files
  case verification
  case integrations
}

public enum KimiTerminalPlacement: String, Codable, Sendable {
  case right
}

public enum KimiRuntimeState: String, Codable, Sendable {
  case stopped
  case starting
  case ready
  case degraded
  case stopping
  case failed
}

public struct KimiSessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  /// The engine uses string IDs such as `ses_...`; the UUID remains the local
  /// stable identity used by SwiftUI's ForEach and Harness records.
  public let runtimeID: String?
  public var title: String
  public var projectPath: String?
  public var status: SessionStatus
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    runtimeID: String? = nil,
    title: String = "新会话",
    projectPath: String? = nil,
    status: SessionStatus = .idle,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.runtimeID = runtimeID
    self.title = title
    self.projectPath = projectPath
    self.status = status
    self.updatedAt = updatedAt
  }
}

public enum KimiMessageRole: String, Codable, Sendable {
  case user
  case assistant
  case system
  case tool
}

public struct KimiMessage: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let role: KimiMessageRole
  public var text: String
  public var isStreaming: Bool
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    role: KimiMessageRole,
    text: String,
    isStreaming: Bool = false,
    createdAt: Date = .now
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
    self.createdAt = createdAt
  }
}

public enum KimiActivityState: String, Codable, Sendable {
  case queued
  case running
  case awaitingPermission
  case completed
  case failed
  case cancelled
}

public struct KimiActivity: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public var detail: String?
  public var state: KimiActivityState
  public var toolCallID: String?
  public var effectID: UUID?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    detail: String? = nil,
    state: KimiActivityState = .queued,
    toolCallID: String? = nil,
    effectID: UUID? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.state = state
    self.toolCallID = toolCallID
    self.effectID = effectID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct KimiPermissionRequest: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  /// Opaque engine permission request identifier. The Swift UUID is used
  /// for stable SwiftUI identity only; this value is what must be sent back to
  /// the headless server when the user approves or rejects the request.
  public let runtimeID: String?
  public let toolID: String
  public let reason: String
  public let patterns: [String]
  public let createdAt: Date

  public init(id: UUID = UUID(), runtimeID: String? = nil, toolID: String, reason: String, patterns: [String] = [], createdAt: Date = .now) {
    self.id = id
    self.runtimeID = runtimeID
    self.toolID = toolID
    self.reason = reason
    self.patterns = patterns
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, runtimeID, toolID, reason, patterns, createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      runtimeID: try container.decodeIfPresent(String.self, forKey: .runtimeID),
      toolID: try container.decode(String.self, forKey: .toolID),
      reason: try container.decode(String.self, forKey: .reason),
      patterns: try container.decodeIfPresent([String].self, forKey: .patterns) ?? [],
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    )
  }
}

public struct KimiUIState: Codable, Equatable, Sendable {
  public var activePane: KimiActivePane
  public let terminalPlacement: KimiTerminalPlacement
  public var runtimeState: KimiRuntimeState
  public var activeSessionID: UUID?
  public var sessions: [KimiSessionSummary]
  public var messages: [KimiMessage]
  public var activities: [KimiActivity]
  public var pendingPermissions: [KimiPermissionRequest]
  public var lastError: String?

  public init(
    activePane: KimiActivePane = .conversation,
    terminalPlacement: KimiTerminalPlacement = .right,
    runtimeState: KimiRuntimeState = .stopped,
    activeSessionID: UUID? = nil,
    sessions: [KimiSessionSummary] = [],
    messages: [KimiMessage] = [],
    activities: [KimiActivity] = [],
    pendingPermissions: [KimiPermissionRequest] = [],
    lastError: String? = nil
  ) {
    self.activePane = activePane
    self.terminalPlacement = terminalPlacement
    self.runtimeState = runtimeState
    self.activeSessionID = activeSessionID
    self.sessions = sessions
    self.messages = messages
    self.activities = activities
    self.pendingPermissions = pendingPermissions
    self.lastError = lastError
  }
}

public enum KimiEvent: Sendable, Equatable {
  case runtimeChanged(KimiRuntimeState)
  case sessionChanged(KimiSessionSummary)
  case userText(String)
  case assistantText(String)
  case activity(KimiActivity)
  case permission(KimiPermissionRequest)
  case error(String)

  public var displayText: String {
    switch self {
    case let .runtimeChanged(state): return state.rawValue
    case let .sessionChanged(session): return session.title
    case let .userText(text), let .assistantText(text), let .error(text): return text
    case let .activity(activity): return activity.title
    case let .permission(permission): return permission.reason
    }
  }
}
