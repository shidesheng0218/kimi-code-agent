import Foundation

public enum TaskIntent: String, Codable, CaseIterable, Sendable {
  case conversation
  case explanation
  case explore
  case plan
  case implement
  case debug
  case review
  case test
  case webResearch
  case browserVerification
  case computerUse
  case externalCollaboration
}

public struct IntentDecision: Codable, Equatable, Sendable {
  public let intent: TaskIntent
  public let confidence: Double
  public let requiresPlanning: Bool
  public let requiresApproval: Bool
  public let recommendedAgents: [AgentKind]

  public init(
    intent: TaskIntent,
    confidence: Double,
    requiresPlanning: Bool,
    requiresApproval: Bool,
    recommendedAgents: [AgentKind]
  ) {
    self.intent = intent
    self.confidence = min(max(confidence, 0), 1)
    self.requiresPlanning = requiresPlanning
    self.requiresApproval = requiresApproval
    self.recommendedAgents = recommendedAgents
  }
}

public enum TaskIntentRouter {
  public static func decide(for rawPrompt: String) -> IntentDecision {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !prompt.isEmpty else {
      return IntentDecision(intent: .conversation, confidence: 1, requiresPlanning: false, requiresApproval: false, recommendedAgents: [])
    }
    if greeting(prompt) {
      return IntentDecision(intent: .conversation, confidence: 0.98, requiresPlanning: false, requiresApproval: false, recommendedAgents: [])
    }
    if requiresFreshWebEvidence(prompt) {
      return IntentDecision(intent: .webResearch, confidence: 0.9, requiresPlanning: false, requiresApproval: false, recommendedAgents: [.webResearch])
    }
    if contains(prompt, ["搜索", "检索", "查一下", "查找资料", "web search", "fetchurl", "网页"]) {
      return IntentDecision(intent: .webResearch, confidence: 0.86, requiresPlanning: false, requiresApproval: false, recommendedAgents: [.webResearch])
    }
    if contains(prompt, ["浏览器", "点击网页", "截图", "页面验证", "browser"]) {
      return IntentDecision(intent: .browserVerification, confidence: 0.88, requiresPlanning: false, requiresApproval: true, recommendedAgents: [.browserVerification])
    }
    if contains(prompt, ["操作电脑", "点击", "输入密码", "computer use", "系统设置"]) {
      return IntentDecision(intent: .computerUse, confidence: 0.86, requiresPlanning: false, requiresApproval: true, recommendedAgents: [.computerUse])
    }
    if contains(prompt, ["审查", "review", "代码检查", "安全检查", "diff"]) {
      return IntentDecision(intent: .review, confidence: 0.84, requiresPlanning: true, requiresApproval: false, recommendedAgents: [.explore, .review])
    }
    if contains(prompt, ["测试", "test", "构建", "build", "验证"]) && !contains(prompt, ["修复", "实现", "改", "bug", "错误", "失败"]) {
      return IntentDecision(intent: .test, confidence: 0.8, requiresPlanning: true, requiresApproval: true, recommendedAgents: [.explore, .test])
    }
    if contains(prompt, ["修复", "bug", "错误", "失败", "崩溃", "不工作", "debug"]) {
      return IntentDecision(intent: .debug, confidence: 0.9, requiresPlanning: true, requiresApproval: true, recommendedAgents: [.explore, .debug, .test, .review])
    }
    if contains(prompt, ["实现", "开发", "新增", "修改", "重构", "写一个", "做一下", "完成", "优化"]) {
      return IntentDecision(intent: .implement, confidence: 0.84, requiresPlanning: true, requiresApproval: true, recommendedAgents: [.explore, .plan, .implement, .test, .review])
    }
    if contains(prompt, ["方案", "计划", "设计", "怎么做", "架构"]) {
      return IntentDecision(intent: .plan, confidence: 0.78, requiresPlanning: true, requiresApproval: false, recommendedAgents: [.explore, .plan, .review])
    }
    if prompt.count < 180 && contains(prompt, ["什么", "为什么", "如何", "能否", "区别", "解释"]) {
      return IntentDecision(intent: .explanation, confidence: 0.7, requiresPlanning: false, requiresApproval: false, recommendedAgents: [])
    }
    return IntentDecision(intent: .explore, confidence: 0.55, requiresPlanning: false, requiresApproval: false, recommendedAgents: [.explore])
  }

