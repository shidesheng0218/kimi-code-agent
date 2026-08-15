import Foundation
import CryptoKit

/// The only durable envelope used between a model provider and the Harness.
/// Keeping arguments as JSON prevents nested objects/arrays from being lost in
/// the legacy `[String: String]` projection.
public struct ToolCallEnvelope: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let toolID: String
  public let arguments: HarnessJSONValue
  public let schemaVersion: Int

  public var idempotencyKey: String { id }

  public init(id: String, toolID: String, arguments: HarnessJSONValue, schemaVersion: Int = 1) {
    self.id = id
    self.toolID = toolID
    self.arguments = arguments
    self.schemaVersion = max(1, schemaVersion)
  }
}

public enum ToolSchemaValidationError: LocalizedError, Equatable, Sendable {
  case invalidSchema(toolID: String, reason: String)
  case invalidRoot(toolID: String, expected: String)
  case missingRequired(toolID: String, path: String)
  case unexpectedProperty(toolID: String, path: String)
  case typeMismatch(toolID: String, path: String, expected: String)
  case invalidEnum(toolID: String, path: String)
  case constraint(toolID: String, path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case let .invalidSchema(toolID, reason): "工具 \(toolID) 的 Schema 无效：\(reason)"
    case let .invalidRoot(toolID, expected): "工具 \(toolID) 参数必须是 \(expected)。"
    case let .missingRequired(toolID, path): "工具 \(toolID) 缺少必填参数：\(path)"
    case let .unexpectedProperty(toolID, path): "工具 \(toolID) 包含未声明参数：\(path)"
    case let .typeMismatch(toolID, path, expected): "工具 \(toolID) 参数 \(path) 类型错误，应为 \(expected)。"
    case let .invalidEnum(toolID, path): "工具 \(toolID) 参数 \(path) 不在允许值范围内。"
    case let .constraint(toolID, path, reason): "工具 \(toolID) 参数 \(path) 不满足约束：\(reason)"
    }
  }
}

/// A deliberately small JSON Schema validator covering the subset emitted by
/// Kimi/OpenAI tools. It is strict about required fields and additional
/// properties, while remaining backward-compatible for tools without a schema.
public enum ToolSchemaValidator {
  public static func validate(_ arguments: HarnessJSONValue, definition: ToolDefinition) throws {
    guard let rawSchema = definition.inputSchemaJSON else { return }
    guard let data = rawSchema.data(using: .utf8),
          let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ToolSchemaValidationError.invalidSchema(toolID: definition.id, reason: "不是合法 JSON 对象")
    }
    try validate(value: arguments, schema: schema, toolID: definition.id, path: "$")
  }

  private static func validate(value: HarnessJSONValue, schema: [String: Any], toolID: String, path: String) throws {
    if let type = schema["type"] as? String, !matches(value, type: type) {
      throw ToolSchemaValidationError.typeMismatch(toolID: toolID, path: path, expected: type)
    }

    if let enumValues = schema["enum"] as? [Any], !enumValues.contains(where: { equalFoundation($0, value) }) {
      throw ToolSchemaValidationError.invalidEnum(toolID: toolID, path: path)
    }

    switch value {
    case let .object(values):
      guard schema["type"] as? String == nil || schema["type"] as? String == "object" else { return }
      let properties = schema["properties"] as? [String: Any] ?? [:]
      let required = schema["required"] as? [String] ?? []
      for name in required where values[name] == nil {
        throw ToolSchemaValidationError.missingRequired(toolID: toolID, path: path + "." + name)
      }
      let allowsAdditional = (schema["additionalProperties"] as? Bool) ?? true
      for (name, child) in values {
        guard let childSchema = properties[name] as? [String: Any] else {
          if !allowsAdditional {
            throw ToolSchemaValidationError.unexpectedProperty(toolID: toolID, path: path + "." + name)
          }
          continue
        }
        try validate(value: child, schema: childSchema, toolID: toolID, path: path + "." + name)
      }
    case let .array(values):
      if let itemSchema = schema["items"] as? [String: Any] {
        for (index, child) in values.enumerated() {
          try validate(value: child, schema: itemSchema, toolID: toolID, path: "\(path)[\(index)]")
        }
      }
      try validateLength(values.count, schema: schema, toolID: toolID, path: path)
    case let .string(string):
      try validateLength(string.count, schema: schema, toolID: toolID, path: path)
    default:
      break
    }
  }

  private static func matches(_ value: HarnessJSONValue, type: String) -> Bool {
    switch type {
    case "object": if case .object = value { return true }
    case "array": if case .array = value { return true }
    case "string": if case .string = value { return true }
    case "number": if case .number = value { return true }
    case "integer": if case let .number(number) = value, number.rounded() == number { return true }
    case "boolean": if case .bool = value { return true }
    case "null": if case .null = value { return true }
    default: return true
    }
    return false
  }

  private static func validateLength(_ count: Int, schema: [String: Any], toolID: String, path: String) throws {
    if let minimum = schema["minLength"] as? Int, count < minimum {
      throw ToolSchemaValidationError.constraint(toolID: toolID, path: path, reason: "长度小于 (minimum)")
    }
    if let maximum = schema["maxLength"] as? Int, count > maximum {
      throw ToolSchemaValidationError.constraint(toolID: toolID, path: path, reason: "长度超过 (maximum)")
    }
    if let minimum = schema["minItems"] as? Int, count < minimum {
      throw ToolSchemaValidationError.constraint(toolID: toolID, path: path, reason: "项目数小于 (minimum)")
    }
    if let maximum = schema["maxItems"] as? Int, count > maximum {
      throw ToolSchemaValidationError.constraint(toolID: toolID, path: path, reason: "项目数超过 (maximum)")
    }
  }

  private static func equalFoundation(_ raw: Any, _ value: HarnessJSONValue) -> Bool {
    switch (raw, value) {
    case (is NSNull, .null): true
    case let (raw as Bool, .bool(value)): raw == value
    case let (raw as NSNumber, .number(value)): raw.doubleValue == value
    case let (raw as String, .string(value)): raw == value
    default: false
    }
  }
}

public enum HarnessDigest {
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

  public static func sha256(_ value: HarnessJSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return sha256((try? encoder.encode(value)) ?? Data())
  }
}
