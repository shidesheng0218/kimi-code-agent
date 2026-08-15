import Foundation

/// Replayable, redacted provider facts.  A trace deliberately stores parsed
/// protocol blocks rather than secrets or raw request headers, allowing a
/// sparse/duplicated Kimi stream to be reproduced offline during diagnosis.
public struct ProviderTrace: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let request: HarnessConversationRequest
  public let toolSchemaDigest: String
  public var blocks: [ProviderTraceBlock]
  public var errorMessage: String?
  public let startedAt: Date
  public var finishedAt: Date?

  public init(
    id: UUID = UUID(),
    request: HarnessConversationRequest,
    tools: [ToolDefinition],
    blocks: [ProviderTraceBlock] = [],
    errorMessage: String? = nil,
    startedAt: Date = .now,
    finishedAt: Date? = nil
  ) {
    self.id = id
    self.request = ProviderTraceRedactor.request(request)
    let toolSchemas = tools.map { definition in
      definition.id + "|" + (definition.inputSchemaJSON ?? "")
    }.joined(separator: "\n")
    self.toolSchemaDigest = HarnessDigest.sha256(toolSchemas)
    self.blocks = blocks
    self.errorMessage = errorMessage
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

public enum ProviderTraceBlock: Codable, Equatable, Sendable {
  case text(String)
  case reasoning(String)
  case toolCallDelta(id: String, name: String?, argumentsDelta: String)
  case usage(HarnessModelUsage)
  case finish(HarnessConversationFinishReason)
  case done

  private enum Kind: String, Codable { case text, reasoning, toolCallDelta, usage, finish, done }
  private enum CodingKeys: String, CodingKey { case kind, text, id, name, argumentsDelta, usage, finish }

  public init(_ event: HarnessConversationEvent) {
    switch event {
    case let .text(text): self = .text(ProviderTraceRedactor.redact(text))
    case let .reasoning(text): self = .reasoning(ProviderTraceRedactor.redact(text))
    case let .toolCallDelta(id, name, argumentsDelta):
      self = .toolCallDelta(id: id, name: name, argumentsDelta: ProviderTraceRedactor.redact(argumentsDelta))
    case let .usage(usage): self = .usage(usage)
    case let .finish(finish): self = .finish(finish)
    case .done: self = .done
    }
  }

  public var event: HarnessConversationEvent {
    switch self {
    case let .text(text): .text(text)
    case let .reasoning(text): .reasoning(text)
    case let .toolCallDelta(id, name, argumentsDelta): .toolCallDelta(id: id, name: name, argumentsDelta: argumentsDelta)
    case let .usage(usage): .usage(usage)
    case let .finish(finish): .finish(finish)
    case .done: .done
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .text: self = .text(try container.decode(String.self, forKey: .text))
    case .reasoning: self = .reasoning(try container.decode(String.self, forKey: .text))
    case .toolCallDelta:
      self = .toolCallDelta(
        id: try container.decode(String.self, forKey: .id),
        name: try container.decodeIfPresent(String.self, forKey: .name),
        argumentsDelta: try container.decodeIfPresent(String.self, forKey: .argumentsDelta) ?? ""
      )
    case .usage: self = .usage(try container.decode(HarnessModelUsage.self, forKey: .usage))
    case .finish: self = .finish(try container.decode(HarnessConversationFinishReason.self, forKey: .finish))
    case .done: self = .done
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .text(text):
      try container.encode(Kind.text, forKey: .kind)
      try container.encode(text, forKey: .text)
    case let .reasoning(text):
      try container.encode(Kind.reasoning, forKey: .kind)
      try container.encode(text, forKey: .text)
    case let .toolCallDelta(id, name, argumentsDelta):
      try container.encode(Kind.toolCallDelta, forKey: .kind)
      try container.encode(id, forKey: .id)
      try container.encodeIfPresent(name, forKey: .name)
      try container.encode(argumentsDelta, forKey: .argumentsDelta)
    case let .usage(usage):
      try container.encode(Kind.usage, forKey: .kind)
      try container.encode(usage, forKey: .usage)
    case let .finish(finish):
      try container.encode(Kind.finish, forKey: .kind)
      try container.encode(finish, forKey: .finish)
    case .done:
      try container.encode(Kind.done, forKey: .kind)
    }
  }
}

public enum ProviderTraceRedactor {
  public static func request(_ request: HarnessConversationRequest) -> HarnessConversationRequest {
    HarnessConversationRequest(
      modelID: request.modelID,
      messages: request.messages.map { message in
        HarnessChatMessage(
          role: message.role,
          content: message.content.map(redact),
          toolCalls: message.toolCalls.map { call in
            HarnessToolCall(id: call.id, name: call.name, argumentsJSON: redact(call.argumentsJSON))
          },
          toolCallID: message.toolCallID
        )
      }
    )
  }

  public static func redact(_ raw: String) -> String {
    var result = raw
    let patterns: [(String, String)] = [
      (#"(?i)(authorization\s*:\s*bearer\s+)[^\s,;]+"#, "$1[REDACTED]"),
      (#"\bsk-[A-Za-z0-9_-]{6,}\b"#, "[REDACTED]"),
      (#"(?i)((?:api[_-]?key|token|secret|password)\s*[=:]\s*)[^\s,;]+"#, "$1[REDACTED]"),
      (#"(?i)(\"(?:api[_-]?key|token|secret|password)\"\s*:\s*\")[^\"]+"#, "$1[REDACTED]")
    ]
    for (pattern, replacement) in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(result.startIndex..., in: result)
      result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
    }
    return result
  }
}

public actor ProviderTraceRecorder {
  private let fileURL: URL?
  private var traces: [UUID: ProviderTrace] = [:]
  private var activeTraceID: UUID?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    if let fileURL,
       let data = try? Data(contentsOf: fileURL),
       let text = String(data: data, encoding: .utf8) {
      let decoder = JSONDecoder()
      for line in text.split(whereSeparator: \.isNewline) {
        if let trace = try? decoder.decode(ProviderTrace.self, from: Data(line.utf8)) {
          traces[trace.id] = trace
        }
      }
    }
  }

  @discardableResult
  public func start(request: HarnessConversationRequest, tools: [ToolDefinition]) -> UUID {
    let trace = ProviderTrace(request: request, tools: tools)
    traces[trace.id] = trace
    activeTraceID = trace.id
    return trace.id
  }

  public func append(_ event: HarnessConversationEvent, traceID: UUID? = nil) {
    let id = traceID ?? activeTraceID
    guard let id, var trace = traces[id], trace.finishedAt == nil else { return }
    trace.blocks.append(ProviderTraceBlock(event))
    traces[id] = trace
  }

  public func finish(_ reason: HarnessConversationFinishReason, traceID: UUID? = nil) {
    let id = traceID ?? activeTraceID
    guard let id, var trace = traces[id], trace.finishedAt == nil else { return }
    trace.blocks.append(.finish(reason))
    trace.finishedAt = .now
    traces[id] = trace
    persist(trace)
    if activeTraceID == id { activeTraceID = nil }
  }

  /// Marks a trace complete without synthesizing a finish block. The provider
  /// already forwards the actual finish reason from the wire stream.
  public func complete(traceID: UUID? = nil) {
    let id = traceID ?? activeTraceID
    guard let id, var trace = traces[id], trace.finishedAt == nil else { return }
    trace.finishedAt = .now
    traces[id] = trace
    persist(trace)
    if activeTraceID == id { activeTraceID = nil }
  }

  public func fail(_ error: Error, traceID: UUID? = nil) {
    let id = traceID ?? activeTraceID
    guard let id, var trace = traces[id], trace.finishedAt == nil else { return }
    trace.errorMessage = error.localizedDescription
    trace.finishedAt = .now
    traces[id] = trace
    persist(trace)
    if activeTraceID == id { activeTraceID = nil }
  }

  public func record(id: UUID) -> ProviderTrace? { traces[id] }

  private func persist(_ trace: ProviderTrace) {
    guard let fileURL, let data = try? JSONEncoder().encode(trace) else { return }
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let line = data + Data([0x0A])
      if FileManager.default.fileExists(atPath: fileURL.path) {
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
      } else {
        try line.write(to: fileURL, options: .atomic)
      }
    } catch {
      // Diagnostic traces cannot compromise a live task.  The in-memory trace
      // is still available to the current Harness operation.
    }
  }
}

public enum ProviderReplayRunner {
  /// Deterministic offline replay used by regression tests and postmortems.
  /// It never contacts the provider and faithfully preserves sparse deltas.
  public static func events(from trace: ProviderTrace) -> [HarnessConversationEvent] {
    trace.blocks.map(\.event)
  }

  public static func stream(from trace: ProviderTrace) -> AsyncThrowingStream<HarnessConversationEvent, Error> {
    AsyncThrowingStream { continuation in
      for event in events(from: trace) { continuation.yield(event) }
      if let error = trace.errorMessage, !error.isEmpty {
        continuation.finish(throwing: NSError(domain: "ProviderReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
      } else {
        continuation.finish()
      }
    }
  }
}
