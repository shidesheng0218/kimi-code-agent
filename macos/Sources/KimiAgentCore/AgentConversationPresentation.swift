import Foundation

public enum AgentConversationRole: String, Equatable, Sendable {
  case user
  case assistant
  case status
}

public enum AgentConversationTone: String, Equatable, Sendable {
  case normal
  case muted
  case success
  case warning
  case error
}

public struct AgentConversationEntry: Identifiable, Equatable, Sendable {
  public let id: String
  public let role: AgentConversationRole
  public var text: String
  public var tone: AgentConversationTone
  public var sourceEventIDs: [UUID]

  public init(
    id: String,
    role: AgentConversationRole,
    text: String,
    tone: AgentConversationTone = .normal,
    sourceEventIDs: [UUID] = []
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.tone = tone
    self.sourceEventIDs = sourceEventIDs
  }
}

public enum AgentConversationPresentation {
  public static func entries(for task: AgentTask) -> [AgentConversationEntry] {
    if !task.turns.isEmpty {
      return entriesForTurns(task)
    }

    var entries: [AgentConversationEntry] = []
    appendUser(task.title, id: "task-\(task.id.uuidString)", sourceEventID: nil, to: &entries)

    for event in task.structuredEvents.sorted(by: { $0.sequence < $1.sequence }) {
      switch event.kind {
      case .output:
        appendOutput(event, to: &entries)
      case .error:
        appendStatus(
          text: presentableError(event.payload["text"] ?? event.payload["message"] ?? "运行出现错误。"),
          tone: .error,
          event: event,
          to: &entries
        )
      case .toolRequested, .commandRequested:
        appendStatus(
          text: "请求工具：\(event.payload["name"] ?? event.payload["action"] ?? event.payload["id"] ?? "Tool")",
          tone: event.requiresApproval ? .warning : .muted,
          event: event,
          to: &entries
        )
      case .toolStarted, .commandStarted:
        appendStatus(
          text: "正在执行：\(event.payload["name"] ?? event.payload["command"] ?? "工具")",
          tone: .muted,
          event: event,
          to: &entries
        )
      case .toolFinished, .commandFinished:
        appendStatus(
          text: "工具完成：\(event.payload["name"] ?? event.payload["id"] ?? "Tool")",
          tone: .success,
          event: event,
          to: &entries
        )
      case .permissionRequested:
        appendStatus(
          text: "等待确认：\(event.payload["action"] ?? "工具操作")",
          tone: .warning,
          event: event,
          to: &entries
        )
      case .permissionApproved:
        appendStatus(
          text: "已批准：\(event.payload["action"] ?? "工具操作")",
          tone: .success,
          event: event,
          to: &entries
        )
      case .permissionDenied:
        appendStatus(
          text: "已拒绝：\(event.payload["action"] ?? "工具操作")",
          tone: .error,
          event: event,
          to: &entries
        )
      case .toolProgress, .taskStarted, .sessionResumed, .verificationStarted, .verificationStepFinished, .verificationPassed, .verificationFailed, .diffGenerated:
        if let text = displayText(for: event), !isTransientText(text) {
          appendStatus(text: text, tone: statusTone(for: event.kind), event: event, to: &entries)
        }
      default:
        break
      }
    }

    return entries
  }