  private static func greeting(_ prompt: String) -> Bool {
    ["你好", "hi", "hello", "在吗", "嗨"].contains(prompt)
  }

  private static func contains(_ prompt: String, _ terms: [String]) -> Bool {
    terms.contains { prompt.contains($0) }
  }

  /// Questions about a changing external state must be backed by current
  /// evidence. Do not treat a generic "今天" as enough on its own: pairing it
  /// with a time-sensitive topic avoids turning ordinary conversation into an
  /// unnecessary research run.
  private static func requiresFreshWebEvidence(_ prompt: String) -> Bool {
    let freshnessTerms = ["今天", "今日", "明天", "明日", "后天", "未来", "接下来", "最新", "实时", "当前", "本周", "本月", "now", "today", "tomorrow", "latest", "current", "real-time"]
    let changingTopics = ["股市", "股票", "行情", "天气", "新闻", "汇率", "价格", "比分", "赛程", "票房", "市值", "排名", "热搜", "market", "stock", "weather", "news", "exchange rate", "score", "schedule", "price"]
    return contains(prompt, freshnessTerms) && contains(prompt, changingTopics)
  }
}

public struct TaskContract: Codable, Equatable, Sendable {
  public let goal: String
  public let scope: [String]
  public let nonGoals: [String]
  public let constraints: [String]
  public let acceptanceCriteria: [String]
  public let verificationPlan: [String]
  public let intent: TaskIntent

  public static func make(prompt: String, decision: IntentDecision, mode: TaskMode) -> TaskContract {
    let goal = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let writeConstraint = mode.isReadOnly ? "只读模式：禁止修改工作区文件。" : "所有写入默认限制在隔离 Worktree，保留可审阅 Diff。"
    let needsVerification = decision.intent == .implement || decision.intent == .debug || decision.intent == .test || decision.intent == .browserVerification || decision.intent == .computerUse
    return TaskContract(
      goal: goal,
      scope: decision.recommendedAgents.map(\.title),
      nonGoals: decision.intent == .conversation || decision.intent == .explanation ? ["不调用工具，除非用户明确要求。"] : ["不超出用户指定项目和任务范围。"],
      constraints: [writeConstraint],
      acceptanceCriteria: needsVerification ? ["变更满足用户目标。", "验证步骤有真实结果。"] : ["直接、准确地回答用户问题。"],
      verificationPlan: needsVerification ? ["运行最相关的测试、构建或浏览器验证。"] : [],
      intent: decision.intent
    )
  }

  public var promptText: String {
    [
      "任务契约：",
      "目标：\(goal)",
      scope.isEmpty ? nil : "阶段：\(scope.joined(separator: " → "))",
      "范围限制：\(nonGoals.joined(separator: "；"))",
      "约束：\(constraints.joined(separator: "；"))",
      "验收：\(acceptanceCriteria.joined(separator: "；"))",
      verificationPlan.isEmpty ? nil : "验证：\(verificationPlan.joined(separator: "；"))"
    ].compactMap { $0 }.joined(separator: "\n")
  }
}

public struct ProjectedContext: Equatable, Sendable {
  public let contract: TaskContract
  public let summary: String
  public let recentTurns: [ConversationTurn]
  public let tokenBudget: Int
  public let rules: [String]
  public let verifiedResults: [String]
  public let unresolved: [String]

  public var promptText: String {
    var sections: [String] = [contract.promptText]
    if !rules.isEmpty {
      sections.append("生效规则：\n" + rules.joined(separator: "\n"))
    }
    if !verifiedResults.isEmpty {
      sections.append("已验证证据：\n" + verifiedResults.joined(separator: "\n"))
    }
    if !unresolved.isEmpty {
      sections.append("未解决问题：\n" + unresolved.joined(separator: "\n"))
    }
    if !summary.isEmpty {
      sections.append("历史摘要：\(summary)")
    }
    if !recentTurns.isEmpty {
      let recentConversation = recentTurns
        .map { "用户：\($0.userMessage)\n助手：\($0.assistantMessage)" }
        .joined(separator: "\n\n")
      sections.append("最近对话：\n" + recentConversation)
    }
    return sections.joined(separator: "\n\n")
  }

