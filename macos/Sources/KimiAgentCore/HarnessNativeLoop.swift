import Foundation

public enum HarnessChatRole: String, Codable, Equatable, Sendable {
  case system
  case user
  case assistant
  case tool
}

public struct HarnessToolCall: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let argumentsJSON: String

  public init(id: String, name: String, argumentsJSON: String) {
    self.id = id
    self.name = name
    self.argumentsJSON = argumentsJSON
  }
}

public struct HarnessChatMessage: Codable, Equatable, Sendable {
  public let role: HarnessChatRole
  public let content: String?
  public let toolCalls: [HarnessToolCall]
  public let toolCallID: String?

  public init(
    role: HarnessChatRole,
    content: String? = nil,
    toolCalls: [HarnessToolCall] = [],
    toolCallID: String? = nil
  ) {
    self.role = role
    self.content = content
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  public static func user(_ text: String) -> HarnessChatMessage {
    HarnessChatMessage(role: .user, content: text)
  }

  public static func assistant(_ text: String, toolCalls: [HarnessToolCall] = []) -> HarnessChatMessage {
    HarnessChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
  }

  public static func tool(_ result: HarnessToolResult) -> HarnessChatMessage {
    HarnessChatMessage(
      role: .tool,
      content: result.output,
      toolCallID: result.callID
    )
  }
}

public struct HarnessConversationRequest: Codable, Equatable, Sendable {
  public let modelID: String
  public let messages: [HarnessChatMessage]

  public init(modelID: String, messages: [HarnessChatMessage]) {
    self.modelID = modelID
    self.messages = messages
  }

  func appending(_ message: HarnessChatMessage) -> HarnessConversationRequest {
    HarnessConversationRequest(modelID: modelID, messages: messages + [message])
  }
}

public enum HarnessConversationEvent: Equatable, Sendable {
  case text(String)
  case toolCallDelta(id: String, name: String?, argumentsDelta: String)
  case done
}

public protocol HarnessConversationProvider: Sendable {
  func stream(
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessConversationEvent, Error>
}

public struct HarnessToolResult: Codable, Equatable, Sendable {
  public let callID: String
  public let toolName: String
  public let output: String
  public let isError: Bool

  public init(callID: String, toolName: String, output: String, isError: Bool) {
    self.callID = callID
    self.toolName = toolName
    self.output = output
    self.isError = isError
  }
}

public struct HarnessConversationResult: Codable, Equatable, Sendable {
  public let text: String
  public let messages: [HarnessChatMessage]
  public let toolResults: [HarnessToolResult]
  public let rounds: Int
  public let blockedByToolFailure: Bool

  public init(text: String, messages: [HarnessChatMessage], toolResults: [HarnessToolResult], rounds: Int, blockedByToolFailure: Bool = false) {
    self.text = text
    self.messages = messages
    self.toolResults = toolResults
    self.rounds = rounds
    self.blockedByToolFailure = blockedByToolFailure
  }
}

public struct HarnessConversationLoop: Sendable {
  public typealias ToolExecutor = @Sendable (HarnessToolCall, HarnessConversationRequest) async throws -> HarnessToolResult

  private let provider: any HarnessConversationProvider
  private let maxRounds: Int
  private let executeTool: ToolExecutor

  public init(
    provider: any HarnessConversationProvider,
    maxRounds: Int = 8,
    executeTool: @escaping ToolExecutor
  ) {
    self.provider = provider
    self.maxRounds = max(1, maxRounds)
    self.executeTool = executeTool
  }

  /// Providers are allowed to emit either JSON fragments or the complete
  /// arguments object on every delta. Merge complete objects idempotently so
  /// repeated `{ "url": "…" }` chunks never become invalid concatenated JSON.
  public static func appendToolArguments(existing: String, delta: String) -> String {
    let incoming = delta.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !incoming.isEmpty else { return existing }
    guard !existing.isEmpty else { return incoming }

    if let existingObject = jsonObject(existing), let incomingObject = jsonObject(incoming) {
      var merged = existingObject
      for (key, value) in incomingObject { merged[key] = value }
      if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
         let string = String(data: data, encoding: .utf8) {
        return string
      }
    }

    return existing + incoming
  }