  private static func entriesForTurns(_ task: AgentTask) -> [AgentConversationEntry] {
    var entries: [AgentConversationEntry] = []
    let orderedTurns = task.turns.sorted { $0.sequence < $1.sequence }
    let orderedEvents = task.structuredEvents.sorted { $0.sequence < $1.sequence }

    for turn in orderedTurns {
      appendUser(turn.userMessage, id: "turn-user-\(turn.id.uuidString)", sourceEventID: nil, to: &entries)
      let events = orderedEvents.filter { $0.turnID == turn.id }
      var assistantEventCount = 0
      var lastAssistantEvent: AgentEvent?
      for event in events {
        switch event.kind {
        case .output:
          if event.payload["role"] == "user" { continue }
          if event.payload["contentType"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "thinking" {
            continue
          }
          // Tool activity belongs to the collapsible run-details panel. Assistant output is
          // always aggregated per turn before display, so streamed reasoning chunks cannot leak.
          assistantEventCount += 1
          lastAssistantEvent = event
        case .error:
          appendStatus(
            text: presentableError(event.payload["text"] ?? event.payload["message"] ?? "运行出现错误。"),
            tone: .error,
            event: event,
            to: &entries
          )
        case .toolRequested, .commandRequested, .permissionRequested,
             .toolStarted, .commandStarted, .toolFinished, .commandFinished,
             .permissionApproved, .permissionDenied,
             .verificationStarted, .verificationStepFinished,
             .verificationPassed, .verificationFailed, .diffGenerated:
          // Activity is rendered in the collapsible run-details panel, not as chat messages.
          continue
        case .toolProgress:
          if let text = displayText(for: event), !isTransientText(text) {
            appendStatus(text: text, tone: statusTone(for: event.kind), event: event, to: &entries)
          }
        default:
          break
        }
      }
      if assistantEventCount > 0 {
        let collapsedSource = assistantTranscript(from: events, fallback: turn.assistantMessage)
        let collapsedText = AssistantReplySanitizer.finalConversationText(
          from: collapsedSource
        ) ?? ""
        if !collapsedText.isEmpty {
          appendAssistant(
            collapsedText,
            id: "turn-assistant-\(turn.id.uuidString)",
            event: lastAssistantEvent ?? events.last ?? syntheticCollapseEvent(for: turn),
            to: &entries
          )
        }
      } else if assistantEventCount == 0,
                !turn.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let assistantText = AssistantReplySanitizer.finalConversationText(from: turn.assistantMessage) ?? turn.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.append(AgentConversationEntry(
          id: "turn-assistant-\(turn.id.uuidString)",
          role: .assistant,
          text: presentableError(assistantText)
        ))
      } else if assistantEventCount == 0,
                turn.assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                events.isEmpty,
                turn.status == .queued || turn.status == .running || turn.status == .retrying {
        entries.append(AgentConversationEntry(
          id: "turn-pending-\(turn.id.uuidString)",
          role: .status,
          text: turn.status == .running ? "Kimi 正在回复…" : "Kimi 正在准备回复…",
          tone: .muted
        ))
      }
      if let errorMessage = turn.errorMessage, !errorMessage.isEmpty,
         !entries.contains(where: { $0.id == "turn-error-\(turn.id.uuidString)" }) {
        entries.append(AgentConversationEntry(
          id: "turn-error-\(turn.id.uuidString)",
          role: .status,
          text: presentableError(errorMessage),
          tone: .error
        ))
      }
    }
    return entries
  }

  private static func appendActivityStatus(_ event: AgentEvent, to entries: inout [AgentConversationEntry]) {
    let text: String
    switch event.kind {
    case .toolRequested, .commandRequested:
      text = "请求工具：\(event.payload["name"] ?? event.payload["action"] ?? "工具操作")"
    case .toolStarted, .commandStarted:
      text = "正在执行：\(event.payload["name"] ?? event.payload["command"] ?? "工具操作")"
    case .toolFinished, .commandFinished:
      text = "已完成：\(event.payload["name"] ?? event.payload["id"] ?? "工具操作")"
    case .permissionRequested:
      text = "等待确认：\(event.payload["action"] ?? "工具操作")"
    case .permissionApproved:
      text = "已批准：\(event.payload["action"] ?? "工具操作")"
    case .permissionDenied:
      text = "已拒绝：\(event.payload["action"] ?? "工具操作")"
    case .verificationStarted, .verificationStepFinished:
      text = event.payload["text"] ?? "正在验证"
    case .verificationPassed:
      text = event.payload["text"] ?? "验证通过"
    case .verificationFailed:
      text = event.payload["text"] ?? "验证失败"
    case .diffGenerated:
      text = event.payload["text"] ?? "已生成变更审阅"
    default:
      return
    }
    appendStatus(text: text, tone: statusTone(for: event.kind), event: event, to: &entries)
  }

  private static func appendOutput(_ event: AgentEvent, to entries: inout [AgentConversationEntry]) {
    if event.payload["role"] == "user" {
      guard let text = displayText(for: event), !text.isEmpty, !isTransientText(text) else { return }
      appendUser(text, id: event.id.uuidString, sourceEventID: event.id, to: &entries)
      return
    }
    if event.actor == "desktop" {
      guard let text = displayText(for: event), !text.isEmpty, !isTransientText(text) else { return }
      appendStatus(text: text, tone: .muted, event: event, to: &entries)
      return
    }
    guard let assistantText = assistantVisibleText(for: event), !assistantText.isEmpty, !isTransientText(assistantText) else { return }
    appendAssistant(assistantText, event: event, to: &entries)
  }