  public init(
    contract: TaskContract,
    summary: String,
    recentTurns: [ConversationTurn],
    tokenBudget: Int,
    rules: [String] = [],
    verifiedResults: [String] = [],
    unresolved: [String] = []
  ) {
    self.contract = contract
    self.summary = summary
    self.recentTurns = recentTurns
    self.tokenBudget = tokenBudget
    self.rules = rules
    self.verifiedResults = verifiedResults
    self.unresolved = unresolved
  }
}

public enum ContextProjector {
  public static func project(
    turns: [ConversationTurn],
    contract: TaskContract,
    rules: [String] = [],
    verifiedResults: [String] = [],
    unresolved: [String] = [],
    tokenBudget: Int = 6_000
  ) -> ProjectedContext {
    let budget = max(400, tokenBudget)
    let ordered = turns.sorted { $0.sequence < $1.sequence }
    let estimatedContractTokens = max(120, contract.promptText.count / 3)
    let available = max(220, budget - estimatedContractTokens)
    var recent: [ConversationTurn] = []
    var used = 0
    for turn in ordered.reversed() where recent.count < 6 {
      let cost = max(16, (turn.userMessage.count + turn.assistantMessage.count) / 3)
      guard used + cost <= available * 2 / 3 else { continue }
      recent.insert(turn, at: 0)
      used += cost
    }
    let retainedIDs = Set(recent.map(\.id))
    let older = ordered.filter { !retainedIDs.contains($0.id) }
    let summaryBudget = max(0, available - used)
    let rawSummary = older.map { turn in
      let user = clipped(turn.userMessage, limit: 180)
      let assistant = clipped(turn.assistantMessage, limit: 220)
      return assistant.isEmpty ? "用户：\(user)" : "用户：\(user)；结论：\(assistant)"
    }.joined(separator: "\n")
    return ProjectedContext(
      contract: contract,
      summary: clipped(rawSummary, limit: summaryBudget * 3),
      recentTurns: recent,
      tokenBudget: budget,
      rules: rules.map { clipped($0, limit: 600) }.filter { !$0.isEmpty },
      verifiedResults: verifiedResults.map { clipped($0, limit: 800) }.filter { !$0.isEmpty },
      unresolved: unresolved.map { clipped($0, limit: 600) }.filter { !$0.isEmpty }
    )
  }

  private static func clipped(_ text: String, limit: Int) -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard limit > 0, normalized.count > limit else { return limit > 0 ? normalized : "" }
    return String(normalized.prefix(limit)) + "…"
  }
}

public enum FinalAnswerOutcome: String, Codable, Sendable {
  case completed
  case failed
  case partial
}

public enum FinalAnswerComposer {
  public static func compose(
    outcome: FinalAnswerOutcome,
    summary: String,
    changedFiles: [String],
    verification: [String],
    risks: [String]
  ) -> String {
    let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    switch outcome {
    case .completed:
      var blocks = ["已完成：\n\(cleanSummary.isEmpty ? "任务已完成。" : cleanSummary)"]
      if !changedFiles.isEmpty { blocks.append("改动：\n" + changedFiles.map { "- \($0)" }.joined(separator: "\n")) }
      blocks.append("验证：\n" + (verification.isEmpty ? "- 尚未执行自动验证。" : verification.map { "- \($0)" }.joined(separator: "\n")))
      if !risks.isEmpty { blocks.append("注意：\n" + risks.map { "- \($0)" }.joined(separator: "\n")) }
      return blocks.joined(separator: "\n\n")
    case .partial:
      return "部分完成：\n\(cleanSummary)\n\n仍需处理：\n" + (risks.isEmpty ? "- 请继续验证剩余步骤。" : risks.map { "- \($0)" }.joined(separator: "\n"))
    case .failed:
      return "未完成：\n\(cleanSummary.isEmpty ? "执行没有完成。" : cleanSummary)\n\n原因：\n" + (risks.isEmpty ? "- 请查看失败上下文后重试。" : risks.map { "- \($0)" }.joined(separator: "\n"))
    }
  }
}
