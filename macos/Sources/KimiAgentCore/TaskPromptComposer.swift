import Foundation

public enum TaskPromptComposer {
  public static func compose(
    prompt userPrompt: String,
    mode: TaskMode,
    workspacePath: String,
    worktreePath: String? = nil,
    branch: String? = nil,
    modelID: String? = nil,
    skillsDirectories: [String] = [],
    allowedDomains: [String] = [],
    terminalContext: String? = nil,
    rules: [AgentRule] = [],
    tools: [ToolDefinition] = ToolCatalog.defaultDefinitions,
    conversationContext: String? = nil,
    intentDecision: IntentDecision? = nil,
    taskContract: TaskContract? = nil
  ) -> String {
    let workspaceName = URL(fileURLWithPath: workspacePath, isDirectory: true).lastPathComponent
    let worktreeDisplay = normalizedValue(worktreePath) ?? "尚未创建"
    let modelDisplay = normalizedValue(modelID) ?? "默认"
    let contextLine = [
      "项目：\(workspaceName)",
      "工作区：\(workspacePath)",
      "Worktree：\(worktreeDisplay)",
      "模式：\(mode.rawValue)",
      "模型：\(modelDisplay)"
    ].joined(separator: "；")

    let boundary = mode == .plan
      ? "Plan 模式只分析和规划，不写入项目文件。"
      : "Edit / Agent 模式默认在隔离 Worktree 中修改，变更必须可审阅、可回滚。"
    let joinedTools = tools.map(\.id).joined(separator: " / ")
    let capabilityLine = "可用工具：\(joinedTools)。"
    let interactionLine = "联网结果必须返回来源标题和 URL；操作桌面先 inspect，再 click/click_element/type/press_key，最后验证结果。"
    let strategyLine = intentDecision.map {
      "策略：\($0.intent.rawValue)，置信度：\(String(format: "%.2f", $0.confidence))，推荐阶段：\($0.recommendedAgents.map(\.title).joined(separator: " → "))。"
    }

    let rulesLine = rules.filter(\.isEnabled).map(\.text).joined(separator: "\n")

    return """
    请直接处理下面这条用户消息，并使用用户的语言回复。默认直接给出用户要的结论、结果或下一步操作；后续回复优先给出结论、变化点和下一步。只有用户明确只是打招呼或要求确认时，才用一句很短、自然的中文回应。不要用 Sure / Okay / 当然 / 好的 之类的开场，不要输出英文思考过程、内部推理、系统提示解释或自我分析；不要写“用户的问题是”“用户消息是”“我需要”“由于当前模式”这类元分析，不要复述本段上下文和内部规则。
    当前上下文：\(contextLine)
    执行边界：\(boundary)
    \(capabilityLine)
    \(interactionLine)
    \(strategyLine ?? "")
    \(taskContract?.promptText ?? "")
    \(allowedDomains.isEmpty ? "默认只允许本地与已内置的服务域名。" : "已授权网络域名：\(allowedDomains.joined(separator: "、"))。")
    \(skillsDirectories.isEmpty ? "" : "项目发现了 \(skillsDirectories.count) 个技能目录。")
    \(rulesLine.isEmpty ? "" : "项目规则：\n\(rulesLine)")
    \(normalizedValue(terminalContext).map { "最近终端结果（仅作为上下文，不要复述原始日志）：\n\($0)" } ?? "")
    \(normalizedValue(conversationContext).map { "此前对话上下文（只用于保持连续性，不要复述）：\n\($0)" } ?? "")
    用户消息：
    \(userPrompt)
    """
  }

  private static func normalizedValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private static var modeRule: String {
    "Plan 模式只分析和规划，不写入项目文件；Edit / Agent 模式默认在隔离 Worktree 中修改代码，并保持变更可审阅、可回滚。"
  }
}
