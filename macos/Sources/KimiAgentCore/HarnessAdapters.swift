import Foundation

public struct LegacyHarnessSession: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID
  public let workspacePath: String
  public let entries: [HarnessSessionEntry]
  public let isReadOnly: Bool

  public init(id: UUID, taskID: UUID, workspacePath: String, entries: [HarnessSessionEntry], isReadOnly: Bool = true) {
    self.id = id
    self.taskID = taskID
    self.workspacePath = workspacePath
    self.entries = entries
    self.isReadOnly = isReadOnly
  }
}

public enum HarnessLegacyMigrator {
  public static func `import`(state: AppState) async throws -> [LegacyHarnessSession] {
    state.tasks.map { task in
      let sessionID = UUID(uuidString: task.sessionID ?? "") ?? task.id
      var entries: [HarnessSessionEntry] = [
        HarnessSessionEntry(
          parentID: nil,
          lane: .main,
          kind: .legacy,
          text: task.title
        )
      ]
      entries.append(contentsOf: task.events.map {
        HarnessSessionEntry(
          parentID: entries.last?.id,
          lane: .main,
          kind: .legacy,
          text: $0
        )
      })
      return LegacyHarnessSession(
        id: sessionID,
        taskID: task.id,
        workspacePath: task.workspacePath,
        entries: entries
      )
    }
  }
}

public struct HarnessProviderContext: Sendable {
  public let sessionID: UUID
  public let operationID: OperationID
  public let lane: LaneID
  public let modelID: String
  /// Provider context preserves roles and tool-call linkage. Flattening this
  /// to strings turns system, assistant and tool facts into user prose.
  public let messages: [HarnessChatMessage]

  public init(
    sessionID: UUID,
    operationID: OperationID,
    lane: LaneID,
    modelID: String,
    messages: [HarnessChatMessage]
  ) {
    self.sessionID = sessionID
    self.operationID = operationID
    self.lane = lane
    self.modelID = modelID
    self.messages = messages
  }

  /// Compatibility import boundary for older adapters. New execution paths
  /// must use the typed initializer above.
  public init(
    sessionID: UUID,
    operationID: OperationID,
    lane: LaneID,
    modelID: String,
    messages: [String]
  ) {
    self.init(
      sessionID: sessionID,
      operationID: operationID,
      lane: lane,
      modelID: modelID,
      messages: messages.map(HarnessChatMessage.user)
    )
  }
}

public enum HarnessExecutionAuthority: String, Codable, CaseIterable, Sendable {
  case harnessNative
  case compatibilityACP
  case compatibilityCLI
}

public enum HarnessToolNameCodec {
  public static func wireName(for runtimeName: String) -> String {
    let replaced = runtimeName.replacingOccurrences(of: ".", with: "_")
    let sanitized = replaced.map { character -> Character in
      if (character.isASCII && (character.isLetter || character.isNumber)) || character == "_" || character == "-" {
        return character
      }
      return "_"
    }
    var value = String(sanitized)
    while value.contains("__") { value = value.replacingOccurrences(of: "__", with: "_") }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if value.isEmpty { value = "tool" }
    if value.first?.isNumber == true { value = "tool_\(value)" }
    if value.first.map({ !($0.isASCII && $0.isLetter) }) ?? true {
      value = "tool_\(value)"
    }
    return value
  }

  public static func runtimeName(for wireName: String) -> String {
    switch wireName {
    case "web_fetch": return "web.fetch"
    case "web_search": return "web.search"
    default: return wireName
    }
  }

  public static func runtimeName(for providerName: String, tools: [ToolDefinition]) -> String {
    tools.first(where: { Self.wireName(for: $0.id) == providerName })?.id ?? runtimeName(for: providerName)
  }
}

public enum HarnessModelEventKind: String, Codable, CaseIterable, Sendable {
  case text
  case thinking
  case toolCall
  case toolResult
  case done
  case error
}

public struct HarnessModelEvent: Codable, Equatable, Sendable {
  public let kind: HarnessModelEventKind
  public let text: String?
  public let toolID: String?
  public let toolName: String?
  public let arguments: [String: String]

  public init(
    kind: HarnessModelEventKind,
    text: String? = nil,
    toolID: String? = nil,
    toolName: String? = nil,
    arguments: [String: String] = [:]
  ) {
    self.kind = kind
    self.text = text
    self.toolID = toolID
    self.toolName = toolName
    self.arguments = arguments
  }

