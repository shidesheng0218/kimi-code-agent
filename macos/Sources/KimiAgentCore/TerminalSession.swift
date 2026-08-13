import Foundation

public enum TerminalActor: String, Codable, CaseIterable, Sendable {
  case user
  case agent
}

public enum TerminalSessionStatus: String, Codable, CaseIterable, Sendable {
  case idle
  case awaitingApproval
  case running
  case failed
}

public enum TerminalCommandStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case awaitingApproval
  case running
  case completed
  case failed
  case denied
  case cancelled
  case interrupted
}

public enum TerminalApprovalState: String, Codable, CaseIterable, Sendable {
  case notRequired
  case awaitingApproval
  case approvedOnce
  case approvedForSession
  case denied
}

public enum TerminalOutputStream: String, Codable, CaseIterable, Sendable {
  case standardOutput
  case standardError
}

public struct TerminalCommandRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  /// The runtime tool-call identifier for Agent-initiated commands. `nil` for commands entered by the user.
  public var toolCallID: String?
  public let command: String
  public let cwd: String
  public let requestedBy: TerminalActor
  public var approval: TerminalApprovalState
  public var status: TerminalCommandStatus
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32?
  public var startedAt: Date?
  public var finishedAt: Date?

  public init(
    id: UUID = UUID(),
    toolCallID: String? = nil,
    command: String,
    cwd: String,
    requestedBy: TerminalActor,
    approval: TerminalApprovalState = .notRequired,
    status: TerminalCommandStatus = .queued,
    stdout: String = "",
    stderr: String = "",
    exitCode: Int32? = nil,
    startedAt: Date? = nil,
    finishedAt: Date? = nil
  ) {
    self.id = id
    self.toolCallID = toolCallID
    self.command = command
    self.cwd = cwd
    self.requestedBy = requestedBy
    self.approval = approval
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }

  public var output: String {
    [stdout, stderr].filter { !$0.isEmpty }.joined()
  }

  public var duration: TimeInterval? {
    guard let startedAt, let finishedAt else { return nil }
    return finishedAt.timeIntervalSince(startedAt)
  }
}

