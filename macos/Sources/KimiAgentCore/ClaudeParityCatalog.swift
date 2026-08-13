import Foundation

public enum ClaudeCapabilityKind: String, Codable, CaseIterable, Sendable {
  case desktopWorkbench
  case terminalSession
  case worktreeIsolation
  case diffReview
  case planMode
  case subagents
  case skills
  case hooks
  case mcp
  case customCommands
  case memory
  case settings
  case browserUse
  case computerUse
  case githubAutomation
  case gitlabIntegration
  case sessionResume
  case loginAndIdentity
  case diagnostics
}

public enum ClaudeCapabilityLoop: String, Codable, CaseIterable, Sendable {
  case localOpenRun
  case planExecuteReview
  case inspectAcceptReject
  case configureAuthorizeRun
  case reviewVerifyMerge
  case resumeRecover
}

public struct ClaudeCapabilityDescriptor: Equatable, Codable, Sendable, Identifiable {
  public let id: String
  public let kind: ClaudeCapabilityKind
  public let title: String
  public let summary: String
  public let loop: ClaudeCapabilityLoop
  public let isImplemented: Bool

  public init(
    kind: ClaudeCapabilityKind,
    title: String,
    summary: String,
    loop: ClaudeCapabilityLoop,
    isImplemented: Bool
  ) {
    self.id = kind.rawValue
    self.kind = kind
    self.title = title
    self.summary = summary
    self.loop = loop
    self.isImplemented = isImplemented
  }
}

public struct ClaudeParityCapabilityCatalog: Equatable, Codable, Sendable {
  public let capabilities: [ClaudeCapabilityDescriptor]

  public static let defaultCatalog = ClaudeParityCapabilityCatalog(capabilities: [
    .init(kind: .desktopWorkbench, title: "原生桌面工作台", summary: "macOS 原生三栏界面、固定 Composer、事件流与 Inspector。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .terminalSession, title: "终端会话", summary: "本地 CLI/Host 回退执行，保留会话恢复。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .worktreeIsolation, title: "Worktree 隔离", summary: "每个可写任务默认独立 worktree。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .diffReview, title: "Diff 审阅", summary: "文件级 / hunk 级接受拒绝与评论。", loop: .inspectAcceptReject, isImplemented: true),
    .init(kind: .planMode, title: "Plan 模式", summary: "只读规划、执行和审阅分离。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .subagents, title: "Subagents", summary: "Analyzer、Implementer、Test Runner、Reviewer 角色分工。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .skills, title: "Skills", summary: "发现 SKILL.md 并注入项目技能。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .hooks, title: "Hooks", summary: "任务开始、工具前后、完成和失败钩子。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .mcp, title: "MCP", summary: "stdio/http 服务器配置与授权执行。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .customCommands, title: "自定义命令", summary: "把常用操作收进可复用命令入口。", loop: .configureAuthorizeRun, isImplemented: false),
    .init(kind: .memory, title: "记忆 / 规则", summary: "项目级和用户级长期规则入口。", loop: .resumeRecover, isImplemented: false),
    .init(kind: .settings, title: "设置", summary: "本地配置、权限和模型偏好。", loop: .resumeRecover, isImplemented: true),
    .init(kind: .browserUse, title: "浏览器使用", summary: "本地网页验证、截图和控制台反馈。", loop: .inspectAcceptReject, isImplemented: true),
    .init(kind: .computerUse, title: "Computer Use", summary: "系统级点击、输入与屏幕操作。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .githubAutomation, title: "GitHub 自动化", summary: "PR、评论、CI 反馈回流。", loop: .reviewVerifyMerge, isImplemented: true),
    .init(kind: .gitlabIntegration, title: "GitLab 集成", summary: "仓库、分支、MR 和流水线。", loop: .reviewVerifyMerge, isImplemented: true),
    .init(kind: .sessionResume, title: "会话恢复", summary: "重启后继续任务和子任务。", loop: .resumeRecover, isImplemented: true),
    .init(kind: .loginAndIdentity, title: "登录与身份", summary: "Kimi OAuth 与 Keychain 存储。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .diagnostics, title: "诊断", summary: "Runtime、Node、权限和 Computer Use 检查。", loop: .localOpenRun, isImplemented: true)
  ])
}
