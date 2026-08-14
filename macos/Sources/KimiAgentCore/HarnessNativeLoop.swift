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

public struct HarnessModelUsage: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int
  public let cachedTokens: Int

  public init(inputTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0, cachedTokens: Int = 0) {
    self.inputTokens = max(0, inputTokens)
    self.outputTokens = max(0, outputTokens)
    self.reasoningTokens = max(0, reasoningTokens)
    self.cachedTokens = max(0, cachedTokens)
  }
}

public enum HarnessConversationFinishReason: String, Codable, Equatable, Sendable {
  case stop
  case toolCalls
  case maxTokens
  case error
}

public enum HarnessConversationEvent: Equatable, Sendable {
  case text(String)
  case reasoning(String)
  case toolCallDelta(id: String, name: String?, argumentsDelta: String)
  case usage(HarnessModelUsage)
  case finish(HarnessConversationFinishReason)
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
  public let reasoning: String
  public let messages: [HarnessChatMessage]
  public let toolResults: [HarnessToolResult]
  public let rounds: Int
  public let blockedByToolFailure: Bool
  public let usage: HarnessModelUsage?
  public let finish: HarnessConversationFinishReason

  public init(
    text: String,
    reasoning: String = "",
    messages: [HarnessChatMessage],
    toolResults: [HarnessToolResult],
    rounds: Int,
    blockedByToolFailure: Bool = false,
    usage: HarnessModelUsage? = nil,
    finish: HarnessConversationFinishReason = .stop
  ) {
    self.text = text
    self.reasoning = reasoning
    self.messages = messages
    self.toolResults = toolResults
    self.rounds = rounds
    self.blockedByToolFailure = blockedByToolFailure
    self.usage = usage
    self.finish = finish
  }
}

/// Canonically assembles a streamed model response without making streamed
/// reasoning user-visible.  The same ordered calls are used for the final
/// assistant message and later provider replay.
public struct HarnessModelStreamAssembler: Sendable {
  private var order: [String] = []
  private var names: [String: String] = [:]
  private var arguments: [String: String] = [:]
  public private(set) var text = ""
  public private(set) var reasoning = ""
  public private(set) var usage: HarnessModelUsage?
  public private(set) var finish: HarnessConversationFinishReason = .stop

  public init() {}

  public mutating func push(_ event: HarnessConversationEvent) {
    switch event {
    case let .text(value): text += value
    case let .reasoning(value): reasoning += value
    case let .toolCallDelta(id, name, argumentsDelta):
      if !order.contains(id) { order.append(id) }
      if let name, !name.isEmpty { names[id] = name }
      arguments[id] = HarnessConversationLoop.appendToolArguments(existing: arguments[id] ?? "", delta: argumentsDelta)
    case let .usage(value): usage = value
    case let .finish(value): finish = value
    case .done: break
    }
  }

  public var toolCalls: [HarnessToolCall] {
    order.compactMap { id in
      guard let name = names[id], !name.isEmpty else { return nil }
      return HarnessToolCall(id: id, name: name, argumentsJSON: arguments[id] ?? "{}")
    }
  }
}

public struct HarnessConversationLoop: Sendable {
  public typealias ToolExecutor = @Sendable (HarnessToolCall, HarnessConversationRequest) async throws -> HarnessToolResult
  public typealias BatchToolExecutor = @Sendable ([HarnessToolCall], HarnessConversationRequest) async -> [HarnessToolResult]
  public typealias EventSink = @Sendable (HarnessDriverEvent) async -> Void
  public typealias NextStepInput = @Sendable () async -> [PromptInput]

  private let provider: any HarnessConversationProvider
  private let maxRounds: Int
  private let maximumOutputTokens: Int
  private let executeTool: ToolExecutor
  private let executeBatch: BatchToolExecutor?
  private let eventSink: EventSink?
  private let nextStepInput: NextStepInput