public struct TerminalSession: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID
  public var cwd: String
  public var status: TerminalSessionStatus
  public var history: [TerminalCommandRecord]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    taskID: UUID,
    cwd: String,
    status: TerminalSessionStatus = .idle,
    history: [TerminalCommandRecord] = [],
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.taskID = taskID
    self.cwd = cwd
    self.status = status
    self.history = history
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public mutating func append(command: TerminalCommandRecord) {
    history.append(command)
    if history.count > 200 {
      history.removeFirst(history.count - 200)
    }
    updatedAt = .now
  }

  public mutating func start(commandID: UUID) {
    update(commandID) { command in
      command.status = .running
      command.startedAt = .now
      command.finishedAt = nil
      command.exitCode = nil
    }
    status = .running
  }

  public mutating func awaitApproval(commandID: UUID) {
    update(commandID) { command in
      command.status = .awaitingApproval
      command.approval = .awaitingApproval
    }
    status = .awaitingApproval
  }

  public mutating func approve(commandID: UUID, forSession: Bool) {
    update(commandID) { command in
      command.approval = forSession ? .approvedForSession : .approvedOnce
      command.status = .queued
    }
    status = .idle
  }

  public mutating func deny(commandID: UUID) {
    update(commandID) { command in
      command.approval = .denied
      command.status = .denied
      command.finishedAt = .now
    }
    status = .idle
  }

  public mutating func appendOutput(commandID: UUID, stream: TerminalOutputStream, text: String) {
    update(commandID) { command in
      switch stream {
      case .standardOutput:
        command.stdout = Self.cappedOutput(command.stdout + text)
      case .standardError:
        command.stderr = Self.cappedOutput(command.stderr + text)
      }
    }
  }

  public mutating func finish(commandID: UUID, exitCode: Int32, cancelled: Bool = false) {
    update(commandID) { command in
      command.exitCode = exitCode
      command.finishedAt = .now
      command.status = cancelled ? .cancelled : exitCode == 0 ? .completed : .failed
    }
    status = exitCode == 0 || cancelled ? .idle : .failed
  }

  public mutating func markRunningCommandsInterrupted() {
    for index in history.indices where history[index].status == .running || history[index].status == .awaitingApproval {
      history[index].status = .interrupted
      history[index].finishedAt = .now
    }
    if status == .running || status == .awaitingApproval {
      status = .idle
    }
    updatedAt = .now
  }

  /// Mirrors a shell-like Agent tool call into the task terminal. Returns `true` only when the session changed.
  ///
  /// Agent events can arrive through both the live host stream and the persisted structured-event stream, so this
  /// method is deliberately idempotent by the runtime tool-call ID.
  @discardableResult
  public mutating func recordAgentToolEvent(_ event: AgentEvent, cwd: String) -> Bool {
    let toolCallID = event.payload["id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedToolCallID = (toolCallID?.isEmpty == false ? toolCallID : nil) ?? event.id.uuidString
    let knownCommandIndex = history.firstIndex(where: { $0.toolCallID == resolvedToolCallID })
    let toolName = (event.payload["name"] ?? "").lowercased()
    let isTerminalTool = Self.isTerminalTool(named: toolName)

    switch event.kind {
    case .toolRequested, .commandRequested:
      guard isTerminalTool, knownCommandIndex == nil else { return false }
      let requiresApproval = event.requiresApproval
      append(command: TerminalCommandRecord(
        toolCallID: resolvedToolCallID,
        command: Self.commandDescription(from: event),
        cwd: cwd,
        requestedBy: .agent,
        approval: requiresApproval ? .awaitingApproval : .notRequired,
        status: requiresApproval ? .awaitingApproval : .queued
      ))
      if requiresApproval, let commandID = history.last?.id {
        awaitApproval(commandID: commandID)
      }
      return true

    case .toolStarted, .commandStarted:
      guard let index = knownCommandIndex else { return false }
      guard history[index].status != .running else { return false }
      start(commandID: history[index].id)
      return true

    case .toolFinished, .commandFinished:
      guard let index = knownCommandIndex else { return false }
      let commandID = history[index].id
      guard !Self.isFinished(history[index].status) else { return false }
      let output = event.payload["output"] ?? event.payload["content"] ?? event.payload["message"] ?? ""
      let failed = (event.payload["status"] ?? "").lowercased() == "failed"
      if !output.isEmpty {
        appendOutput(commandID: commandID, stream: failed ? .standardError : .standardOutput, text: output)
      }
      finish(commandID: commandID, exitCode: failed ? 1 : 0)
      return true

    default:
      return false
    }
  }

  public var agentContextSummary: String {
    guard let command = history.last(where: { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }) else {
      return ""
    }
    let output = command.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let clipped = output.count > 4_000 ? String(output.suffix(4_000)) : output
    let exitCode = command.exitCode.map(String.init) ?? "未知"
    return "最近终端命令：\(command.command)\n目录：\(command.cwd)\n退出码：\(exitCode)\n输出：\(clipped)"
  }

  private mutating func update(_ commandID: UUID, _ body: (inout TerminalCommandRecord) -> Void) {
    guard let index = history.firstIndex(where: { $0.id == commandID }) else { return }
    body(&history[index])
    updatedAt = .now
  }

  private static func cappedOutput(_ value: String) -> String {
    let limit = 64_000
    guard value.count > limit else { return value }
    return "…(较早输出已截断)\n" + String(value.suffix(limit))
  }

  private static func isTerminalTool(named name: String) -> Bool {
    ["shell", "bash", "zsh", "terminal", "command", "exec", "run_command"].contains { name.contains($0) }
  }

  private static func isFinished(_ status: TerminalCommandStatus) -> Bool {
    switch status {
    case .completed, .failed, .denied, .cancelled, .interrupted:
      true
    case .queued, .awaitingApproval, .running:
      false
    }
  }

  private static func commandDescription(from event: AgentEvent) -> String {
    let name = event.payload["name"] ?? "shell"
    let arguments = event.payload["arguments"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !arguments.isEmpty else { return name }
    guard let data = arguments.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return "\(name) \(arguments)"
    }
    for key in ["command", "cmd", "script", "input"] {
      if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return value
      }
    }
    return "\(name) \(arguments)"
  }
}
