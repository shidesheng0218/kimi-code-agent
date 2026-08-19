import Foundation

public struct PluginWorkerHandshake: Codable, Equatable, Sendable {
  public let protocolVersion: String
  public let workerName: String
  public let workerVersion: String
  public let capabilities: [String]

  public init(protocolVersion: String, workerName: String, workerVersion: String, capabilities: [String]) {
    self.protocolVersion = protocolVersion
    self.workerName = workerName
    self.workerVersion = workerVersion
    self.capabilities = Array(Set(capabilities)).sorted()
  }
}

public enum PluginWorkerProtocolError: LocalizedError, Equatable {
  case malformedResponse
  case rpcError(String)
  case protocolMismatch(String)
  case missingCapabilities([String])

  public var errorDescription: String? {
    switch self {
    case .malformedResponse: "插件 Worker 握手响应格式无效。"
    case let .rpcError(message): "插件 Worker 返回 JSON-RPC 错误：" + message
    case let .protocolMismatch(version): "插件 Worker 协议版本不兼容：" + version
    case let .missingCapabilities(capabilities): "插件 Worker 缺少能力：" + capabilities.joined(separator: ", ")
    }
  }
}

public enum PluginWorkerProtocol {
  public static let protocolVersion = "1.0"

  public static func initializeRequest(id: Int64 = 1, hostVersion: String = "1.0.0") throws -> Data {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "method": "initialize",
      "params": [
        "protocolVersion": protocolVersion,
        "host": ["name": "KimiCodeAgent", "version": hostVersion],
        "capabilities": ["tools": true, "hooks": true, "skills": true, "mcp": true]
      ]
    ]
    return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) + Data([0x0A])
  }

  public static func decodeHandshake(
    _ data: Data,
    expectedProtocolVersion: String = protocolVersion,
    requiredCapabilities: Set<String> = []
  ) throws -> PluginWorkerHandshake {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PluginWorkerProtocolError.malformedResponse
    }
    if let error = object["error"] as? [String: Any] {
      throw PluginWorkerProtocolError.rpcError(error["message"] as? String ?? "unknown error")
    }
    guard let result = object["result"] as? [String: Any],
          let version = result["protocolVersion"] as? String,
          let worker = result["worker"] as? [String: Any],
          let name = worker["name"] as? String,
          let workerVersion = worker["version"] as? String else {
      throw PluginWorkerProtocolError.malformedResponse
    }
    guard version.split(separator: ".").first == expectedProtocolVersion.split(separator: ".").first else {
      throw PluginWorkerProtocolError.protocolMismatch(version)
    }
    let capabilities: [String]
    if let values = result["capabilities"] as? [String] {
      capabilities = values
    } else if let values = result["capabilities"] as? [String: Any] {
      capabilities = values.compactMap { key, value in
        (value as? Bool) == true ? key : nil
      }
    } else {
      capabilities = []
    }
    let missing = requiredCapabilities.subtracting(capabilities)
    guard missing.isEmpty else {
      throw PluginWorkerProtocolError.missingCapabilities(missing.sorted())
    }
    return PluginWorkerHandshake(
      protocolVersion: version,
      workerName: name,
      workerVersion: workerVersion,
      capabilities: capabilities
    )
  }
}
