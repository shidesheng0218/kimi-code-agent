import Foundation

public struct SkillDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let entryPath: String?
  public let permissions: [String]
  public let fileURL: URL

  public init(
    name: String,
    description: String,
    fileURL: URL,
    entryPath: String? = nil,
    permissions: [String] = []
  ) {
    id = fileURL.path
    self.name = name
    self.description = description
    self.entryPath = entryPath
    self.permissions = permissions
    self.fileURL = fileURL
  }

  public var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  public var entryURL: URL? {
    guard let entryPath, !entryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return directoryURL.appendingPathComponent(entryPath)
  }
}

public struct SkillInvocation: Equatable, Sendable {
  public let skill: SkillDescriptor
  public let arguments: String
  public let prompt: String

  public init(skill: SkillDescriptor, arguments: String, prompt: String) {
    self.skill = skill
    self.arguments = arguments
    self.prompt = prompt
  }
}

/// Conservative local matching for declarative SKILL.md instructions. It
/// never executes an entry script; it merely selects one relevant skill to
/// preload into the Harness context. Explicit `/skill-name` always wins.
public enum SkillAutoMatcher {
  public static func match(prompt: String, skills: [SkillDescriptor]) -> SkillDescriptor? {
    let normalizedPrompt = normalize(prompt)
    guard !normalizedPrompt.isEmpty, !normalizedPrompt.hasPrefix("/") else { return nil }
    let candidates = skills.map { skill in (skill, score(prompt: normalizedPrompt, skill: skill)) }
      .filter { $0.1 >= 4 }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
        return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
      }
    return candidates.first?.0
  }

  private static func score(prompt: String, skill: SkillDescriptor) -> Int {
    var value = 0
    let name = normalize(skill.name)
    if name.count >= 2, prompt.contains(name) { value += 12 }

    let description = normalize(skill.description)
    let englishTerms = (name + " " + description)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count >= 3 && !$0.allSatisfy(\ .isNumber) }
    for term in Set(englishTerms) where prompt.contains(term) {
      value += 3
    }

    let cjk = Array(description.filter(isCJK))
    guard cjk.count > 1 else { return value }
    let bigrams = Set((0..<(cjk.count - 1)).map { String(cjk[$0...($0 + 1)]) })
    for bigram in bigrams where prompt.contains(bigram) {
      value += 2
    }
    return value
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      (0x4E00...0x9FFF).contains(Int(scalar.value))
    }
  }
}

public enum SkillInvocationParser {
  /// Parses `/skill-name optional arguments` without treating ordinary slash
  /// text as a Skill. The caller decides which discovered scopes are enabled.
  public static func parse(_ rawPrompt: String, skills: [SkillDescriptor]) -> SkillInvocation? {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard prompt.first == "/" else { return nil }
    let pieces = prompt.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    guard let command = pieces.first.map(String.init), command.count > 1 else { return nil }
    let name = String(command.dropFirst())
    guard let skill = skills.first(where: { $0.name == name }) else { return nil }
    let arguments = pieces.dropFirst().first.map(String.init) ?? ""
    return SkillInvocation(
      skill: skill,
      arguments: arguments,
      prompt: promptText(
        skill: skill,
        header: "手动调用 Skill：/\(skill.name)",
        userPrompt: nil,
        arguments: arguments
      )
    )
  }

  public static func automaticInvocation(prompt: String, skills: [SkillDescriptor]) -> SkillInvocation? {
    let originalPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let skill = SkillAutoMatcher.match(prompt: originalPrompt, skills: skills) else { return nil }
    return SkillInvocation(
      skill: skill,
      arguments: "",
      prompt: promptText(
        skill: skill,
        header: "自动匹配 Skill：/\(skill.name)",
        userPrompt: originalPrompt,
        arguments: ""
      )
    )
  }

