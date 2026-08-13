import Foundation

public enum TerminalTabKind: String, Codable, CaseIterable, Sendable {
  case local
  case ssh
}

public enum TerminalTabStatus: String, Codable, CaseIterable, Sendable {
  case idle
  case running
  case awaitingApproval
  case interrupted
  case failed
  case disconnected
}

public struct TerminalTabRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID?
  public var title: String
  public var kind: TerminalTabKind
  public var cwd: String
  public var shellPath: String
  public var status: TerminalTabStatus
  public var rows: Int
  public var columns: Int
  public var output: String
  public var environmentProfileID: UUID?
  public var sshProfileID: UUID?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    taskID: UUID? = nil,
    title: String,
    kind: TerminalTabKind = .local,
    cwd: String,
    shellPath: String = "/bin/zsh",
    status: TerminalTabStatus = .idle,
    rows: Int = 32,
    columns: Int = 120,
    output: String = "",
    environmentProfileID: UUID? = nil,
    sshProfileID: UUID? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.taskID = taskID
    self.title = title
    self.kind = kind
    self.cwd = cwd
    self.shellPath = shellPath
    self.status = status
    self.rows = max(2, rows)
    self.columns = max(20, columns)
    self.output = output
    self.environmentProfileID = environmentProfileID
    self.sshProfileID = sshProfileID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct TerminalEnvironmentProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var variables: [String: String]
  public var secretVariableNames: [String]
  public var workingDirectory: String?
  public var shellPath: String
  public var loginShell: Bool

  public init(
    id: UUID = UUID(),
    name: String,
    variables: [String: String] = [:],
    secretVariableNames: [String] = [],
    workingDirectory: String? = nil,
    shellPath: String = "/bin/zsh",
    loginShell: Bool = true
  ) {
    self.id = id
    self.name = name
    self.variables = variables
    self.secretVariableNames = secretVariableNames
    self.workingDirectory = workingDirectory
    self.shellPath = shellPath
    self.loginShell = loginShell
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, variables, secretVariableNames, workingDirectory, shellPath, loginShell
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    variables = try values.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
    secretVariableNames = try values.decodeIfPresent([String].self, forKey: .secretVariableNames) ?? []
    workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
    shellPath = try values.decodeIfPresent(String.self, forKey: .shellPath) ?? "/bin/zsh"
    loginShell = try values.decodeIfPresent(Bool.self, forKey: .loginShell) ?? true
  }
}

public struct SSHProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var host: String
  public var port: Int
  public var username: String
  public var identityFile: String?
  public var proxyJump: String?
  public var workingDirectory: String?
  public var shellPath: String
  public var hostKeyPolicy: SSHHostKeyPolicy
  public var knownHostsFile: String?
  public var expectedHostFingerprint: String?
  public var credentialReference: SSHCredentialReference?
  public var reconnectPolicy: TerminalReconnectPolicy

  public init(
    id: UUID = UUID(),
    name: String,
    host: String,
    port: Int = 22,
    username: String,
    identityFile: String? = nil,
    proxyJump: String? = nil,
    workingDirectory: String? = nil,
    shellPath: String = "/bin/zsh",
    hostKeyPolicy: SSHHostKeyPolicy = .ask,
    knownHostsFile: String? = nil,
    expectedHostFingerprint: String? = nil,
    credentialReference: SSHCredentialReference? = nil,
    reconnectPolicy: TerminalReconnectPolicy = .default
  ) {
    self.id = id
    self.name = name
    self.host = host
    self.port = max(1, min(port, 65_535))
    self.username = username
    self.identityFile = identityFile
    self.proxyJump = proxyJump
    self.workingDirectory = workingDirectory
    self.shellPath = shellPath
    self.hostKeyPolicy = hostKeyPolicy
    self.knownHostsFile = knownHostsFile
    self.expectedHostFingerprint = expectedHostFingerprint
    self.credentialReference = credentialReference
    self.reconnectPolicy = reconnectPolicy
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, host, port, username, identityFile, proxyJump, workingDirectory, shellPath
    case hostKeyPolicy, knownHostsFile, expectedHostFingerprint, credentialReference, reconnectPolicy
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    host = try values.decode(String.self, forKey: .host)
    port = max(1, min(try values.decodeIfPresent(Int.self, forKey: .port) ?? 22, 65_535))
    username = try values.decode(String.self, forKey: .username)
    identityFile = try values.decodeIfPresent(String.self, forKey: .identityFile)
    proxyJump = try values.decodeIfPresent(String.self, forKey: .proxyJump)
    workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
    shellPath = try values.decodeIfPresent(String.self, forKey: .shellPath) ?? "/bin/zsh"
    hostKeyPolicy = try values.decodeIfPresent(SSHHostKeyPolicy.self, forKey: .hostKeyPolicy) ?? .ask
    knownHostsFile = try values.decodeIfPresent(String.self, forKey: .knownHostsFile)
    expectedHostFingerprint = try values.decodeIfPresent(String.self, forKey: .expectedHostFingerprint)
    credentialReference = try values.decodeIfPresent(SSHCredentialReference.self, forKey: .credentialReference)
    reconnectPolicy = try values.decodeIfPresent(TerminalReconnectPolicy.self, forKey: .reconnectPolicy) ?? .default
  }
}

public enum SSHHostKeyPolicy: String, Codable, CaseIterable, Sendable {
  case ask
  case strict
  case acceptNew
}

public enum TerminalQueueStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case running
  case completed
  case failed
  case cancelled
  case interrupted
}

