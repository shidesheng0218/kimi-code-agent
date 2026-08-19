import Foundation

public enum KimiRuntimeEventKind: String, Codable, Sendable {
  case sessionCreated
  case sessionUpdated
  case sessionStatus
  case sessionIdle
  case userText
  case assistantText
  case toolCall
  case toolResult
  case permissionAsked
  case permissionReplied
  case fileChanged
  case patchCreated
  case terminalCreated
  case mcpUpdated
  case subagentStarted
  case subagentCompleted
  case compacted
  case error
  case unknown
}

public struct KimiRuntimeEvent: Codable, Equatable, Sendable {
  public let id: UUID
  public let sessionID: String
  public let kind: KimiRuntimeEventKind
  public let text: String?
  public let toolCallID: String?
  public let toolID: String?
  public let requestID: String?
  public let payload: [String: String]
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    sessionID: String,
    kind: KimiRuntimeEventKind,
    text: String? = nil,
    toolCallID: String? = nil,
    toolID: String? = nil,
    requestID: String? = nil,
    payload: [String: String] = [:],
    createdAt: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.kind = kind
    self.text = text
    self.toolCallID = toolCallID
    self.toolID = toolID
    self.requestID = requestID
    self.payload = payload
    self.createdAt = createdAt
  }
}

public enum KimiRuntimeEventBridge {
  public static func map(_ event: KimiRuntimeEvent) -> [KimiEvent] {
    switch event.kind {
    case .assistantText:
      return event.text.map { [.assistantText($0)] } ?? []
    case .userText:
      return event.text.map { [.userText($0)] } ?? []
    case .sessionCreated, .sessionUpdated, .sessionStatus, .sessionIdle:
      return []
    case .toolCall:
      return [
        .activity(KimiActivity(
          title: event.toolID ?? "工具活动",
          detail: event.text,
          state: .running,
          toolCallID: event.toolCallID
        ))
      ]
    case .toolResult:
      return [
        .activity(KimiActivity(
          title: event.toolID ?? "工具活动",
          detail: event.text,
          state: .completed,
          toolCallID: event.toolCallID
        ))
      ]
    case .permissionAsked:
      return [
        .permission(KimiPermissionRequest(
          id: event.id,
          runtimeID: event.requestID,
          toolID: event.toolID ?? "unknown",
          reason: event.text ?? "需要确认工具操作。",
          patterns: event.payload["patterns"].map { [$0] } ?? []
        ))
      ]
    case .permissionReplied, .fileChanged, .patchCreated, .terminalCreated,
         .mcpUpdated, .subagentStarted, .subagentCompleted, .compacted, .unknown:
      return event.text.map { [.activity(KimiActivity(title: event.kind.rawValue, detail: $0, state: .completed))] } ?? []
    case .error:
      return [.error(event.text ?? "执行引擎出现错误。")]
    }
  }

  public static func decodeSSEData(_ data: Data, sessionID: String) -> KimiRuntimeEvent? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let rawType = (object["type"] as? String) ?? (object["event"] as? String) ?? "unknown"
    let properties = object["properties"] as? [String: Any] ?? object["data"] as? [String: Any] ?? object
    let nestedPart = properties["part"] as? [String: Any]
    let part = nestedPart ?? properties
    let partState = part["state"] as? [String: Any]
    let rawPartType = (part["type"] as? String)?.lowercased()
    var kind = mapKind(rawType)
    if rawType.lowercased().contains("text.delta") { kind = .assistantText }
    if rawType.lowercased().contains("reasoning.delta") { kind = .assistantText }
    if rawType.lowercased().contains("tool.called") || rawType.lowercased().contains("tool.input") { kind = .toolCall }
    if rawType.lowercased().contains("tool.success") || rawType.lowercased().contains("tool.failed") || rawType.lowercased().contains("tool.result") { kind = .toolResult }
    if rawPartType == "tool" {
      let status = (partState?["status"] as? String)?.lowercased()
      kind = (status == "completed" || status == "failed") ? .toolResult : .toolCall
    } else if rawPartType == "text" || rawPartType == "reasoning" {
      kind = .assistantText
    }
    let text = (properties["delta"] as? String)
      ?? (part["text"] as? String)
      ?? (part["content"] as? String)
      ?? (part["message"] as? String)
      ?? stringify(part["result"])
      ?? stringify(partState?["output"])
      ?? stringify(properties["error"])
    let toolCallID = properties["callID"] as? String
      ?? part["callID"] as? String
      ?? part["toolCallID"] as? String
    let toolID = properties["tool"] as? String
      ?? part["tool"] as? String
      ?? part["toolID"] as? String
    let eventSessionID = properties["sessionID"] as? String
      ?? part["sessionID"] as? String
      ?? sessionID
    let requestID = properties["id"] as? String
      ?? properties["requestID"] as? String
    var payload = properties.compactMapValues { $0 as? String }
    if let input = partState?["input"], let encoded = stringify(input) { payload["arguments"] = encoded }
    if let input = properties["input"], let encoded = stringify(input) { payload["arguments"] = encoded }
    if let status = partState?["status"] as? String { payload["status"] = status }
    if let error = properties["error"] { payload["error"] = stringify(error) ?? "error" }
    return KimiRuntimeEvent(
      sessionID: eventSessionID,
      kind: kind,
      text: text,
      toolCallID: toolCallID,
      toolID: toolID,
      requestID: requestID,
      payload: payload
    )
  }

  private static func stringify(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let value = value as? String { return value }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func mapKind(_ raw: String) -> KimiRuntimeEventKind {
    let value = raw.lowercased()
    if value.contains("session.idle") { return .sessionIdle }
    if value.contains("session.status") { return .sessionStatus }
    if value.contains("session.created") { return .sessionCreated }
    if value.contains("session.updated") { return .sessionUpdated }
    if value.contains("message.part") || value.contains("text") {
      return value.contains("user") ? .userText : .assistantText
    }
    if value.contains("tool") && value.contains("result") { return .toolResult }
    if value.contains("tool") || value.contains("call") { return .toolCall }
    if value.contains("permission") && (value.contains("reply") || value.contains("resolved")) { return .permissionReplied }
    if value.contains("permission") { return .permissionAsked }
    if value.contains("file") { return .fileChanged }
    if value.contains("patch") || value.contains("diff") { return .patchCreated }
    if value.contains("terminal") || value.contains("pty") { return .terminalCreated }
    if value.contains("mcp") { return .mcpUpdated }
    if value.contains("subagent") || value.contains("child") { return value.contains("complete") ? .subagentCompleted : .subagentStarted }
    if value.contains("compact") { return .compacted }
    if value.contains("error") { return .error }
    return .unknown
  }
}
