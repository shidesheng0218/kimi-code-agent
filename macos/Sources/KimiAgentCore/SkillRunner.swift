import Foundation

public struct SkillExecutionResult: Codable, Equatable, Sendable {
  public let skillID: String
  public let entryPath: String
  public let standardOutput: String
  public let standardError: String
  public let exitCode: Int32
  public let timedOut: Bool
  public let startedAt: Date
  public let finishedAt: Date

  public init(
    skillID: String,
    entryPath: String,
    standardOutput: String,
    standardError: String,
    exitCode: Int32,
    timedOut: Bool,
    startedAt: Date,
    finishedAt: Date
  ) {
    self.skillID = skillID
    self.entryPath = entryPath
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

public enum SkillRunnerError: LocalizedError {
  case missingEntry(skillName: String)
  case missingExecutable(path: String)
  case denied(command: String)

  public var errorDescription: String? {
    switch self {
    case let .missingEntry(skillName):
      return "Skill \(skillName) 缺少可执行入口。"
    case let .missingExecutable(path):
      return "Skill 入口不存在：\(path)"
    case let .denied(command):
      return "Skill 执行被权限策略拒绝：\(command)"
    }
  }
}

public enum SkillRunner {
  public static func execute(
    skill: SkillDescriptor,
    projectDirectory: URL,
    task: AgentTask,
    timeoutSeconds: Int = 60,
    additionalEnvironment: [String: String] = [:]
  ) throws -> SkillExecutionResult {
    guard let entryURL = skill.entryURL else {
      throw SkillRunnerError.missingEntry(skillName: skill.name)
    }
    guard FileManager.default.fileExists(atPath: entryURL.path) else {
      throw SkillRunnerError.missingExecutable(path: entryURL.path)
    }

    let permissionPolicy = PermissionPolicy(workspacePath: projectDirectory.path)
    if permissionPolicy.decision(for: .executeCommand, command: entryURL.path) == .deny {
      throw SkillRunnerError.denied(command: entryURL.path)
    }

    let startedAt = Date()
    var environment = ProcessInfo.processInfo.environment
    environment.merge(additionalEnvironment, uniquingKeysWith: { _, new in new })
    environment["KIMI_AGENT_TASK_ID"] = task.id.uuidString
    environment["KIMI_AGENT_TASK_TITLE"] = task.title
    environment["KIMI_AGENT_TASK_MODE"] = task.mode.rawValue
    environment["KIMI_AGENT_WORKSPACE"] = task.workspacePath
    environment["KIMI_AGENT_SKILL_ID"] = skill.id
    environment["KIMI_AGENT_SKILL_NAME"] = skill.name
    environment["KIMI_AGENT_SKILL_DIR"] = skill.directoryURL.path
    let scratchURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kimi-skill-\(task.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
    let sandbox = TerminalSandboxConfiguration.strict(
      workspaceURL: projectDirectory,
      scratchURL: scratchURL,
      allowNetwork: false
    )
    let command = shellQuote(entryURL.path)
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
    try? FileManager.default.removeItem(at: scratchURL)
    return SkillExecutionResult(
      skillID: skill.id,
      entryPath: entryURL.path,
      standardOutput: result.standardOutput,
      standardError: result.standardError,
      exitCode: result.exitCode,
      timedOut: timedOut,
      startedAt: startedAt,
      finishedAt: Date()
    )
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
