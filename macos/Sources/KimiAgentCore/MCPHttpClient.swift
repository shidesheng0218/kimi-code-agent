import Foundation

public final class MCPHttpClient: @unchecked Sendable {
  private let endpoint: URL
  private let session: URLSession
  private let lock = NSLock()
  private let timeoutSeconds: TimeInterval
  private var nextID: Int64 = 0
  private var initializeResult: MCPInitializeResult?

  public init(
    endpoint: URL,
    allowedDomains: [String] = [],
    session: URLSession? = nil,
    timeoutSeconds: TimeInterval = 15
  ) throws {
    try Self.validate(endpoint: endpoint, allowedDomains: allowedDomains)
    self.endpoint = endpoint
    if let session {
      self.session = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = timeoutSeconds
      self.session = URLSession(
        configuration: configuration,
        delegate: RedirectValidator(allowedDomains: allowedDomains),
        delegateQueue: nil
      )
    }
    self.timeoutSeconds = timeoutSeconds
  }

  public func initialize() throws -> MCPInitializeResult {
    if let initializeResult {
      return initializeResult
    }
    let response = try request(method: "initialize", params: [
      "protocolVersion": "2024-11-05",
      "clientInfo": ["name": "KimiAgentDesktop", "version": "0.3.0"],
      "capabilities": ["tools": [:]]
    ])
    let protocolVersion = response["protocolVersion"] as? String ?? "2024-11-05"
    guard let serverInfo = response["serverInfo"] as? [String: Any],
          let name = serverInfo["name"] as? String,
          let version = serverInfo["version"] as? String else {
      throw MCPClientError.malformedResponse
    }
    _ = try? request(method: "notifications/initialized", params: [:], expectResult: false)
    let result = MCPInitializeResult(
      protocolVersion: protocolVersion,
      serverInfo: MCPServerInfo(name: name, version: version)
    )
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

  public func close() {}

  private func request(method: String, params: [String: Any], expectResult: Bool = true) throws -> [String: Any] {
    lock.lock()
    let requestID = nextID + 1
    nextID = requestID
    lock.unlock()

    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": requestID,
      "method": method,
      "params": params
    ]
    let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    let semaphore = DispatchSemaphore(value: 0)
    let capture = ResponseCapture()

    let task = session.dataTask(with: request) { data, response, error in
      capture.data = data
      capture.error = error
      capture.statusCode = (response as? HTTPURLResponse)?.statusCode
      semaphore.signal()
    }
    task.resume()

    if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
      task.cancel()
      throw MCPClientError.timeout
    }
    if let responseError = capture.error {
      throw responseError
    }
    if let statusCode = capture.statusCode, !(200..<300).contains(statusCode) {
      throw MCPClientError.errorResponse("HTTP \(statusCode)")
    }
    if !expectResult {
      return [:]
    }
    guard let responseData = capture.data, !responseData.isEmpty else {
      throw MCPClientError.missingResult
    }
    guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
      throw MCPClientError.malformedResponse
    }
    if let error = object["error"] as? [String: Any] {
      throw MCPClientError.errorResponse((error["message"] as? String) ?? "MCP error")
    }
    guard let result = object["result"] as? [String: Any] else {
      throw MCPClientError.missingResult
    }
    return result
  }

  private static func validate(endpoint: URL, allowedDomains: [String]) throws {
    guard let host = endpoint.host?.lowercased(), !host.isEmpty else {
      throw MCPClientError.endpointNotAllowed(endpoint.absoluteString)
    }
    if isLocalhost(host) {
      return
    }
    if allowedDomains.map({ $0.lowercased() }).contains(where: { matches(host: host, domain: $0) }) {
      return
    }
    throw MCPClientError.endpointNotAllowed(host)
  }

  static func isLocalhost(_ host: String) -> Bool {
    host == "localhost" || host == "::1" || host.hasPrefix("127.") || host.hasSuffix(".localhost")
  }

  static func matches(host: String, domain: String) -> Bool {
    if domain.hasPrefix("*.") {
      let suffix = String(domain.dropFirst())
      return host == String(domain.dropFirst(2)) || host.hasSuffix(suffix)
    }
    return host == domain || host.hasSuffix(".\(domain)")
  }

  private static func jsonString(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }
}

private final class ResponseCapture: @unchecked Sendable {
  var data: Data?
  var error: Error?
  var statusCode: Int?
}

/// Re-validates every redirect destination against the same endpoint
/// allowlist used at construction, so a configured remote server cannot
/// bounce the client to loopback or other internal addresses.
private final class RedirectValidator: NSObject, URLSessionTaskDelegate {
  private let allowedDomains: [String]

  init(allowedDomains: [String]) {
    self.allowedDomains = allowedDomains
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if let url = request.url,
       let host = url.host?.lowercased(),
       !host.isEmpty,
       MCPHttpClient.isLocalhost(host)
        || allowedDomains.contains(where: { MCPHttpClient.matches(host: host, domain: $0) }) {
      completionHandler(request)
      return
    }
    completionHandler(nil)
  }
}
