import Foundation

public enum MCPHarnessToolIdentifier {
  public static let prefix = "mcp."

  public static func resourceReader(serverID: UUID) -> String {
    "\(prefix)\(serverID.uuidString.lowercased()).resources.read"
  }

  public static func promptGetter(serverID: UUID) -> String {
    "\(prefix)\(serverID.uuidString.lowercased()).prompts.get"
  }

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
  private let workerSupervisor: MCPWorkerSupervisor?

  public init(runtime: ProjectExtensionRuntime, workerSupervisor: MCPWorkerSupervisor? = nil) {
    self.runtime = runtime
    self.workerSupervisor = workerSupervisor
  }

  public func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    let target = try resolveTarget(for: request)
    // ProjectExtensionRuntime owns synchronous MCP clients. Isolating the
    // blocking call keeps the Harness actor and SwiftUI main actor responsive.
    do {
      let result = try await Task.detached(priority: .userInitiated) { [runtime] in
        switch target {
        case let .tool(serverID, toolName, arguments):
          let value = try runtime.callMCPTool(serverID: serverID, name: toolName, arguments: arguments)
          return ResolvedResult.tool(value)
        case let .resource(serverID, uri):
          return .resource(try runtime.readMCPResource(serverID: serverID, uri: uri))
        case let .prompt(serverID, name, arguments):
          return .prompt(try runtime.getMCPPrompt(serverID: serverID, name: name, arguments: arguments))
        }
      }.value
      let serverID = target.serverID
      await workerSupervisor?.markHealthy(serverID: target.serverID.uuidString)
      return result.toolExecutionResult(serverID: serverID)
    } catch {
      // A failed call is never replayed here: the ToolExecutionCoordinator
      // owns the current Intent/Receipt boundary. We only mark the Worker
      // degraded and perform a bounded reconnect so the next explicit model
      // call can recover without duplicating an unknown MCP side effect.
      if let workerSupervisor,
         await workerSupervisor.markFailure(serverID: target.serverID.uuidString, message: error.localizedDescription) {
        let statuses = (try? await Task.detached(priority: .utility) { [runtime] in
          try runtime.refreshMCPStatuses()
        }.value) ?? []
        if statuses.first(where: { $0.id == target.serverID })?.state == .running {
          await workerSupervisor.markHealthy(serverID: target.serverID.uuidString)
        }
      }
      throw error
    }
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
      let resources = try runtime.listMCPResources(serverID: server.id)
      if !resources.isEmpty {
        let names = resources.prefix(8).map(\.name).joined(separator: "、")
        definitions.append(ToolDefinition(
          id: MCPHarnessToolIdentifier.resourceReader(serverID: server.id),
          title: "MCP · \(server.name) · 读取资源",
          description: "读取 MCP Resource。可用资源：\(names)。",
          permissionScopes: [.network],
          risk: .medium,
          executionMode: .sessionSerial,
          supportsBackground: true,
          inputSchemaJSON: #"{"type":"object","properties":{"uri":{"type":"string"}},"required":["uri"],"additionalProperties":false}"#
        ))
      }
      let prompts = try runtime.listMCPPrompts(serverID: server.id)
      if !prompts.isEmpty {
        let names = prompts.prefix(8).map(\.name).joined(separator: "、")
        definitions.append(ToolDefinition(
          id: MCPHarnessToolIdentifier.promptGetter(serverID: server.id),
          title: "MCP · \(server.name) · 获取提示",
          description: "获取 MCP Prompt。可用提示：\(names)。除 name 外的字符串参数将传给指定 Prompt。",
          permissionScopes: [.network],
          risk: .medium,
          executionMode: .sessionSerial,
          supportsBackground: true,
          inputSchemaJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":{"type":"string"}}"#
        ))
      }
    }
    return definitions.sorted { $0.id < $1.id }
  }

  private enum Target {
    case tool(serverID: UUID, toolName: String, arguments: [String: String])
    case resource(serverID: UUID, uri: String)
    case prompt(serverID: UUID, name: String, arguments: [String: String])

    var serverID: UUID {
      switch self {
      case let .tool(serverID, _, _), let .resource(serverID, _), let .prompt(serverID, _, _):
        return serverID
      }
    }
  }

  private enum ResolvedResult: Sendable {
    case tool(MCPToolCallResult)
    case resource([MCPResourceContent])
    case prompt(MCPPromptResult)

    func toolExecutionResult(serverID: UUID) -> ToolExecutionResult {
      switch self {
      case let .tool(result):
        return ToolExecutionResult(
          output: result.standardOutput,
          metadata: [
            "server_id": serverID.uuidString,
            "kind": "tool",
            "raw_json": result.rawJSON,
            "worker_state": MCPWorkerState.healthy.rawValue
          ]
        )
      case let .resource(contents):
        let output = contents.map { content in
          content.text ?? content.blob ?? "（资源没有可读取的文本或 Blob 内容）"
        }.joined(separator: "\n\n")
        return ToolExecutionResult(
          output: output,
          metadata: [
            "server_id": serverID.uuidString,
            "kind": "resource",
            "resource_count": String(contents.count),
            "uris": contents.map(\.uri).joined(separator: "\n"),
            "worker_state": MCPWorkerState.healthy.rawValue
          ]
        )
      case let .prompt(result):
        let output = result.messages.map { "[\($0.role)] \($0.text)" }.joined(separator: "\n\n")
        return ToolExecutionResult(
          output: output,
          metadata: [
            "server_id": serverID.uuidString,
            "kind": "prompt",
            "message_count": String(result.messages.count),
            "worker_state": MCPWorkerState.healthy.rawValue
          ]
        )
      }
    }
  }

  private func resolveTarget(for request: ToolExecutionRequest) throws -> Target {
    if let parsed = MCPHarnessToolIdentifier.parse(request.toolID) {
      if request.toolID == MCPHarnessToolIdentifier.resourceReader(serverID: parsed.serverID) {
        guard let uri = request.input["uri"]?.trimmingCharacters(in: .whitespacesAndNewlines), !uri.isEmpty else {
          throw NativeHarnessToolError.missingInput("uri")
        }
        return .resource(serverID: parsed.serverID, uri: uri)
      }
      if request.toolID == MCPHarnessToolIdentifier.promptGetter(serverID: parsed.serverID) {
        guard let name = request.input["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
          throw NativeHarnessToolError.missingInput("name")
        }
        var arguments = request.input
        arguments.removeValue(forKey: "name")
        return .prompt(serverID: parsed.serverID, name: name, arguments: arguments)
      }
      return .tool(serverID: parsed.serverID, toolName: parsed.toolName, arguments: request.input)
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
    return .tool(serverID: serverID, toolName: name, arguments: arguments)
  }
}
