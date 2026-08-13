import Foundation

public struct KimiChildRuntimeConfiguration: Sendable {
  public let nodePath: String
  public let hostScriptURL: URL
  public let runtimePath: String
  public let workspacePath: String
  public let taskID: String
  public let modelID: String?
  public let skillsDirectories: [String]
  public let allowedDomains: [String]
  public let environment: [String: String]
  public let timeoutSeconds: TimeInterval

  public init(
    nodePath: String,
    hostScriptURL: URL,
    runtimePath: String,
    workspacePath: String,
    taskID: String,
    modelID: String? = nil,
    skillsDirectories: [String] = [],
    allowedDomains: [String] = [],
    environment: [String: String] = [:],
    timeoutSeconds: TimeInterval = 120
  ) {
    self.nodePath = nodePath
    self.hostScriptURL = hostScriptURL
    self.runtimePath = runtimePath
    self.workspacePath = workspacePath
    self.taskID = taskID
    self.modelID = modelID
    self.skillsDirectories = skillsDirectories
    self.allowedDomains = allowedDomains
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
  }
}

public enum KimiChildRuntimeError: LocalizedError, Equatable {
  case hostExited(code: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case let .hostExited(code, message):
      "Child Agent Runtime 退出（" + String(code) + "）：" + message
    }
  }
}

/// Bridges an independent Child Session to the same Native Agent Host used by
/// the main conversation. Every child gets a distinct session ID and its own
/// event callback, while the host/CLI compatibility logic remains shared.
public final class KimiChildRuntimeExecutor: @unchecked Sendable {
  public let configuration: KimiChildRuntimeConfiguration
  private let onEvent: @Sendable (AgentEvent) -> Void
  private let lock = NSLock()
  private var activeHandles: [UUID: KimiAgentHostHandle] = [:]

  public init(
    configuration: KimiChildRuntimeConfiguration,
    onEvent: @escaping @Sendable (AgentEvent) -> Void
  ) {
    self.configuration = configuration
    self.onEvent = onEvent
  }

  public func execute(
    session: SessionRecord,
    prompt: String,
    tools: [ToolDefinition]
  ) async throws -> AgentResult {
    let toolIDs = tools.map(\.id).joined(separator: ", ")
    let childPrompt = "你是独立 Child Agent：" + session.agentID +
      "。\n只处理分配给你的子任务，完成后返回简洁结论、变更或验证结果，不输出内部思考。\n" +
      "当前允许工具：" + (toolIDs.isEmpty ? "无" : toolIDs) + "。\n子任务：\n" + prompt
    let handle = try KimiAgentHostRunner.start(
      configuration: KimiAgentHostConfiguration(
        nodePath: configuration.nodePath,
        hostScriptURL: configuration.hostScriptURL,
        runtimePath: configuration.runtimePath,
        workspacePath: session.worktreePath ?? configuration.workspacePath,
        sessionID: session.id.uuidString,
        runtimeSessionID: nil,
        taskID: configuration.taskID,
        prompt: childPrompt,
        modelID: session.modelID ?? configuration.modelID,
        skillsDirectories: configuration.skillsDirectories,
        allowedDomains: configuration.allowedDomains,
        environment: configuration.environment
      ),
      onEnvelope: { [onEvent] envelope in
        guard let event = envelope.event else { return }
        onEvent(event)
      }
    )
    setHandle(handle, for: session.id)
    defer {
      removeHandle(for: session.id)
    }
    let timeout = configuration.timeoutSeconds
    let result = await Task.detached(priority: .userInitiated) {
      handle.wait(timeout: timeout)
    }.value
    guard result.exitCode == 0 else {
      let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw KimiChildRuntimeError.hostExited(code: result.exitCode, message: message.isEmpty ? "无错误详情" : message)
    }

    let output = result.standardOutput
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        guard let event = try? AgentHostBridgeProtocol.decodeEnvelope(Data(line.utf8)),
              let agentEvent = event.event,
              agentEvent.kind == .output else { return nil }
        return agentEvent.payload["text"]
      }
      .joined()
    let summary = AssistantReplySanitizer.finalConversationText(from: output)
      ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    return AgentResult(summary: summary.isEmpty ? "Child Agent 已完成。" : summary)
  }

  public func cancel(sessionID: UUID) {
    let handle = handle(for: sessionID)
    handle?.terminate()
  }

  private func setHandle(_ handle: KimiAgentHostHandle, for sessionID: UUID) {
    lock.lock()
    activeHandles[sessionID] = handle
    lock.unlock()
  }

  private func removeHandle(for sessionID: UUID) {
    lock.lock()
    activeHandles.removeValue(forKey: sessionID)
    lock.unlock()
  }

  private func handle(for sessionID: UUID) -> KimiAgentHostHandle? {
    lock.lock()
    defer { lock.unlock() }
    return activeHandles[sessionID]
  }
}
