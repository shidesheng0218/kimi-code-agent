import Foundation

public struct KimiAgentHostConfiguration: Sendable {
  public let nodePath: String
  public let hostScriptURL: URL
  public let runtimePath: String
  public let workspacePath: String
  public let sessionID: String
  public let runtimeSessionID: String?
  public let taskID: String
  public let prompt: String
  public let modelID: String?
  public let skillsDirectories: [String]
  public let allowedDomains: [String]
  public let environment: [String: String]

  public init(
    nodePath: String,
    hostScriptURL: URL,
    runtimePath: String,
    workspacePath: String,
    sessionID: String,
    runtimeSessionID: String? = nil,
    taskID: String,
    prompt: String,
    modelID: String?,
    skillsDirectories: [String],
    allowedDomains: [String] = [],
    environment: [String: String] = [:]
  ) {
    self.nodePath = nodePath
    self.hostScriptURL = hostScriptURL
    self.runtimePath = runtimePath
    self.workspacePath = workspacePath
    self.sessionID = sessionID
    self.runtimeSessionID = runtimeSessionID
    self.taskID = taskID
    self.prompt = prompt
    self.modelID = modelID
    self.skillsDirectories = skillsDirectories
    self.allowedDomains = allowedDomains
    self.environment = environment
  }
}

public struct KimiAgentHostResult: Sendable {
  public let standardOutput: String
  public let standardError: String
  public let exitCode: Int32
}

public final class KimiAgentHostHandle: @unchecked Sendable {
  private let process: Process
  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe
  private let stderrPipe: Pipe
  private let onEnvelope: (AgentHostEnvelope) -> Void
  private let lock = NSLock()
  private var stdoutBuffer = Data()
  private var standardOutput = ""
  private var standardError = ""
  private var reportedHostError: String?

