import Foundation

public enum ExtensionRowSeverity: String, Codable, CaseIterable, Sendable {
  case neutral
  case success
  case warning
  case destructive
}

public struct ExtensionManagementRow: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let detail: String
  public let statusText: String
  public let severity: ExtensionRowSeverity
  public let details: [String]

  public init(
    id: String,
    title: String,
    detail: String,
    statusText: String,
    severity: ExtensionRowSeverity,
    details: [String] = []
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.statusText = statusText
    self.severity = severity
    self.details = details
  }
}

public struct ExtensionManagementSection: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let summary: String
  public let rows: [ExtensionManagementRow]

  public init(id: String, title: String, summary: String, rows: [ExtensionManagementRow]) {
    self.id = id
    self.title = title
    self.summary = summary
    self.rows = rows
  }
}

public struct ExtensionManagementPresentation: Codable, Equatable, Sendable {
  public let title: String
  public let subtitle: String
  public let sections: [ExtensionManagementSection]

  public init(
    configuration: ProjectAgentConfiguration?,
    discoveredSkills: [SkillDescriptor],
    hookResults: [HookResult],
    mcpStatuses: [MCPServerStatus],
    plugins: [KimiPluginDescriptor] = []
  ) {
    title = "扩展管理"
    subtitle = Self.makeSubtitle(
      skillCount: discoveredSkills.count,
      hookCount: configuration?.hooks.count ?? 0,
      mcpCount: configuration?.mcpServers.count ?? mcpStatuses.count,
      pluginCount: plugins.count
    )
    sections = [
      ExtensionManagementSection(
        id: "plugins",
        title: "Plugins",
        summary: plugins.isEmpty ? "未发现 Plugins" : "(plugins.count) 个已发现",
        rows: Self.makePluginRows(plugins: plugins)
      ),
      ExtensionManagementSection(
        id: "skills",
        title: "Skills",
        summary: Self.makeSkillSummary(configuration: configuration, skills: discoveredSkills),
        rows: Self.makeSkillRows(skills: discoveredSkills)
      ),
      ExtensionManagementSection(
        id: "hooks",
        title: "Hooks",
        summary: Self.makeHookSummary(configuration: configuration, hookResults: hookResults),
        rows: Self.makeHookRows(configuration: configuration, hookResults: hookResults)
      ),
      ExtensionManagementSection(
        id: "mcp",
        title: "MCP",
        summary: Self.makeMCPSummary(configuration: configuration, mcpStatuses: mcpStatuses),
        rows: Self.makeMCPRows(configuration: configuration, statuses: mcpStatuses)
      )
    ]
  }

  private static func makeSubtitle(skillCount: Int, hookCount: Int, mcpCount: Int, pluginCount: Int) -> String {
    "\(pluginCount) 个 Plugins · \(skillCount) 个技能 · \(hookCount) 个 Hooks · \(mcpCount) 个 MCP"
  }

  private static func makePluginRows(plugins: [KimiPluginDescriptor]) -> [ExtensionManagementRow] {
    plugins.map { plugin in
      ExtensionManagementRow(
        id: plugin.id,
        title: plugin.manifest.name,
        detail: "v\(plugin.manifest.version) · \(plugin.scope.rawValue)",
        statusText: plugin.isEnabled ? "enabled" : "disabled",
        severity: plugin.isEnabled ? .success : .warning,
        details: [
          "插件 ID \(plugin.manifest.id)",
          "版本 \(plugin.manifest.version)",
          "范围 \(plugin.scope.rawValue)",
          plugin.manifest.capabilities.isEmpty ? "未声明扩展能力" : "能力 \(plugin.manifest.capabilities.joined(separator: " · "))",
          plugin.rootURL.path
        ]
      )
    }
  }

  private static func makeSkillSummary(
    configuration: ProjectAgentConfiguration?,
    skills: [SkillDescriptor]
  ) -> String {
    if skills.isEmpty {
      let configured = configuration?.skillsDirectories.count ?? 0
      return configured == 0 ? "未发现 Skills" : "已配置 \(configured) 个目录，未发现 Skills"
    }
    let executableCount = skills.filter { $0.entryURL != nil }.count
    return "\(skills.count) 个 Skills · \(executableCount) 个可执行"
  }