  /// Some Kimi tool-call streams omit web arguments even though the current
  /// user turn contains enough deterministic input. Recover only read-only web
  /// tools; never infer file paths, shell commands, or mutation parameters
  /// from prose.
  public static func recoverToolCall(
    _ call: HarnessToolCall,
    request: HarnessConversationRequest
  ) -> HarnessToolCall {
    let object = jsonObject(call.argumentsJSON)
    let existingURL = firstNonEmptyString(in: object, keys: ["url", "href", "uri", "link", "target_url"])
    let existingQuery = firstNonEmptyString(in: object, keys: ["query", "text_query", "q", "keyword", "keywords"])
    let canonicalName = canonicalWebToolName(call.name)
    guard canonicalName == "web.fetch" || canonicalName == "web.search" else {
      return call
    }
    let source = request.messages.reversed()
      .first(where: { $0.role == .user })?
      .content ?? ""
    let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let recoveredQuery = recoveredSearchQuery(existingQuery: existingQuery, source: source)

    if canonicalName == "web.search" {
      let query = recoveredQuery ?? trimmedSource
      guard !query.isEmpty else {
        return HarnessToolCall(id: call.id, name: "web.search", argumentsJSON: call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON)
      }
      let arguments = jsonString(["query": query]) ?? call.argumentsJSON
      return HarnessToolCall(id: call.id, name: "web.search", argumentsJSON: arguments)
    }

    let pattern = #"https?://[^\s\"'<>）。，、]+"#
    if let expression = try? NSRegularExpression(pattern: pattern),
       let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
       let range = Range(match.range, in: source) {
      let url = String(source[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?，。；：！？、\"'"))
      if !url.isEmpty {
        let arguments = jsonString(["url": url]) ?? call.argumentsJSON
        return HarnessToolCall(id: call.id, name: "web.fetch", argumentsJSON: arguments)
      }
    }

    // A FetchURL call without a URL is a model/tool mismatch for questions
    // such as “明天天气怎么样？”: there is nothing to fetch yet. Convert it
    // into the read-only search tool instead of retrying the same bad call.
    if let recoveredQuery, !recoveredQuery.isEmpty {
      let arguments = jsonString(["query": recoveredQuery]) ?? #"{"query":""}"#
      return HarnessToolCall(id: call.id, name: "web.search", argumentsJSON: arguments)
    }

    if let existingURL {
      let arguments = jsonString(["url": existingURL]) ?? call.argumentsJSON
      return HarnessToolCall(id: call.id, name: "web.fetch", argumentsJSON: arguments)
    }
    return HarnessToolCall(id: call.id, name: "web.fetch", argumentsJSON: call.argumentsJSON.isEmpty ? "{}" : call.argumentsJSON)
  }

  private static func recoveredSearchQuery(existingQuery: String?, source: String) -> String? {
    let sourceQuery = extractUserPrompt(from: source) ?? source.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSourceQuery = compactSearchQuery(sourceQuery)
    if let existingQuery {
      let trimmedExisting = existingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedExisting.isEmpty,
         trimmedExisting.count <= 500,
         !looksLikeComposedTaskPrompt(trimmedExisting) {
        return trimmedExisting
      }
    }
    return normalizedSourceQuery.isEmpty ? nil : normalizedSourceQuery
  }