  private static func assistantVisibleText(for event: AgentEvent) -> String? {
    guard let text = displayText(for: event) else { return nil }
    return AssistantReplySanitizer.finalConversationText(from: text, contentType: event.payload["contentType"])
  }

  private static func appendUser(
    _ rawText: String,
    id: String,
    sourceEventID: UUID?,
    to entries: inout [AgentConversationEntry]
  ) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if let last = entries.last, last.role == .user,
       normalizeComparableText(last.text) == normalizeComparableText(text) { return }
    entries.append(AgentConversationEntry(
      id: id,
      role: .user,
      text: text,
      sourceEventIDs: sourceEventID.map { [$0] } ?? []
    ))
  }

  private static func appendAssistant(
    _ text: String,
    id: String? = nil,
    event: AgentEvent,
    to entries: inout [AgentConversationEntry]
  ) {
    if let lastIndex = entries.indices.last, entries[lastIndex].role == .assistant {
      entries[lastIndex].text += text
      entries[lastIndex].sourceEventIDs.append(event.id)
      return
    }
    entries.append(AgentConversationEntry(
      id: id ?? event.id.uuidString,
      role: .assistant,
      text: text,
      sourceEventIDs: [event.id]
    ))
  }

  private static func appendStatus(
    text rawText: String,
    tone: AgentConversationTone,
    event: AgentEvent,
    to entries: inout [AgentConversationEntry]
  ) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    entries.append(AgentConversationEntry(
      id: event.id.uuidString,
      role: .status,
      text: text,
      tone: tone,
      sourceEventIDs: [event.id]
    ))
  }

  private static func displayText(for event: AgentEvent) -> String? {
    if let text = event.payload["text"] { return text }
    if let message = event.payload["message"] { return message }
    if let version = event.payload["version"] { return "Kimi Runtime \(version)" }
    return nil
  }

  private static func assistantTranscript(from events: [AgentEvent], fallback: String) -> String {
    let outputChunks = events.compactMap { event -> String? in
      guard event.kind == .output, event.actor != "desktop", event.payload["role"] != "user" else { return nil }
      guard event.payload["contentType"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "thinking" else { return nil }
      return displayText(for: event)
    }
    if !outputChunks.isEmpty {
      // ACP text updates are incremental chunks. Inserting paragraph separators between
      // chunks changes the meaning of short Chinese labels (for example “首页第一句”
      // + “可见文本”) and lets the sanitizer select a fragment instead of the reply.
      return outputChunks.joined()
    }
    return fallback
  }

  private static func isToolOrWorkflowEvent(_ event: AgentEvent) -> Bool {
    switch event.kind {
    case .toolRequested, .toolStarted, .toolFinished, .toolProgress,
         .commandRequested, .commandStarted, .commandFinished,
         .permissionRequested, .permissionApproved, .permissionDenied,
         .verificationStarted, .verificationStepFinished, .verificationPassed, .verificationFailed,
         .diffGenerated:
      return true
    default:
      return false
    }
  }

  private static func syntheticCollapseEvent(for turn: ConversationTurn) -> AgentEvent {
    AgentEvent(
      sessionID: UUID(),
      taskID: UUID(),
      turnID: turn.id,
      sequence: 0,
      actor: "desktop",
      kind: .output,
      payload: ["text": turn.assistantMessage, "contentType": "text"]
    )
  }

  private static func isTransientText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "正在思考…" || trimmed == "正在思考..." || trimmed == "Kimi 输出"
  }

  private static func statusTone(for kind: AgentEventKind) -> AgentConversationTone {
    switch kind {
    case .verificationPassed:
      .success
    case .verificationFailed:
      .error
    case .permissionRequested:
      .warning
    default:
      .muted
    }
  }

  private static func cleanError(_ text: String) -> String {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix("错误：") {
      value.removeFirst("错误：".count)
      value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.isEmpty ? "运行出现错误。" : value
  }

  public static func presentableError(_ text: String) -> String {
    let value = cleanError(text)
    if isLegacyLongWebSearchQueryFailure(value) {
      return "旧版联网失败记录：当时把整段任务提示误当成搜索词，导致查询过长。请点击重试或新建同样问题，当前版本会只使用真实用户问题搜索。"
    }
    return value
  }

  private static func isLegacyLongWebSearchQueryFailure(_ text: String) -> Bool {
    text.lowercased().contains("web search") && text.contains("查询不能超过 500 个字符")
  }

  private static func normalizeComparableText(_ text: String) -> String {
    text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "。", with: ".")
  }
}