  private static func makeHookSummary(
    configuration: ProjectAgentConfiguration?,
    hookResults: [HookResult]
  ) -> String {
    let hookCount = configuration?.hooks.count ?? 0
    let blockedCount = hookResults.filter { $0.decision == .block }.count
    if hookCount == 0 {
      return "未配置 Hooks"
    }
    return "\(hookCount) 个 Hooks · \(blockedCount) 个阻断"
  }

  private static func makeMCPSummary(
    configuration: ProjectAgentConfiguration?,
    mcpStatuses: [MCPServerStatus]
  ) -> String {
    let configured = configuration?.mcpServers.count ?? mcpStatuses.count
    let running = mcpStatuses.filter { $0.state == .running }.count
    if configured == 0 {
      return "未配置 MCP"
    }
    return "\(configured) 个 MCP · \(running) 个运行中"
  }

  private static func makeSkillRows(skills: [SkillDescriptor]) -> [ExtensionManagementRow] {
    skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { skill in
      let detail = skill.entryPath.map { "入口 \($0)" } ?? "没有可执行入口"
      let statusText = skill.permissions.isEmpty ? "未声明权限" : skill.permissions.joined(separator: " · ")
      let severity: ExtensionRowSeverity = skill.entryPath == nil ? .warning : .success
      return ExtensionManagementRow(
        id: skill.id,
        title: skill.name,
        detail: detail,
        statusText: statusText,
        severity: severity,
        details: [
          "路径 \(skill.directoryURL.path)",
          skill.entryPath.map { "入口 \($0)" } ?? "入口未配置",
          skill.permissions.isEmpty ? "权限未声明" : "权限 \(skill.permissions.joined(separator: " · "))"
        ]
      )
    }
  }

  private static func makeHookRows(
    configuration: ProjectAgentConfiguration?,
    hookResults: [HookResult]
  ) -> [ExtensionManagementRow] {
    guard let hooks = configuration?.hooks else { return [] }
    let latestResultsByHookID = Dictionary(grouping: hookResults, by: \.hookID)
      .compactMapValues { $0.last }
    return hooks.enumerated().map { index, hook in
      let latestResult = latestResultsByHookID[hook.id]
      let detail = truncate(hook.command, limit: 48)
      let statusText: String
      let severity: ExtensionRowSeverity
      if let latestResult {
        statusText = latestResult.decision == .block ? "blocked" : "allow"
        severity = latestResult.decision == .block ? .warning : .success
      } else {
        statusText = hook.behavior.rawValue
        severity = hook.behavior == .block ? .warning : .neutral
      }
      return ExtensionManagementRow(
        id: hook.id.uuidString + "-\(index)",
        title: hook.event.rawValue,
        detail: detail,
        statusText: statusText,
        severity: severity,
        details: [
          "事件 \(hook.event.rawValue)",
          "行为 \(hook.behavior.rawValue)",
          "超时 \(hook.timeoutSeconds) 秒",
          latestResult.map { "最近 \($0.decision == .block ? "阻断" : "允许")" } ?? "尚未执行"
        ]
      )
    }
  }

  private static func makeMCPRows(
    configuration: ProjectAgentConfiguration?,
    statuses: [MCPServerStatus]
  ) -> [ExtensionManagementRow] {
    let fallbackRows = configuration?.mcpServers.map { server in
      ExtensionManagementRow(
        id: server.id.uuidString,
        title: server.name,
        detail: server.transport.rawValue,
        statusText: server.isEnabled ? "stopped" : "disabled",
        severity: server.isEnabled ? .neutral : .warning,
        details: [
          "传输 \(server.transport.rawValue)",
          server.command.map { "命令 \($0)" } ?? "命令未配置",
          server.endpoint.map { "端点 \($0.absoluteString)" } ?? "端点未配置"
        ]
      )
    } ?? []

    guard !statuses.isEmpty else { return fallbackRows }
    return statuses.map { status in
      ExtensionManagementRow(
        id: status.id.uuidString,
        title: status.name,
        detail: status.message.isEmpty ? status.transport.rawValue : status.message,
        statusText: status.state.rawValue,
        severity: severity(for: status.state),
        details: [
          "传输 \(status.transport.rawValue)",
          "状态 \(status.state.rawValue)",
          status.message.isEmpty ? "暂无附加信息" : status.message
        ]
      )
    }
  }

  private static func severity(for state: MCPServerState) -> ExtensionRowSeverity {
    switch state {
    case .running:
      return .success
    case .failed:
      return .destructive
    case .disabled:
      return .warning
    case .stopped:
      return .neutral
    }
  }

  private static func truncate(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit - 1)) + "…"
  }
}
