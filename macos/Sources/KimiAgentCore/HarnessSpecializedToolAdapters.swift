import Foundation

public enum MCPHarnessToolIdentifier {
  public static let prefix = "mcp."

  public static func make(serverID: UUID, toolName: String) -> String {
    "\(prefix)\(serverID.uuidString.lowercased()).\(toolName)"
  }

  public static func parse(_ toolID: String) -> (serverID: UUID, toolName: String)? {
    guard toolID.hasPrefix(prefix) else { return nil }
    let remainder = String(toolID.dropFirst(prefix.count))
    guard let separator = remainder.firstIndex(of: "."),
          let serverID = UUID(uuidString: String(remainder[..<separator])) else { return nil }
    let toolName = String(remainder[remainder.index(after: separator)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !toolName.isEmpty else { return nil }
    return (serverID, toolName)
  }
}

public enum BrowserHarnessRequestDecoder {
  public static func plan(
    from request: ToolExecutionRequest,
    fallbackURL: URL? = nil,
    hasOpenPage: Bool = false
  ) throws -> BrowserVerificationPlan {
    if let encoded = request.input["plan"],
       let data = encoded.data(using: .utf8),
       let plan = try? JSONDecoder().decode(BrowserVerificationPlan.self, from: data) {
      return plan
    }
    let rawKind = request.input["action"] ?? request.input["kind"] ?? "open"
    guard let kind = BrowserVerificationStepKind(rawValue: rawKind) else {
      throw BrowserHarnessAdapterError.invalidBrowserAction(rawKind)
    }
    let rawURL = request.input["url"].flatMap(URL.init(string:))
    // Tool-call arguments occasionally contain the complete natural-language
    // instruction after the URL. When the model targets the same host as the
    // user's explicit URL, prefer that trusted task URL instead of executing a
    // polluted path such as `%EF%BC%8C检查页面...`.
    let stepURL: URL?
    if let rawURL, let fallbackURL,
       rawURL.host?.lowercased() == fallbackURL.host?.lowercased() {
      stepURL = fallbackURL
    } else {
      stepURL = rawURL
    }
    let step = BrowserVerificationStep(
      kind: kind,
      url: stepURL ?? ((kind == .open || kind == .navigate) ? fallbackURL : nil),
      selector: request.input["selector"],
      text: request.input["text"],
      key: request.input["key"],
      artifactName: request.input["artifact_name"]
    )
    let allowedDomains = request.input["allowed_domains"]
      .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } }
      ?? []
    // Models often emit a narrow `inspect` or `screenshot` call after an
    // earlier `open` call. A tool loop can legitimately replay that call
    // without its prior WebView instance, so restore only the explicit URL
    // written by the user into the current task. No new destination is ever
    // inferred here.
    if !hasOpenPage,
       kind != .open,
       kind != .navigate,
       let fallbackURL {
      return BrowserVerificationPlan(
        allowedDomains: allowedDomains,
        steps: [
          BrowserVerificationStep(kind: .open, url: fallbackURL),
          step
        ]
      )
    }
    return BrowserVerificationPlan(allowedDomains: allowedDomains, steps: [step])
  }

  public static func firstHTTPURL(in text: String) -> URL? {
    let pattern = #"https?://[^\s<>\]\[\)\}\x{FF0C}\x{3002}\x{FF1B}\x{FF1A}\x{3001}\x{FF01}\x{FF1F}\x{3009}\x{300B}\x{3011}\x{3010}\"']+"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text) else { return nil }
    let candidate = String(text[range])
      .trimmingCharacters(in: CharacterSet(charactersIn: "，。；：、！？）》】】\"'"))
    return URL(string: candidate)
  }
}

public enum BrowserHarnessAdapterError: LocalizedError, Equatable {
  case invalidBrowserAction(String)
  case missingMCPServer
  case missingMCPTool

  public var errorDescription: String? {
    switch self {
    case let .invalidBrowserAction(value): "不支持的浏览器动作：\(value)"
    case .missingMCPServer: "MCP 工具缺少 server_id。"
    case .missingMCPTool: "MCP 工具缺少 name。"
    }
  }
}

public final class MCPHarnessToolExecutor: ToolExecutor, @unchecked Sendable {
  private let runtime: ProjectExtensionRuntime

  public init(runtime: ProjectExtensionRuntime) {
    self.runtime = runtime
  }

  public func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    let target = try resolveTarget(for: request)
    // ProjectExtensionRuntime owns synchronous MCP clients. Isolating the
    // blocking call keeps the Harness actor and SwiftUI main actor responsive.
    let result = try await Task.detached(priority: .userInitiated) { [runtime] in
      try runtime.callMCPTool(serverID: target.serverID, name: target.toolName, arguments: target.arguments)
    }.value
    return ToolExecutionResult(
      output: result.standardOutput,
      metadata: [
        "server_id": target.serverID.uuidString,
        "tool": target.toolName,
        "raw_json": result.rawJSON
      ]
    )
  }

  public func discoverDefinitions() throws -> [ToolDefinition] {
    let configuration = try runtime.loadConfiguration()
    var definitions: [ToolDefinition] = []
    for server in configuration.mcpServers where server.isEnabled {
      let tools = try runtime.listMCPTools(serverID: server.id)
      definitions.append(contentsOf: tools.map { tool in
        ToolDefinition(
          id: MCPHarnessToolIdentifier.make(serverID: server.id, toolName: tool.name),
          title: "MCP · \(server.name) · \(tool.name)",
          description: tool.description.isEmpty ? "调用 MCP 工具 \(tool.name)。" : tool.description,
          permissionScopes: [.network],
          risk: .medium,
          executionMode: .sessionSerial,
          supportsBackground: true,
          inputSchemaJSON: tool.inputSchemaJSON
        )
      })
    }
    return definitions.sorted { $0.id < $1.id }
  }

  private func resolveTarget(for request: ToolExecutionRequest) throws -> (serverID: UUID, toolName: String, arguments: [String: String]) {
    if let parsed = MCPHarnessToolIdentifier.parse(request.toolID) {
      return (parsed.serverID, parsed.toolName, request.input)
    }
    guard let rawServerID = request.input["server_id"], let serverID = UUID(uuidString: rawServerID) else {
      throw BrowserHarnessAdapterError.missingMCPServer
    }
    guard let name = request.input["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      throw BrowserHarnessAdapterError.missingMCPTool
    }
    var arguments = request.input
    arguments.removeValue(forKey: "server_id")
    arguments.removeValue(forKey: "name")
    return (serverID, name, arguments)
  }
}