  private static func promptText(
    skill: SkillDescriptor,
    header: String,
    userPrompt: String?,
    arguments: String
  ) -> String {
    let body = (try? String(contentsOf: skill.fileURL, encoding: .utf8)) ?? ""
    let instruction = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return [
      header,
      userPrompt?.isEmpty == false ? "用户请求：\(userPrompt!)" : nil,
      arguments.isEmpty ? nil : "参数：\(arguments)",
      instruction.isEmpty ? nil : "Skill 指令：\n\(instruction)",
      "请按当前 Harness 权限执行，并只返回与用户任务相关的结果。"
    ].compactMap { $0 }.joined(separator: "\n\n")
  }
}

public enum HookEvent: String, Codable, CaseIterable, Sendable {
  case sessionStart
  case sessionEnd
  case userPromptSubmit
  case taskStarted
  case beforeTool
  case afterTool
  case postToolUseFailure
  case permissionRequest
  case permissionDenied
  case subagentStart
  case subagentStop
  case taskCreated
  case taskCompleted
  case taskFailed
  case preCompact
  case postCompact
  case messageDisplay
  case mcpToolCall
}

public enum HookBehavior: String, Codable, CaseIterable, Sendable {
  case allow
  case block
}

public struct HookDefinition: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let event: HookEvent
  public let command: String
  public let timeoutSeconds: Int
  public let behavior: HookBehavior

  private enum CodingKeys: String, CodingKey {
    case id, event, command, timeoutSeconds, behavior
  }

  public init(
    id: UUID = UUID(),
    event: HookEvent,
    command: String,
    timeoutSeconds: Int = 30,
    behavior: HookBehavior = .allow
  ) {
    self.id = id
    self.event = event
    self.command = command
    self.timeoutSeconds = timeoutSeconds
    self.behavior = behavior
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    event = try container.decode(HookEvent.self, forKey: .event)
    command = try container.decode(String.self, forKey: .command)
    timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
    behavior = try container.decodeIfPresent(HookBehavior.self, forKey: .behavior) ?? .allow
  }
}

public struct HookResult: Codable, Equatable, Sendable {
  public let hookID: UUID
  public let event: HookEvent
  public let command: String
  public let decision: HookBehavior
  public let exitCode: Int32?
  public let standardOutput: String
  public let standardError: String
  public let timedOut: Bool
  public let startedAt: Date
  public let finishedAt: Date

  public init(
    hookID: UUID,
    event: HookEvent,
    command: String,
    decision: HookBehavior,
    exitCode: Int32? = nil,
    standardOutput: String = "",
    standardError: String = "",
    timedOut: Bool = false,
    startedAt: Date = .now,
    finishedAt: Date = .now
  ) {
    self.hookID = hookID
    self.event = event
    self.command = command
    self.decision = decision
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.timedOut = timedOut
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

public struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let transport: MCPTransport
  public let command: String?
  public let endpoint: URL?
  public let arguments: [String]
  public let isEnabled: Bool

  public init(
    id: UUID = UUID(), name: String, transport: MCPTransport, command: String? = nil,
    endpoint: URL? = nil, arguments: [String] = [], isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.transport = transport
    self.command = command
    self.endpoint = endpoint
    self.arguments = arguments
    self.isEnabled = isEnabled
  }
}

public enum MCPTransport: String, Codable, CaseIterable, Sendable {
  case stdio
  case http
}

public enum MCPServerState: String, Codable, CaseIterable, Sendable {
  case disabled
  case stopped
  case running
  case failed
}

public struct MCPServerStatus: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let transport: MCPTransport
  public let state: MCPServerState
  public let message: String

  public init(
    id: UUID,
    name: String,
    transport: MCPTransport,
    state: MCPServerState,
    message: String = ""
  ) {
    self.id = id
    self.name = name
    self.transport = transport
    self.state = state
    self.message = message
  }
}

