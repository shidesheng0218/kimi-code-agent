import Foundation

public struct MCPServerInfo: Codable, Equatable, Sendable {
  public let name: String
  public let version: String

  public init(name: String, version: String) {
    self.name = name
    self.version = version
  }
}

public struct MCPInitializeResult: Codable, Equatable, Sendable {
  public let protocolVersion: String
  public let serverInfo: MCPServerInfo

  public init(protocolVersion: String, serverInfo: MCPServerInfo) {
    self.protocolVersion = protocolVersion
    self.serverInfo = serverInfo
  }
}

public struct MCPTool: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let inputSchemaJSON: String

  public init(name: String, description: String, inputSchemaJSON: String) {
    self.id = name
    self.name = name
    self.description = description
    self.inputSchemaJSON = inputSchemaJSON
  }
}

public struct MCPToolCallResult: Codable, Equatable, Sendable {
  public let standardOutput: String
  public let rawJSON: String

  public init(standardOutput: String, rawJSON: String) {
    self.standardOutput = standardOutput
    self.rawJSON = rawJSON
  }
}

public enum MCPClientError: LocalizedError {
  case notConnected
  case endpointNotAllowed(String)
  case malformedResponse
  case missingResult
  case errorResponse(String)
  case timeout

  public var errorDescription: String? {
    switch self {
    case .notConnected:
      return "MCP client is not connected."
    case let .endpointNotAllowed(endpoint):
      return "MCP endpoint is not allowed: \(endpoint)"
    case .malformedResponse:
      return "MCP response was malformed."
    case .missingResult:
      return "MCP response did not contain a result."
    case let .errorResponse(message):
      return message
    case .timeout:
      return "MCP request timed out."
    }
  }
}

public final class MCPStdioClient: @unchecked Sendable {
  private let process: Process
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private let lock = NSLock()
  private let condition = NSCondition()
  private let standardOutputDecoder = TerminalUTF8StreamDecoder()
  private let standardErrorDecoder = TerminalUTF8StreamDecoder()
  private let sandboxProfileURL: URL?
  private var lineBuffer = ""
  private var responseBuffer: [Int64: [String: Any]] = [:]
  private var stderrText = ""
  private var nextID: Int64 = 0
  private var isClosed = false
  private var didTerminate = false
  private var initializeResult: MCPInitializeResult?

  public init(
    command: String,
    arguments: [String],
    workingDirectory: URL? = nil,
    sandbox: TerminalSandboxConfiguration? = nil
  ) throws {
    process = Process()
    var environment = ProcessInfo.processInfo.environment
    var generatedProfileURL: URL?
    let innerExecutable: URL
    let innerArguments: [String]
    if command.contains("/") {
      innerExecutable = URL(fileURLWithPath: command)
      innerArguments = arguments
    } else {
      innerExecutable = URL(fileURLWithPath: "/usr/bin/env")
      innerArguments = [command] + arguments
    }
    if let sandbox, sandbox.enabled, TerminalSandboxConfiguration.isSupported {
      try FileManager.default.createDirectory(at: sandbox.scratchURL, withIntermediateDirectories: true)
      let profileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-mcp-\(UUID().uuidString).sb")
      try sandbox.profile().write(to: profileURL, atomically: true, encoding: .utf8)
      generatedProfileURL = profileURL
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = ["-f", profileURL.path, innerExecutable.path] + innerArguments
      process.currentDirectoryURL = workingDirectory.map(sandbox.canonicalizedURL)
      environment["HOME"] = sandbox.scratchURL.path
      environment["ZDOTDIR"] = sandbox.scratchURL.path
      environment["HISTFILE"] = "/dev/null"
    } else {
      process.executableURL = innerExecutable
      process.arguments = innerArguments
      process.currentDirectoryURL = workingDirectory
    }
    sandboxProfileURL = generatedProfileURL
    process.environment = environment
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.terminationHandler = { [weak self] _ in
      self?.handleTermination()
    }
    try process.run()
    observe(stdoutPipe.fileHandleForReading, stream: .stdout)
    observe(stderrPipe.fileHandleForReading, stream: .stderr)
  }

  deinit {
    close()
  }

  public func initialize() throws -> MCPInitializeResult {
    if let initializeResult {
      return initializeResult
    }
    let params: [String: Any] = [
      "protocolVersion": "2024-11-05",
      "clientInfo": ["name": "KimiAgentDesktop", "version": "0.3.0"],
      "capabilities": ["tools": [:]]
    ]
    let response = try request(method: "initialize", params: params)
    let protocolVersion = response["protocolVersion"] as? String ?? "2024-11-05"
    guard let serverInfo = response["serverInfo"] as? [String: Any],
          let name = serverInfo["name"] as? String,
          let version = serverInfo["version"] as? String else {
      throw MCPClientError.malformedResponse
    }
    _ = try? request(method: "notifications/initialized", params: [:], expectResponse: false)
    let result = MCPInitializeResult(protocolVersion: protocolVersion, serverInfo: MCPServerInfo(name: name, version: version))
    initializeResult = result
    return result
  }