  init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe, onEnvelope: @escaping (AgentHostEnvelope) -> Void) {
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
    self.onEnvelope = onEnvelope
    observe(stdoutPipe.fileHandleForReading, stream: .standardOutput)
    observe(stderrPipe.fileHandleForReading, stream: .standardError)
  }

  public func approve(id: String, response: AgentHostApprovalResponse) throws {
    try send(AgentHostApprovalRequest(id: id, response: response))
  }

  public func terminate() {
    try? sendRaw(["type": "interrupt"])
    if process.isRunning {
      process.terminate()
    }
  }

  public func wait() -> KimiAgentHostResult {
    process.waitUntilExit()
    drain(stdoutPipe.fileHandleForReading, stream: .standardOutput)
    drain(stderrPipe.fileHandleForReading, stream: .standardError)
    lock.lock()
    let hostError = reportedHostError
    var combinedError = standardError
    if let hostError, !combinedError.contains(hostError) {
      if !combinedError.isEmpty, !combinedError.hasSuffix("\n") {
        combinedError += "\n"
      }
      combinedError += hostError
    }
    let result = KimiAgentHostResult(
      standardOutput: standardOutput,
      standardError: combinedError,
      exitCode: hostError == nil ? process.terminationStatus : max(process.terminationStatus, 1)
    )
    lock.unlock()
    return result
  }

  /// Bound ACP waiting so a broken runtime cannot leave a task stuck in `running` forever.
  public func wait(timeout: TimeInterval) -> KimiAgentHostResult {
    let deadline = Date().addingTimeInterval(max(timeout, 1))
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      terminate()
      process.waitUntilExit()
      lock.lock()
      if !standardError.contains("Native Agent Host 超时") {
        standardError += "\nNative Agent Host 超时（超过 \(Int(timeout)) 秒），已自动停止。"
      }
      lock.unlock()
    }
    drain(stdoutPipe.fileHandleForReading, stream: .standardOutput)
    drain(stderrPipe.fileHandleForReading, stream: .standardError)
    lock.lock()
    let hostError = reportedHostError
    var combinedError = standardError
    if let hostError, !combinedError.contains(hostError) {
      if !combinedError.isEmpty, !combinedError.hasSuffix("\n") { combinedError += "\n" }
      combinedError += hostError
    }
    let result = KimiAgentHostResult(
      standardOutput: standardOutput,
      standardError: combinedError,
      exitCode: hostError == nil ? process.terminationStatus : max(process.terminationStatus, 1)
    )
    lock.unlock()
    return result
  }

  private func send<T: Encodable>(_ value: T) throws {
    let data = try AgentHostBridgeProtocol.encode(value)
    try write(data)
  }

  private func sendRaw(_ value: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    try write(data)
  }

  private func write(_ data: Data) throws {
    guard process.isRunning else {
      throw NSError(domain: "KimiAgentHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Agent Host 已停止。"])
    }
    lock.lock()
    defer { lock.unlock() }
    stdinPipe.fileHandleForWriting.write(data)
    stdinPipe.fileHandleForWriting.write(Data([0x0A]))
  }

  private func observe(_ fileHandle: FileHandle, stream: KimiProcessStream) {
    fileHandle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.append(data, stream: stream)
    }
  }

  private func drain(_ fileHandle: FileHandle, stream: KimiProcessStream) {
    fileHandle.readabilityHandler = nil
    let remainingData = fileHandle.readDataToEndOfFile()
    if !remainingData.isEmpty {
      append(remainingData, stream: stream)
    }
  }

  private func append(_ data: Data, stream: KimiProcessStream) {
    switch stream {
    case .standardError:
      let text = String(data: data, encoding: .utf8) ?? ""
      lock.lock()
      standardError += text
      lock.unlock()
    case .standardOutput:
      var lines: [Data] = []
      lock.lock()
      standardOutput += String(data: data, encoding: .utf8) ?? ""
      stdoutBuffer.append(data)
      while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
        lines.append(stdoutBuffer[..<newline])
        stdoutBuffer.removeSubrange(...newline)
      }
      lock.unlock()

      for line in lines where !line.isEmpty {
        if let envelope = try? AgentHostBridgeProtocol.decodeEnvelope(line) {
          if envelope.type == "error", let message = envelope.message, !message.isEmpty {
            lock.lock()
            reportedHostError = message
            lock.unlock()
          }
          onEnvelope(envelope)
        }
      }
    }
  }
}

public enum KimiAgentHostRunner {
  public static func start(
    configuration: KimiAgentHostConfiguration,
    onEnvelope: @escaping (AgentHostEnvelope) -> Void
  ) throws -> KimiAgentHostHandle {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: configuration.nodePath)
    process.arguments = [configuration.hostScriptURL.path]
    process.currentDirectoryURL = URL(fileURLWithPath: configuration.workspacePath, isDirectory: true)
    process.environment = ProcessInfo.processInfo.environment
      .merging(configuration.environment, uniquingKeysWith: { _, new in new })
      .merging([
      "KIMI_RUNTIME_PATH": configuration.runtimePath,
      "KIMI_NODE_PATH": configuration.nodePath,
      "KIMI_AGENT_ALLOWED_DOMAINS": configuration.allowedDomains.joined(separator: ",")
    ], uniquingKeysWith: { _, new in new })

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()

    let handle = KimiAgentHostHandle(
      process: process,
      stdinPipe: stdinPipe,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      onEnvelope: onEnvelope
    )
    do {
      try handle.sendStart(configuration)
      return handle
    } catch {
      handle.terminate()
      throw error
    }
  }
}

private extension KimiAgentHostHandle {
  func sendStart(_ configuration: KimiAgentHostConfiguration) throws {
    try send(AgentHostStartRequest(
      sessionID: configuration.sessionID,
      runtimeSessionID: configuration.runtimeSessionID,
      taskID: configuration.taskID,
      workspacePath: configuration.workspacePath,
      prompt: configuration.prompt,
      modelID: configuration.modelID,
      runtimePath: configuration.runtimePath,
      nodePath: configuration.nodePath,
      skillsDirectories: configuration.skillsDirectories
    ))
  }
}