  public static func text(_ value: String) -> HarnessModelEvent {
    HarnessModelEvent(kind: .text, text: value)
  }
}

public protocol HarnessModelProvider: Sendable {
  func stream(
    context: HarnessProviderContext,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessModelEvent, Error>
}

public struct StaticHarnessModelProvider: HarnessModelProvider {
  private let values: [HarnessModelEvent]

  public init(events: [HarnessModelEvent]) {
    self.values = events
  }

  public func stream(
    context: HarnessProviderContext,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessModelEvent, Error> {
    AsyncThrowingStream { continuation in
      for value in values { continuation.yield(value) }
      continuation.finish()
    }
  }
}

public enum KimiHTTPProviderError: LocalizedError, Equatable {
  case invalidResponse
  case httpStatus(Int, String)
  case invalidEvent(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: "Kimi API 返回了无效响应。"
    case let .httpStatus(status, body): "Kimi API 请求失败（\(status)）：\(body)"
    case let .invalidEvent(line): "Kimi API 流事件无法解析：\(line)"
    }
  }
}

/// OpenAI-compatible streaming adapter for Kimi API. The adapter only emits
/// model events; the Harness remains the authority that executes tool calls.
public final class KimiHTTPModelProvider: HarnessModelProvider, HarnessConversationProvider, @unchecked Sendable {
  public let baseURL: URL
  public let apiKey: String
  public let modelID: String
  public let maximumOutputTokens: Int?
  private let session: URLSession
  private let traceRecorder: ProviderTraceRecorder?

  public init(
    baseURL: URL,
    apiKey: String,
    modelID: String,
    maximumOutputTokens: Int? = nil,
    session: URLSession = .shared,
    traceRecorder: ProviderTraceRecorder? = nil
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.modelID = modelID
    self.maximumOutputTokens = maximumOutputTokens.map { max(1, $0) }
    self.session = session
    self.traceRecorder = traceRecorder
  }