  public init(
    provider: any HarnessConversationProvider,
    maxRounds: Int = 8,
    executeTool: @escaping ToolExecutor,
    executeBatch: BatchToolExecutor? = nil,
    maximumOutputTokens: Int = 0,
    eventSink: EventSink? = nil,
    nextStepInput: @escaping NextStepInput = { [] }
  ) {
    self.provider = provider
    self.maxRounds = max(1, maxRounds)
    self.maximumOutputTokens = max(0, maximumOutputTokens)
    self.executeTool = executeTool
    self.executeBatch = executeBatch
    self.eventSink = eventSink
    self.nextStepInput = nextStepInput
  }

  /// Providers are allowed to emit either JSON fragments or the complete
  /// arguments object on every delta. Merge complete objects idempotently so
  /// repeated `{ "url": "…" }` chunks never become invalid concatenated JSON.
  public static func appendToolArguments(existing: String, delta: String) -> String {
    let normalizedIncoming = delta.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedIncoming.isEmpty else { return existing }
    guard !existing.isEmpty else { return delta }

    if let existingObject = jsonObject(existing), let incomingObject = jsonObject(normalizedIncoming) {
      var merged = existingObject
      for (key, value) in incomingObject { merged[key] = value }
      if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
         let string = String(data: data, encoding: .utf8) {
        return string
      }
    }

    // JSON string boundaries are data, not formatting: a later delta can
    // legitimately start with a space.  Never trim it before concatenation.
    return existing + delta
  }

