import Foundation

public struct KimiStreamEventParser: Sendable {
  public let sessionID: UUID
  public let taskID: UUID
  public let turnID: UUID?
  private var sequence: Int64

  public init(sessionID: UUID, taskID: UUID, turnID: UUID? = nil, sequence: Int64 = 0) {
    self.sessionID = sessionID
    self.taskID = taskID
    self.turnID = turnID
    self.sequence = sequence
  }

  public mutating func parse(line: String) -> [AgentEvent] {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let role = object["role"] as? String else {
      return []
    }

    var events: [AgentEvent] = []
    if role == "assistant" {
      let contentType = assistantContentType(from: object)
      if let content = assistantContentText(from: object), !content.isEmpty {
        events.append(make(.output, payload: [
          "text": content,
          "contentType": contentType ?? "text"
        ]))
      }
    }

    if role == "assistant", let toolCalls = object["tool_calls"] as? [[String: Any]] {
      for call in toolCalls {
        let id = call["id"] as? String ?? ""
        let function = call["function"] as? [String: Any]
        let name = function?["name"] as? String ?? "unknown"
        let arguments = function?["arguments"] as? String ?? ""
        events.append(make(
          .toolRequested,
          payload: ["id": id, "name": name, "arguments": arguments],
          requiresApproval: true
        ))
      }
    }

    if role == "tool" {
      let id = object["tool_call_id"] as? String ?? ""
      let content = object["content"] as? String ?? ""
      events.append(make(.toolFinished, payload: ["id": id, "content": content]))
    }

    if role == "meta", let type = object["type"] as? String {
      switch type {
      case "session.resume_hint":
        events.append(make(.sessionResumed, payload: ["sessionID": object["session_id"] as? String ?? ""]))
      case "turn.step.retrying":
        events.append(make(.error, payload: ["type": type, "message": object["error_message"] as? String ?? "重试中"]))
      case "system.version":
        events.append(make(.output, payload: ["version": object["version"] as? String ?? ""]))
      default:
        events.append(make(.output, payload: ["type": type]))
      }
    }

    return events
  }

  public mutating func event(
    kind: AgentEventKind,
    payload: [String: String],
    requiresApproval: Bool = false
  ) -> AgentEvent {
    make(kind, payload: payload, requiresApproval: requiresApproval)
  }

  private mutating func make(
    _ kind: AgentEventKind,
    payload: [String: String],
    requiresApproval: Bool = false
  ) -> AgentEvent {
    sequence += 1
    return AgentEvent(
      sessionID: sessionID,
      taskID: taskID,
      turnID: turnID,
      sequence: sequence,
      actor: "kimi-runtime",
      kind: kind,
      payload: payload,
      requiresApproval: requiresApproval
    )
  }

  private func assistantContentText(from object: [String: Any]) -> String? {
    if let content = object["content"] as? String {
      return content
    }
    if let content = object["content"] as? [String: Any] {
      return String(content["text"] as? String ?? content["think"] as? String ?? "")
    }
    return nil
  }

  private func assistantContentType(from object: [String: Any]) -> String? {
    if let explicit = object["contentType"] as? String, !explicit.isEmpty {
      return explicit
    }
    if let explicit = object["content_type"] as? String, !explicit.isEmpty {
      return explicit
    }
    if let content = object["content"] as? [String: Any], let type = content["type"] as? String, !type.isEmpty {
      return type
    }
    return nil
  }
}