  public func stream(
    context: HarnessProviderContext,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessModelEvent, Error> {
    let conversationStream = try await stream(
      request: HarnessConversationRequest(
        modelID: context.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? modelID : context.modelID,
        messages: context.messages
      ),
      tools: tools,
      signal: signal
    )
    return AsyncThrowingStream { continuation in
      Task {
        do {
          for try await event in conversationStream {
            switch event {
            case let .text(text): continuation.yield(.text(text))
            case let .reasoning(text): continuation.yield(HarnessModelEvent(kind: .thinking, text: text))
            case let .toolCallDelta(id, name, argumentsDelta):
              continuation.yield(HarnessModelEvent(
                kind: .toolCall,
                toolID: id,
                toolName: name,
                arguments: ["raw": argumentsDelta]
              ))
            case .usage, .finish: break
            case .done: continuation.yield(HarnessModelEvent(kind: .done))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  public func stream(
    request conversationRequest: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessConversationEvent, Error> {
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Self.requestBody(
      request: conversationRequest,
      tools: tools,
      maximumOutputTokens: maximumOutputTokens
    )

    let session = self.session
    let preparedRequest = request
    let recorder = traceRecorder
    let traceID = await recorder?.start(request: conversationRequest, tools: tools)
    return AsyncThrowingStream { continuation in
      let producer = Task {
        do {
          // OpenAI-compatible streams commonly include an `id` only in the
          // first tool-call delta. Later argument deltas identify the call by
          // its stable array index, so retain that mapping for the whole
          // response instead of creating a new call with an empty payload.
          var toolCallIDsByIndex: [Int: String] = [:]
          let (bytes, response) = try await session.bytes(for: preparedRequest)
          guard let http = response as? HTTPURLResponse else {
            throw KimiHTTPProviderError.invalidResponse
          }
          guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw KimiHTTPProviderError.httpStatus(http.statusCode, body)
          }
          for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" {
              let event = HarnessConversationEvent.done
              continuation.yield(event)
              await recorder?.append(event, traceID: traceID)
              break
            }
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
              throw KimiHTTPProviderError.invalidEvent(String(payload))
            }
            if let text = delta["content"] as? String, !text.isEmpty {
              let event = HarnessConversationEvent.text(text)
              continuation.yield(event)
              await recorder?.append(event, traceID: traceID)
            }
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
              let event = HarnessConversationEvent.reasoning(reasoning)
              continuation.yield(event)
              await recorder?.append(event, traceID: traceID)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
              for (position, call) in toolCalls.enumerated() {
                let function = call["function"] as? [String: Any]
                let wireName = function?["name"] as? String
                let name = wireName.map { HarnessToolNameCodec.runtimeName(for: $0, tools: tools) }
                let arguments = Self.normalizedToolArguments(function?["arguments"])
                let index = call["index"] as? Int ?? position
                let id: String
                if let streamedID = call["id"] as? String, !streamedID.isEmpty {
                  toolCallIDsByIndex[index] = streamedID
                  id = streamedID
                } else {
                  id = toolCallIDsByIndex[index] ?? "call-index-\(index)"
                  toolCallIDsByIndex[index] = id
                }
                let event = HarnessConversationEvent.toolCallDelta(id: id, name: name, argumentsDelta: arguments)
                continuation.yield(event)
                await recorder?.append(event, traceID: traceID)
              }
            }
            if let usage = object["usage"] as? [String: Any] {
              let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
              let completionDetails = usage["completion_tokens_details"] as? [String: Any]
              let event = HarnessConversationEvent.usage(HarnessModelUsage(
                inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                outputTokens: usage["completion_tokens"] as? Int ?? 0,
                reasoningTokens: completionDetails?["reasoning_tokens"] as? Int ?? 0,
                cachedTokens: promptDetails?["cached_tokens"] as? Int ?? 0
              ))
              continuation.yield(event)
              await recorder?.append(event, traceID: traceID)
            }
            if let reason = choices.first?["finish_reason"] as? String {
              let mapped: HarnessConversationFinishReason
              switch reason {
              case "tool_calls": mapped = .toolCalls
              case "length": mapped = .maxTokens
              case "stop": mapped = .stop
              default: mapped = .error
              }
              let event = HarnessConversationEvent.finish(mapped)
              continuation.yield(event)
              await recorder?.append(event, traceID: traceID)
            }
          }
          await recorder?.complete(traceID: traceID)
          continuation.finish()
        } catch is CancellationError {
          await recorder?.fail(CancellationError(), traceID: traceID)
          continuation.finish()
        } catch {
          await recorder?.fail(error, traceID: traceID)
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        producer.cancel()
      }
    }
  }

  public static func requestBody(
    request conversationRequest: HarnessConversationRequest,
    tools: [ToolDefinition],
    maximumOutputTokens: Int? = nil
  ) throws -> Data {
    var body: [String: Any] = [
      "model": conversationRequest.modelID,
      "stream": true,
      "messages": conversationRequest.messages.map(Self.encodeMessage),
      "tools": tools.map { definition in
        let parameters: Any = definition.inputSchemaJSON
          .flatMap { data in
            guard let raw = data.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: raw)
          }
          ?? ["type": "object", "additionalProperties": true]
        return [
          "type": "function",
          "function": [
            "name": HarnessToolNameCodec.wireName(for: definition.id),
            "description": definition.description,
            "parameters": parameters
          ]
        ]
      }
    ]
    if let maximumOutputTokens {
      body["max_tokens"] = maximumOutputTokens
    }
    return try JSONSerialization.data(withJSONObject: body, options: [])
  }

  /// Kimi/OpenAI-compatible providers normally stream function arguments as a
  /// JSON string, but some responses return an already-decoded JSON object.
  /// A name/index-only delta has no argument content and must remain empty:
  /// inserting `{}` would corrupt the JSON fragments that follow it.
  public static func normalizedToolArguments(_ value: Any?) -> String {
    if let string = value as? String {
      return string
    }
    if let dictionary = value as? [String: String],
       let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
      return string
    }
    if let dictionary = value as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
      return string
    }
    if let data = value as? Data, let string = String(data: data, encoding: .utf8) {
      return string
    }
    return ""
  }

  private static func encodeMessage(_ message: HarnessChatMessage) -> [String: Any] {
    var value: [String: Any] = ["role": message.role.rawValue]
    if let content = message.content { value["content"] = content }
    if !message.toolCalls.isEmpty {
      value["tool_calls"] = message.toolCalls.map { call in
        [
          "id": call.id,
          "type": "function",
          "function": ["name": call.name, "arguments": call.argumentsJSON]
        ]
      }
    }
    if let toolCallID = message.toolCallID {
      value["tool_call_id"] = toolCallID
    }
    return value
  }
}