public struct TerminalCommandJob: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let command: String
  public var priority: Int
  public var timeoutSeconds: Int
  public var requiresApproval: Bool
  public var status: TerminalQueueStatus
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    command: String,
    priority: Int = 0,
    timeoutSeconds: Int = 300,
    requiresApproval: Bool = false,
    status: TerminalQueueStatus = .queued,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.command = command
    self.priority = priority
    self.timeoutSeconds = max(1, timeoutSeconds)
    self.requiresApproval = requiresApproval
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct TerminalWorkspaceState: Codable, Equatable, Sendable {
  public var workspacePath: String?
  public var tabs: [TerminalTabRecord]
  public var activeTabID: UUID?
  public var queuedJobs: [TerminalCommandJob]
  public var environmentProfiles: [TerminalEnvironmentProfile]
  public var sshProfiles: [SSHProfile]
  public var paneLayout: TerminalPaneLayout?

  public init(
    workspacePath: String? = nil,
    tabs: [TerminalTabRecord] = [],
    activeTabID: UUID? = nil,
    queuedJobs: [TerminalCommandJob] = [],
    environmentProfiles: [TerminalEnvironmentProfile] = [],
    sshProfiles: [SSHProfile] = [],
    paneLayout: TerminalPaneLayout? = nil
  ) {
    self.workspacePath = workspacePath
    self.tabs = tabs
    self.activeTabID = activeTabID ?? tabs.last?.id
    self.queuedJobs = queuedJobs
    self.environmentProfiles = environmentProfiles
    self.sshProfiles = sshProfiles
    self.paneLayout = paneLayout
  }

  @discardableResult
  public mutating func openLocalTab(title: String? = nil, cwd: String, taskID: UUID? = nil) -> TerminalTabRecord {
    let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = (trimmedTitle?.isEmpty == false ? trimmedTitle : nil)
      ?? URL(fileURLWithPath: cwd).lastPathComponent
    let tab = TerminalTabRecord(taskID: taskID, title: resolvedTitle.isEmpty ? "终端" : resolvedTitle, cwd: cwd)
    tabs.append(tab)
    activeTabID = tab.id
    if paneLayout == nil { paneLayout = .single(tab.id) }
    return tab
  }

  @discardableResult
  public mutating func openSSHTab(profile: SSHProfile, taskID: UUID? = nil) -> TerminalTabRecord {
    let tab = TerminalTabRecord(
      taskID: taskID,
      title: profile.name,
      kind: .ssh,
      cwd: profile.workingDirectory ?? "~",
      sshProfileID: profile.id
    )
    tabs.append(tab)
    activeTabID = tab.id
    if paneLayout == nil { paneLayout = .single(tab.id) }
    if !sshProfiles.contains(where: { $0.id == profile.id }) { sshProfiles.append(profile) }
    return tab
  }

  public mutating func selectTab(_ id: UUID?) {
    guard let id, tabs.contains(where: { $0.id == id }) else { return }
    activeTabID = id
  }

  public mutating func closeTab(_ id: UUID) {
    tabs.removeAll { $0.id == id }
    paneLayout?.close(id)
    if paneLayout?.panes.count ?? 0 < 2 { paneLayout = tabs.first.map { .single($0.id) } }
    if activeTabID == id { activeTabID = tabs.last?.id }
    queuedJobs.removeAll { $0.sessionID == id && $0.status == .queued }
  }

  @discardableResult
  public mutating func enqueue(command: String, sessionID: UUID, priority: Int = 0, timeoutSeconds: Int = 300, requiresApproval: Bool = false) -> TerminalCommandJob {
    let job = TerminalCommandJob(sessionID: sessionID, command: command, priority: priority, timeoutSeconds: timeoutSeconds, requiresApproval: requiresApproval)
    queuedJobs.append(job)
    queuedJobs.sort { lhs, rhs in
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      return lhs.createdAt < rhs.createdAt
    }
    return job
  }

  public mutating func cancelQueuedJob(_ id: UUID) {
    guard let index = queuedJobs.firstIndex(where: { $0.id == id && $0.status == .queued }) else { return }
    queuedJobs[index].status = .cancelled
    queuedJobs[index].updatedAt = .now
  }

  public mutating func updateJob(_ id: UUID, status: TerminalQueueStatus) {
    guard let index = queuedJobs.firstIndex(where: { $0.id == id }) else { return }
    queuedJobs[index].status = status
    queuedJobs[index].updatedAt = .now
  }

  public mutating func appendOutput(tabID: UUID, text: String) {
    guard let index = tabs.firstIndex(where: { $0.id == tabID }), !text.isEmpty else { return }
    tabs[index].output += text
    if tabs[index].output.count > 200_000 {
      tabs[index].output = "…(较早终端输出已截断)\n" + String(tabs[index].output.suffix(200_000))
    }
    tabs[index].updatedAt = .now
  }

  public mutating func updateTab(_ id: UUID, status: TerminalTabStatus? = nil, rows: Int? = nil, columns: Int? = nil) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    if let status { tabs[index].status = status }
    if let rows { tabs[index].rows = max(2, rows) }
    if let columns { tabs[index].columns = max(20, columns) }
    tabs[index].updatedAt = .now
  }

  public mutating func markInterrupted() {
    for index in tabs.indices where tabs[index].status == .running || tabs[index].status == .awaitingApproval {
      tabs[index].status = .interrupted
      tabs[index].updatedAt = .now
    }
    for index in queuedJobs.indices where queuedJobs[index].status == .queued || queuedJobs[index].status == .running {
      queuedJobs[index].status = .interrupted
      queuedJobs[index].updatedAt = .now
    }
  }
}