public struct ProjectAgentConfiguration: Codable, Equatable, Sendable {
  public var modelID: String?
  public var maxConcurrentWorkers: Int
  public var skillsDirectories: [String]
  public var hooks: [HookDefinition]
  public var mcpServers: [MCPServerConfiguration]
  public var allowedDomains: [String]
  public var browserVerification: BrowserVerificationPlan?

  public init(
    modelID: String? = nil,
    maxConcurrentWorkers: Int = 8,
    skillsDirectories: [String] = [],
    hooks: [HookDefinition] = [],
    mcpServers: [MCPServerConfiguration] = [],
    allowedDomains: [String] = [],
    browserVerification: BrowserVerificationPlan? = nil
  ) {
    self.modelID = modelID
    self.maxConcurrentWorkers = min(max(maxConcurrentWorkers, 1), 8)
    self.skillsDirectories = skillsDirectories
    self.hooks = hooks
    self.mcpServers = mcpServers
    self.allowedDomains = allowedDomains
    self.browserVerification = browserVerification
  }

  public static func configurationURL(projectDirectory: URL) -> URL {
    projectDirectory
      .appendingPathComponent(".kimi-agent", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  public static func load(projectDirectory: URL, fileManager: FileManager = .default) throws -> ProjectAgentConfiguration {
    let url = configurationURL(projectDirectory: projectDirectory)
    guard fileManager.fileExists(atPath: url.path) else {
      return ProjectAgentConfiguration()
    }
    let decoder = JSONDecoder()
    return try decoder.decode(ProjectAgentConfiguration.self, from: Data(contentsOf: url))
  }

  public func write(projectDirectory: URL, fileManager: FileManager = .default) throws {
    let url = Self.configurationURL(projectDirectory: projectDirectory)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}

public final class ProjectExtensionRuntime: @unchecked Sendable {
  private let projectDirectory: URL
  private let fileManager: FileManager
  private var mcpClients: [UUID: MCPStdioClient] = [:]
  private var mcpHttpClients: [UUID: MCPHttpClient] = [:]

  public init(projectDirectory: URL, fileManager: FileManager = .default) {
    self.projectDirectory = projectDirectory
    self.fileManager = fileManager
  }

  deinit {
    stop()
  }

  public func loadConfiguration() throws -> ProjectAgentConfiguration {
    try ProjectAgentConfiguration.load(projectDirectory: projectDirectory, fileManager: fileManager)
  }

  public func discoverSkills() throws -> [SkillDescriptor] {
    let configuration = try loadConfiguration()
    let additionalDirectories = configuration.skillsDirectories.map { directory -> URL in
      URL(fileURLWithPath: directory, relativeTo: projectDirectory).standardizedFileURL
    }
    return SkillRegistry.discover(projectDirectory: projectDirectory, additionalDirectories: additionalDirectories)
  }

  public func executeSkill(named skillName: String, task: AgentTask) throws -> SkillExecutionResult {
    let skills = try discoverSkills()
    guard let skill = skills.first(where: { $0.name == skillName }) else {
      throw SkillRunnerError.missingEntry(skillName: skillName)
    }
    return try SkillRunner.execute(skill: skill, projectDirectory: projectDirectory, task: task)
  }

  public func runHooks(event: HookEvent, task: AgentTask) throws -> [HookResult] {
    let configuration = try loadConfiguration()
    let hooks = configuration.hooks.filter { $0.event == event }
    return try hooks.map { hook in
      let startedAt = Date()
      guard hook.behavior == .allow else {
        return HookResult(
          hookID: hook.id,
          event: hook.event,
          command: hook.command,
          decision: .block,
          startedAt: startedAt,
          finishedAt: Date()
        )
      }

      let result = try runShellCommand(
        hook.command,
        timeoutSeconds: hook.timeoutSeconds,
        environment: hookEnvironment(event: event, task: task)
      )
      return HookResult(
        hookID: hook.id,
        event: hook.event,
        command: hook.command,
        decision: .allow,
        exitCode: result.exitCode,
        standardOutput: result.standardOutput,
        standardError: result.standardError,
        timedOut: result.timedOut,
        startedAt: startedAt,
        finishedAt: Date()
      )
    }
  }

  public func refreshMCPStatuses() throws -> [MCPServerStatus] {
    let configuration = try loadConfiguration()
    return configuration.mcpServers.map { server in
      guard server.isEnabled else {
        stopMCPServer(id: server.id)
        return MCPServerStatus(
          id: server.id,
          name: server.name,
          transport: server.transport,
          state: .disabled,
          message: "Server is disabled."
        )
      }

      switch server.transport {
      case .stdio:
        return connectStdioServer(server)
      case .http:
        guard server.endpoint != nil else {
          stopMCPServer(id: server.id)
          return MCPServerStatus(
            id: server.id,
            name: server.name,
            transport: server.transport,
            state: .failed,
            message: "Missing HTTP endpoint."
          )
        }
        return connectHTTPServer(server, allowedDomains: configuration.allowedDomains)
      }
    }
  }

  public func stop() {
    for client in mcpClients.values {
      client.close()
    }
    mcpClients.removeAll()
    for client in mcpHttpClients.values {
      client.close()
    }
    mcpHttpClients.removeAll()
  }

  public func listMCPTools(serverID: UUID) throws -> [MCPTool] {
    let configuration = try loadConfiguration()
    guard let server = configuration.mcpServers.first(where: { $0.id == serverID }), server.isEnabled else {
      return []
    }
    guard server.transport == .stdio else {
      if server.transport == .http {
        let client = try connectOrCreateHTTPClient(server, allowedDomains: configuration.allowedDomains)
        _ = try client.initialize()
        return try client.listTools()
      }
      return []
    }
    let client = try connectOrCreateClient(server)
    _ = try client.initialize()
    return try client.listTools()
  }

  public func listMCPResources(serverID: UUID) throws -> [MCPResource] {
    let configuration = try loadConfiguration()
    guard let server = configuration.mcpServers.first(where: { $0.id == serverID }), server.isEnabled else {
      return []
    }

    switch server.transport {
    case .stdio:
      let client = try connectOrCreateClient(server)
      let initialize = try client.initialize()
      guard initialize.capabilities.resources else { return [] }
      return try client.listResources()
    case .http:
      let client = try connectOrCreateHTTPClient(server, allowedDomains: configuration.allowedDomains)
      let initialize = try client.initialize()
      guard initialize.capabilities.resources else { return [] }
      return try client.listResources()
    }
  }

  public func listMCPPrompts(serverID: UUID) throws -> [MCPPrompt] {
    let configuration = try loadConfiguration()
    guard let server = configuration.mcpServers.first(where: { $0.id == serverID }), server.isEnabled else {
      return []
    }

    switch server.transport {
    case .stdio:
      let client = try connectOrCreateClient(server)
      let initialize = try client.initialize()
      guard initialize.capabilities.prompts else { return [] }
      return try client.listPrompts()
    case .http:
      let client = try connectOrCreateHTTPClient(server, allowedDomains: configuration.allowedDomains)
      let initialize = try client.initialize()
      guard initialize.capabilities.prompts else { return [] }
      return try client.listPrompts()
    }
  }

  public func readMCPResource(serverID: UUID, uri: String) throws -> [MCPResourceContent] {
    let configuration = try loadConfiguration()
    guard let server = configuration.mcpServers.first(where: { $0.id == serverID }), server.isEnabled else {
      throw MCPClientError.notConnected
    }

    switch server.transport {
    case .stdio:
      let client = try connectOrCreateClient(server)
      _ = try client.initialize()
      return try client.readResource(uri: uri)
    case .http:
      let client = try connectOrCreateHTTPClient(server, allowedDomains: configuration.allowedDomains)
      _ = try client.initialize()
      return try client.readResource(uri: uri)
    }
  }

  public func getMCPPrompt(
    serverID: UUID,
    name: String,
    arguments: [String: String] = [:]
  ) throws -> MCPPromptResult {
    let configuration = try loadConfiguration()
    guard let server = configuration.mcpServers.first(where: { $0.id == serverID }), server.isEnabled else {
      throw MCPClientError.notConnected
    }

    switch server.transport {
    case .stdio:
      let client = try connectOrCreateClient(server)
      _ = try client.initialize()
      return try client.getPrompt(name: name, arguments: arguments)
    case .http:
      let client = try connectOrCreateHTTPClient(server, allowedDomains: configuration.allowedDomains)
      _ = try client.initialize()
      return try client.getPrompt(name: name, arguments: arguments)
    }
  }

  public func callMCPTool(serverID: UUID, name: String, arguments: [String: String]) throws -> MCPToolCallResult {
    let configuration = try loadConfiguration()
    guard let server = configuration.mcpServers.first(where: { $0.id == serverID }), server.isEnabled else {
      throw MCPClientError.notConnected
    }
    guard server.transport == .stdio else {
      if server.transport == .http {
        let client = try connectOrCreateHTTPClient(server, allowedDomains: configuration.allowedDomains)
        _ = try client.initialize()
        return try client.callTool(name: name, arguments: arguments)
      }
      throw MCPClientError.notConnected
    }
    let client = try connectOrCreateClient(server)
    _ = try client.initialize()
    return try client.callTool(name: name, arguments: arguments)
  }

  private func hookEnvironment(event: HookEvent, task: AgentTask) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["KIMI_AGENT_HOOK_EVENT"] = event.rawValue
    environment["KIMI_AGENT_TASK_ID"] = task.id.uuidString
    environment["KIMI_AGENT_TASK_TITLE"] = task.title
    environment["KIMI_AGENT_TASK_MODE"] = task.mode.rawValue
    environment["KIMI_AGENT_WORKSPACE"] = task.workspacePath
    if let worktreePath = task.worktreePath {
      environment["KIMI_AGENT_WORKTREE"] = worktreePath
    }
    return environment
  }

  private func runShellCommand(
    _ command: String,
    timeoutSeconds: Int,
    environment: [String: String]
  ) throws -> HookProcessResult {
    let scratchURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kimi-hook-\(UUID().uuidString)", isDirectory: true)
    let sandbox = TerminalSandboxConfiguration.strict(
      workspaceURL: projectDirectory,
      scratchURL: scratchURL,
      allowNetwork: false
    )
    let handle = try TerminalCommandRunner.start(
      command: command,
      cwd: projectDirectory,
      environment: environment,
      sandbox: sandbox
    )
    var timedOut = false
    let timeout = max(timeoutSeconds, 1)
    let deadline = Date().addingTimeInterval(TimeInterval(timeout))
    while handle.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if handle.isRunning {
      timedOut = true
      handle.terminate()
    }
    let result = handle.wait()
    try? fileManager.removeItem(at: scratchURL)
    return HookProcessResult(
      standardOutput: result.standardOutput,
      standardError: result.standardError,
      exitCode: result.exitCode,
      timedOut: timedOut
    )
  }

  private func connectStdioServer(_ server: MCPServerConfiguration) -> MCPServerStatus {
    if mcpClients[server.id] != nil {
      return MCPServerStatus(
        id: server.id,
        name: server.name,
        transport: server.transport,
        state: .running,
        message: "stdio server is connected."
      )
    }
    do {
      let client = try connectOrCreateClient(server)
      _ = try client.initialize()
      return MCPServerStatus(
        id: server.id,
        name: server.name,
        transport: server.transport,
        state: .running,
        message: "stdio server connected."
      )
    } catch {
      stopMCPServer(id: server.id)
      return MCPServerStatus(
        id: server.id,
        name: server.name,
        transport: server.transport,
        state: .failed,
        message: error.localizedDescription
      )
    }
  }

  private func connectHTTPServer(_ server: MCPServerConfiguration, allowedDomains: [String]) -> MCPServerStatus {
    if mcpHttpClients[server.id] != nil {
      return MCPServerStatus(
        id: server.id,
        name: server.name,
        transport: server.transport,
        state: .running,
        message: "HTTP server is connected."
      )
    }
    do {
      let client = try connectOrCreateHTTPClient(server, allowedDomains: allowedDomains)
      _ = try client.initialize()
      return MCPServerStatus(
        id: server.id,
        name: server.name,
        transport: server.transport,
        state: .running,
        message: "HTTP endpoint connected."
      )
    } catch {
      stopMCPServer(id: server.id)
      return MCPServerStatus(
        id: server.id,
        name: server.name,
        transport: server.transport,
        state: .failed,
        message: error.localizedDescription
      )
    }
  }

  private func connectOrCreateClient(_ server: MCPServerConfiguration) throws -> MCPStdioClient {
    guard let command = server.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
      throw MCPClientError.notConnected
    }

    if let client = mcpClients[server.id] {
      return client
    }

    let client = try MCPStdioClient(
      command: command,
      arguments: server.arguments,
      workingDirectory: projectDirectory,
      sandbox: TerminalSandboxConfiguration.strict(
        workspaceURL: projectDirectory,
        scratchURL: FileManager.default.temporaryDirectory
          .appendingPathComponent("kimi-mcp-\(server.id.uuidString)", isDirectory: true)
      )
    )
    mcpClients[server.id] = client
    return client
  }

  private func connectOrCreateHTTPClient(_ server: MCPServerConfiguration, allowedDomains: [String]) throws -> MCPHttpClient {
    guard let endpoint = server.endpoint else {
      throw MCPClientError.notConnected
    }

    if let client = mcpHttpClients[server.id] {
      return client
    }

    let client = try MCPHttpClient(
      endpoint: endpoint,
      allowedDomains: allowedDomains
    )
    mcpHttpClients[server.id] = client
    return client
  }

  private func stopMCPServer(id: UUID) {
    mcpClients.removeValue(forKey: id)?.close()
    mcpHttpClients.removeValue(forKey: id)?.close()
  }
}

private struct HookProcessResult {
  let standardOutput: String
  let standardError: String
  let exitCode: Int32
  let timedOut: Bool
}

public enum SkillRegistry {
  public static func discover(projectDirectory: URL, additionalDirectories: [URL] = []) -> [SkillDescriptor] {
    let defaults = [
      projectDirectory.appendingPathComponent(".kimi/skills", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi-agent/skills", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi/plugins", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi-agent/plugins", isDirectory: true),
      projectDirectory.appendingPathComponent(".codex/skills", isDirectory: true)
    ]
    let manager = FileManager.default
    let files = (defaults + additionalDirectories).flatMap { directory -> [URL] in
      guard let enumerator = manager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { return [] }
      return enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "SKILL.md" }
    }

    return files.sorted { $0.path < $1.path }.map(descriptor(for:))
  }

  private static func descriptor(for fileURL: URL) -> SkillDescriptor {
    let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    let metadata = frontMatter(from: contents)
    return SkillDescriptor(
      name: metadata["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? fileURL.deletingLastPathComponent().lastPathComponent,
      description: metadata["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      fileURL: fileURL,
      entryPath: metadata["entry"]?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
      permissions: listValue(metadata["permissions"])
    )
  }

  private static func listValue(_ value: String?) -> [String] {
    guard let value else { return [] }
    return value
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func frontMatter(from contents: String) -> [String: String] {
    let lines = contents.components(separatedBy: .newlines)
    guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [:] }
    var result: [String: String] = [:]
    for line in lines.dropFirst() {
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
      let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
      if pieces.count == 2 {
        result[pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)] = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return result
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
