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
    .init(kind: .desktopWorkbench, title: "原生桌面工作台", summary: "macOS 原生三栏界面、统一时间线对话、Todo 清单与 Inspector。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .terminalSession, title: "终端会话", summary: "右侧本机交互终端（不经权限门），Agent Shell 由引擎权限管控。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .worktreeIsolation, title: "Worktree 隔离", summary: "引擎提供 worktree 沙箱端点，但尚未接入会话；当前会话直接在项目目录执行，改动经 Diff 审阅后人工合并。", loop: .planExecuteReview, isImplemented: false),
    .init(kind: .diffReview, title: "Diff 审阅", summary: "Diff 面板实时渲染工作区改动（文件/hunk 级）；合并保持人工。", loop: .inspectAcceptReject, isImplemented: true),
    .init(kind: .planMode, title: "Plan 模式", summary: "引擎支持 plan agent，UI 尚未暴露模式切换。", loop: .planExecuteReview, isImplemented: false),
    .init(kind: .subagents, title: "Subagents", summary: "引擎原生 task 子代理，活动卡展示运行与结算状态。", loop: .planExecuteReview, isImplemented: true),
    .init(kind: .skills, title: "Skills", summary: "引擎发现项目与插件技能，集成面板展示。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .hooks, title: "Hooks", summary: "引擎配置层支持 hooks，尚未在 UI 暴露。", loop: .configureAuthorizeRun, isImplemented: false),
    .init(kind: .mcp, title: "MCP", summary: "引擎管理 MCP 服务器，集成面板展示连接状态。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .customCommands, title: "自定义命令", summary: "Slash 命令补全与执行（含项目级命令发现）。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .memory, title: "记忆 / 规则", summary: "项目级和用户级长期规则入口。", loop: .resumeRecover, isImplemented: false),
    .init(kind: .settings, title: "设置", summary: "本地配置、权限和模型偏好。", loop: .resumeRecover, isImplemented: true),
    .init(kind: .browserUse, title: "浏览器使用", summary: "WKWebView 验证、截图产物回流与展示。", loop: .inspectAcceptReject, isImplemented: true),
    .init(kind: .computerUse, title: "Computer Use", summary: "系统级点击、输入与屏幕操作（逐次审批）。", loop: .configureAuthorizeRun, isImplemented: true),
    .init(kind: .githubAutomation, title: "GitHub 自动化", summary: "凭据存储就绪，UI 入口未接。", loop: .reviewVerifyMerge, isImplemented: false),
    .init(kind: .gitlabIntegration, title: "GitLab 集成", summary: "凭据存储就绪，UI 入口未接。", loop: .reviewVerifyMerge, isImplemented: false),
    .init(kind: .sessionResume, title: "会话恢复", summary: "重启/切换后从引擎消息日志重建对话、Todo 与活动。", loop: .resumeRecover, isImplemented: true),
    .init(kind: .loginAndIdentity, title: "登录与身份", summary: "Kimi OAuth 与 Keychain 存储。", loop: .localOpenRun, isImplemented: true),
    .init(kind: .diagnostics, title: "诊断", summary: "Runtime、Node、权限和 Computer Use 检查。", loop: .localOpenRun, isImplemented: true)
  ])
}
