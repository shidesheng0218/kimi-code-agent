import Foundation

public enum AgentHostApprovalResponse: String, Codable, CaseIterable, Sendable {
  case approve
  case approveForSession = "approve_for_session"
  case reject
}

public struct AgentHostStartRequest: Encodable, Sendable {
  public let type = "start"
  public let sessionID: String
  public let runtimeSessionID: String?
  public let taskID: String
  public let workspacePath: String
  public let prompt: String
  public let modelID: String?
  public let runtimePath: String
  public let nodePath: String
  public let skillsDirectories: [String]

  public init(
    sessionID: String,
    runtimeSessionID: String? = nil,
    taskID: String,
    workspacePath: String,
    prompt: String,
    modelID: String?,
    runtimePath: String,
    nodePath: String,
    skillsDirectories: [String]
  ) {
    self.sessionID = sessionID
    self.runtimeSessionID = runtimeSessionID
    self.taskID = taskID
    self.workspacePath = workspacePath
    self.prompt = prompt
    self.modelID = modelID
    self.runtimePath = runtimePath
    self.nodePath = nodePath
    self.skillsDirectories = skillsDirectories
  }
}

public struct AgentHostApprovalRequest: Encodable, Sendable {
  public let type = "approve"
  public let id: String
  public let response: AgentHostApprovalResponse

  public init(id: String, response: AgentHostApprovalResponse) {
    self.id = id
    self.response = response
  }
}

public struct AgentHostEnvelope: Decodable, Sendable {
  public let type: String
  public let sessionID: String?
  public let runtimeSessionID: String?
  public let event: AgentEvent?
  public let message: String?
}

public enum AgentHostBridgeProtocol {
  public static func decodeEnvelope(_ data: Data) throws -> AgentHostEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(AgentHostEnvelope.self, from: data)
  }

  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
}
