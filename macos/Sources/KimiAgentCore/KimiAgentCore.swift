import Foundation

public enum TaskMode: String, CaseIterable, Codable, Sendable {
  case plan
  case edit
  case agent

  public var isReadOnly: Bool {
    self == .plan
  }

  public var permissionBadgeTitle: String {
    isReadOnly ? "只读" : "操作需确认"
  }

  public var permissionBadgeSymbol: String {
    isReadOnly ? "eye" : "hand.raised"
  }

  public var permissionBadgeHint: String {
    switch self {
    case .plan:
      "只读模式不会写入项目文件，适合分析、规划和审阅。"
    case .edit:
      "Edit 模式适合明确的代码修改；高风险操作仍需确认。"
    case .agent:
      "Agent 模式适合连续执行任务；写入、命令和系统操作都会走权限策略。"
    }
  }
}

public enum KimiPermissionMode: Sendable {
  case interactive
  case automatic
}

public struct KimiCommand: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]

  public init(executableURL: URL, arguments: [String]) {
    self.executableURL = executableURL
    self.arguments = arguments
  }
}

public enum KimiCommandBuilder {
  public static func makeLoginCommand(
    runtimePath: String,
    nodeExecutable: String = "node"
  ) -> KimiCommand {
    KimiCommand(
      executableURL: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [nodeExecutable, runtimePath, "login"]
    )
  }

  public static func makeCommand(
    runtimePath: String,
    prompt: String,
    mode: TaskMode,
    permission: KimiPermissionMode = .interactive,
    nodeExecutable: String = "node",
    modelID: String? = nil,
    skillsDirectories: [String] = []
  ) -> KimiCommand {
    var arguments = [
      nodeExecutable,
      runtimePath,
      "--prompt",
      prompt,
      "--output-format",
      "stream-json"
    ]

    if mode == .plan {
      // Prompt mode cannot be combined with --plan in Kimi Code 0.33.x.
      // The built-in plan agent exposes the same read-only tool boundary
      // while remaining compatible with structured prompt execution.
      arguments += ["--agent", "plan"]
    }

    // Kimi Code 0.33.x runs prompt mode with an automatic approval handler
    // internally and rejects --auto/--yolo when --prompt is present. The
    // desktop confirmation happens before this command is created, so the
    // permission value remains part of the API without emitting a conflicting
    // CLI flag.
    _ = permission

    if let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      arguments += ["--model", modelID]
    }

    for directory in skillsDirectories where !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      arguments += ["--skills-dir", directory]
    }

    return KimiCommand(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: arguments)
  }
}