  /// Normalize legacy wire names without manufacturing model arguments.
  ///
  /// A missing URL/query is a model-tool contract violation, not a reason to
  /// scrape values from the user's prose.  Guessing made retries look
  /// successful while executing a request the model never actually emitted.
  /// The tool executor returns a structured validation error instead, allowing
  /// the next model step to repair the call explicitly.
  public static func recoverToolCall(
    _ call: HarnessToolCall,
    request: HarnessConversationRequest
  ) -> HarnessToolCall {
    let arguments = call.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    return HarnessToolCall(
      id: call.id,
      name: canonicalWebToolName(call.name),
      argumentsJSON: arguments.isEmpty ? "{}" : arguments
    )
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
    let turnID = UUID()
    await emit(.turnStarted(HarnessTurnRecord(turnID: turnID, modelID: request.modelID)))

    do {
      for round in 1...maxRounds {
        let injected = await nextStepInput()
        if !injected.isEmpty {
          let text = injected.map(\.text).joined(separator: "\n")
          messages.append(.user("执行中补充：\n\(text)"))
        }
        let roundRequest = HarnessConversationRequest(modelID: request.modelID, messages: messages)
        let step = HarnessStepRecord(turnID: turnID, step: round)
        await emit(.stepStarted(step))
        await emit(.requestHeader(HarnessModelRequestHeader(
          turnID: turnID,
          step: round,
          modelID: roundRequest.modelID,
          toolIDs: tools.map(\.id),
          maximumOutputTokens: maximumOutputTokens
        )))
        let stream = try await provider.stream(request: roundRequest, tools: tools, signal: signal)
        var assembler = HarnessModelStreamAssembler()

        for try await event in stream {
          await emit(.modelChunk(Self.modelStreamBlock(from: event, step: round)))
          assembler.push(event)
        }

        let calls = assembler.toolCalls.map {
          Self.recoverToolCall($0, request: roundRequest)
        }
        let assistant = HarnessChatMessage.assistant(assembler.text, toolCalls: calls)
        messages.append(assistant)
        finalText += assembler.text
        await emit(.assistantMessage(HarnessAssistantMessageRecord(turnID: turnID, step: round, message: assistant)))
        for call in calls {
          await emit(.toolCallDeclared(HarnessToolCallRecord(turnID: turnID, step: round, call: call)))
        }

        guard !calls.isEmpty else {
          await emit(.stepEnded(HarnessStepRecord(turnID: turnID, step: round, status: .completed)))
          await emit(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: request.modelID, status: .completed)))
          return HarnessConversationResult(
            text: finalText,
            reasoning: assembler.reasoning,
            messages: messages,
            toolResults: toolResults,
            rounds: round,
            usage: assembler.usage,
            finish: assembler.finish
          )
        }

        let roundResults: [HarnessToolResult]
        if let executeBatch {
          roundResults = await executeBatch(calls, roundRequest)
        } else {
          var values: [HarnessToolResult] = []
          for call in calls {
            do {
              values.append(try await executeTool(call, roundRequest))
            } catch {
              values.append(HarnessToolResult(callID: call.id, toolName: call.name, output: error.localizedDescription, isError: true))
            }
          }
          roundResults = values
        }

        for (index, call) in calls.enumerated() {
          let result = index < roundResults.count
            ? roundResults[index]
            : HarnessToolResult(callID: call.id, toolName: call.name, output: "工具调度器没有返回结果。", isError: true)
          toolResults.append(result)
          messages.append(.tool(result))
          await emit(.toolResultRecorded(HarnessToolResultRecord(turnID: turnID, step: round, result: result)))
          if result.isError {
            let signature = "\(call.name)|\(call.argumentsJSON)"
            failedToolAttempts[signature, default: 0] += 1
            if failedToolAttempts[signature, default: 0] >= 2 {
              let blockedText = "工具调用连续失败：\(result.output)"
              await emit(.stepEnded(HarnessStepRecord(turnID: turnID, step: round, status: .failed)))
              await emit(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: request.modelID, status: .failed)))
              return HarnessConversationResult(
                text: blockedText,
                reasoning: assembler.reasoning,
                messages: messages,
                toolResults: toolResults,
                rounds: round,
                blockedByToolFailure: true,
                usage: assembler.usage,
                finish: assembler.finish
              )
            }
          }
        }
        await emit(.stepEnded(HarnessStepRecord(turnID: turnID, step: round, status: .toolCalls)))
      }

      throw NSError(
        domain: "HarnessConversationLoop",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "模型工具循环超过最大轮数（\(maxRounds)）。"]
      )
    } catch is CancellationError {
      await emit(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: request.modelID, status: .cancelled)))
      throw CancellationError()
    } catch {
      await emit(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: request.modelID, status: .failed)))
      throw error
    }
  }

  private func emit(_ event: HarnessDriverEvent) async {
    await eventSink?(event)
  }

  private static func modelStreamBlock(from event: HarnessConversationEvent, step: Int) -> ModelStreamBlock {
    switch event {
    case let .text(text):
      return ModelStreamBlock(step: step, kind: .text, text: text)
    case let .reasoning(text):
      return ModelStreamBlock(step: step, kind: .reasoning, text: text)
    case let .toolCallDelta(id, name, argumentsDelta):
      return ModelStreamBlock(step: step, kind: .toolCall, toolCallID: id, toolName: name, argumentsDelta: argumentsDelta)
    case let .usage(usage):
      return ModelStreamBlock(step: step, kind: .usage, usage: usage)
    case let .finish(finish):
      return ModelStreamBlock(step: step, kind: .finish, finish: finish)
    case .done:
      return ModelStreamBlock(step: step, kind: .done)
    }
  }
}

public actor ScriptedHarnessConversationProvider: HarnessConversationProvider {
  private let turns: [[HarnessConversationEvent]]
  private var index = 0
  private var receivedRequests: [HarnessConversationRequest] = []

  public init(turns: [[HarnessConversationEvent]]) {
    self.turns = turns
  }

  public func stream(
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    signal: AsyncStream<Void>?
  ) async throws -> AsyncThrowingStream<HarnessConversationEvent, Error> {
    receivedRequests.append(request)
    let turn = index < turns.count ? turns[index] : [.done]
    index += 1
    return AsyncThrowingStream { continuation in
      for event in turn { continuation.yield(event) }
      continuation.finish()
    }
  }

  public func requests() -> [HarnessConversationRequest] { receivedRequests }
}

public extension HarnessConversationEvent {
  static func toolCall(id: String, name: String, argumentsJSON: String) -> HarnessConversationEvent {
    .toolCallDelta(id: id, name: name, argumentsDelta: argumentsJSON)
  }
}