  public func listTools() throws -> [MCPTool] {
    let response = try request(method: "tools/list", params: [:])
    guard let tools = response["tools"] as? [[String: Any]] else {
      throw MCPClientError.malformedResponse
    }
    return tools.compactMap { tool in
      guard let name = tool["name"] as? String else { return nil }
      let description = tool["description"] as? String ?? ""
      let inputSchema = tool["inputSchema"].flatMap { Self.jsonString($0) } ?? "{}"
      return MCPTool(name: name, description: description, inputSchemaJSON: inputSchema)
    }
  }

  public func callTool(name: String, arguments: [String: String]) throws -> MCPToolCallResult {
    let response = try request(method: "tools/call", params: ["name": name, "arguments": arguments])
    let rawJSON = Self.jsonString(response) ?? "{}"
    let contents = response["content"] as? [[String: Any]] ?? []
    let text = contents.compactMap { $0["text"] as? String }.joined(separator: "\n")
    return MCPToolCallResult(standardOutput: text, rawJSON: rawJSON)
  }

  public func close() {
    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    isClosed = true
    lock.unlock()
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    cleanupSandboxProfile()
  }

  private enum Stream {
    case stdout
    case stderr
  }

  private func observe(_ fileHandle: FileHandle, stream: Stream) {
    fileHandle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.ingest(data, stream: stream)
    }
  }

  private func ingest(_ data: Data, stream: Stream) {
    let text: String
    switch stream {
    case .stdout: text = standardOutputDecoder.append(data)
    case .stderr: text = standardErrorDecoder.append(data)
    }
    guard !text.isEmpty else { return }
    switch stream {
    case .stdout:
      lock.lock()
      lineBuffer += text
      while let newline = lineBuffer.firstIndex(of: "\n") {
        let line = String(lineBuffer[..<newline])
        lineBuffer.removeSubrange(...newline)
        handleLine(line)
      }
      lock.unlock()
    case .stderr:
      lock.lock()
      stderrText += text
      lock.unlock()
    }
  }

  private func handleLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
      return
    }
    guard let id = Self.int64ID(dictionary["id"]) else { return }
    condition.lock()
    responseBuffer[id] = dictionary
    condition.broadcast()
    condition.unlock()
  }

  private func request(method: String, params: [String: Any], expectResponse: Bool = true) throws -> [String: Any] {
    lock.lock()
    guard !isClosed, !didTerminate, process.isRunning else {
      lock.unlock()
      throw MCPClientError.notConnected
    }
    nextID += 1
    let id = nextID
    lock.unlock()
    let request: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: request) else {
      throw MCPClientError.malformedResponse
    }
    // Serialize payload writes so parallel callers cannot interleave bytes
    // and corrupt the JSON-RPC framing on the shared stdin pipe.
    lock.lock()
    stdinPipe.fileHandleForWriting.write(data)
    stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    lock.unlock()

    guard expectResponse else { return [:] }
    let deadline = Date().addingTimeInterval(10)
    condition.lock()
    defer { condition.unlock() }
    while responseBuffer[id] == nil {
      if isClosed || didTerminate || !process.isRunning {
        throw MCPClientError.notConnected
      }
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 {
        throw MCPClientError.timeout
      }
      _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.1)))
      if isClosed {
        throw MCPClientError.notConnected
      }
    }

    guard let response = responseBuffer.removeValue(forKey: id) else {
      throw MCPClientError.malformedResponse
    }
    if let error = response["error"] as? [String: Any] {
      throw MCPClientError.errorResponse((error["message"] as? String) ?? "MCP error")
    }
    guard let result = response["result"] as? [String: Any] else {
      throw MCPClientError.missingResult
    }
    return result
  }

  private func handleTermination() {
    lock.lock()
    didTerminate = true
    lock.unlock()
    condition.lock()
    condition.broadcast()
    condition.unlock()
    cleanupSandboxProfile()
  }

  private func cleanupSandboxProfile() {
    guard let sandboxProfileURL else { return }
    try? FileManager.default.removeItem(at: sandboxProfileURL)
  }

  private static func int64ID(_ value: Any?) -> Int64? {
    switch value {
    case let value as Int64:
      return value
    case let value as Int:
      return Int64(value)
    case let value as NSNumber:
      return value.int64Value
    case let value as String:
      return Int64(value)
    default:
      return nil
    }
  }

  private static func jsonString(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
      return nil
    }
    return text
  }
}