  private static func extractUserPrompt(from source: String) -> String? {
    for marker in ["用户消息：", "用户任务："] {
      guard let range = source.range(of: marker, options: [.backwards]) else { continue }
      let suffix = source[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !suffix.isEmpty else { continue }
      return suffix
    }
    return nil
  }

  private static func compactSearchQuery(_ value: String) -> String {
    var query = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let firstLine = query.split(whereSeparator: \ .isNewline).first {
      let line = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
      if !line.isEmpty { query = line }
    }
    if query.count > 500 {
      query = String(query.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return query
  }

  private static func looksLikeComposedTaskPrompt(_ value: String) -> Bool {
    value.contains("当前上下文：") ||
      value.contains("执行边界：") ||
      value.contains("可用工具：") ||
      value.contains("用户消息：") ||
      value.contains("用户任务：")
  }

  private static func canonicalWebToolName(_ name: String) -> String {
    switch name.lowercased() {
    case "web.fetch", "web_fetch", "fetchurl", "network.fetch":
      return "web.fetch"
    case "web.search", "web_search", "websearch":
      return "web.search"
    default:
      return name
    }
  }

  private static func firstNonEmptyString(in object: [String: Any]?, keys: [String]) -> String? {
    guard let object else { return nil }
    for key in keys {
      if let value = object[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private static func jsonString(_ object: [String: String]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func jsonObject(_ value: String) -> [String: Any]? {
    guard let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else { return nil }
    return dictionary
  }

  public func run(
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>? = nil
  ) async throws -> HarnessConversationResult {
    var messages = request.messages
    var toolResults: [HarnessToolResult] = []
    var finalText = ""
    var failedToolAttempts: [String: Int] = [:]

    for round in 1...maxRounds {
      let roundRequest = HarnessConversationRequest(modelID: request.modelID, messages: messages)
      let stream = try await provider.stream(request: roundRequest, tools: tools, signal: signal)
      var text = ""
      var toolOrder: [String] = []
      var toolNames: [String: String] = [:]
      var toolArguments: [String: String] = [:]

      for try await event in stream {
        switch event {
        case let .text(value):
          text += value
        case let .toolCallDelta(id, name, argumentsDelta):
          if !toolOrder.contains(id) { toolOrder.append(id) }
          if let name, !name.isEmpty { toolNames[id] = name }
          toolArguments[id] = Self.appendToolArguments(existing: toolArguments[id] ?? "", delta: argumentsDelta)
        case .done:
          break
        }
      }

      let calls = toolOrder.compactMap { id -> HarnessToolCall? in
        guard let name = toolNames[id], !name.isEmpty else { return nil }
        return Self.recoverToolCall(
          HarnessToolCall(id: id, name: name, argumentsJSON: toolArguments[id] ?? "{}"),
          request: roundRequest
        )
      }
      messages.append(.assistant(text, toolCalls: calls))
      finalText += text

      guard !calls.isEmpty else {
        return HarnessConversationResult(text: finalText, messages: messages, toolResults: toolResults, rounds: round)
      }

      for call in calls {
        let result: HarnessToolResult
        do {
          result = try await executeTool(call, roundRequest)
        } catch {
          result = HarnessToolResult(callID: call.id, toolName: call.name, output: error.localizedDescription, isError: true)
        }
        toolResults.append(result)
        messages.append(.tool(result))
        if result.isError {
          let signature = "\(call.name)|\(call.argumentsJSON)"
          failedToolAttempts[signature, default: 0] += 1
          if failedToolAttempts[signature, default: 0] >= 2 {
            let blockedText = "工具调用连续失败：\(result.output)"
            return HarnessConversationResult(
              text: blockedText,
              messages: messages,
              toolResults: toolResults,
              rounds: round,
              blockedByToolFailure: true
            )
          }
        }
      }
    }

    throw NSError(
      domain: "HarnessConversationLoop",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "模型工具循环超过最大轮数（\(maxRounds)）。"]
    )
  }
}

public actor ScriptedHarnessConversationProvider: HarnessConversationProvider {
  private let turns: [[HarnessConversationEvent]]
  private var index = 0

  public init(turns: [[HarnessConversationEvent]]) {
    self.turns = turns
  }

  public func stream(
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessConversationEvent, Error> {
    let turn = index < turns.count ? turns[index] : [.done]
    index += 1
    return AsyncThrowingStream { continuation in
      for event in turn { continuation.yield(event) }
      continuation.finish()
    }
  }
}

public extension HarnessConversationEvent {
  static func toolCall(id: String, name: String, argumentsJSON: String) -> HarnessConversationEvent {
    .toolCallDelta(id: id, name: name, argumentsDelta: argumentsJSON)
  }
}
