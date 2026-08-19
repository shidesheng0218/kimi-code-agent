import AppKit
import Foundation
import KimiAgentCore
import Security

@main
struct KimiNativeBridge {
  static func main() async {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else {
      emit(KimiNativeBridgeResponse(requestID: "unknown", ok: false, error: "原生桥接未收到请求。"))
      return
    }

    do {
      let request = try JSONDecoder().decode(KimiNativeBridgeRequest.self, from: data)
      do {
        try request.validate()
        emit(try await execute(request))
      } catch {
        emit(KimiNativeBridgeResponse.failure(requestID: request.requestID, error: error.localizedDescription))
      }
    } catch {
      emit(KimiNativeBridgeResponse(requestID: "unknown", ok: false, error: error.localizedDescription))
    }
  }

  private static func execute(_ request: KimiNativeBridgeRequest) async throws -> KimiNativeBridgeResponse {
    switch request.operation {
    case .webSearch:
      let runtime = try await webRuntime(requiresSearchProvider: true)
      let result = try await runtime.search(WebSearchRequest(
        query: request.query ?? "",
        maxResults: request.maxResults ?? 8
      ))
      try webSourceStore().record(result.sources)
      let sources = try JSONEncoder().encode(result.sources)
      let output = result.sources.map { source in
        let snippet = source.snippet.isEmpty ? "" : " — \(source.snippet)"
        return "- [\(source.title)](\(source.url))\(snippet)"
      }.joined(separator: "\n")
      return KimiNativeBridgeResponse(
        requestID: request.requestID,
        ok: true,
        output: output.isEmpty ? "未找到公开来源。" : output,
        metadata: [
          "provider": result.providerID,
          "sources": String(data: sources, encoding: .utf8) ?? "[]",
          "fallback": result.fallbackUsed ? "true" : "false",
          "elapsedMS": String(result.elapsedMilliseconds)
        ]
      )
    case .webFetch:
      if let sourceID = request.sourceID?.trimmingCharacters(in: .whitespacesAndNewlines), !sourceID.isEmpty {
        try webSourceStore().validate(sourceID: sourceID, url: request.url ?? "")
      }
      let runtime = try await webRuntime(requiresSearchProvider: false)
      let result = try await runtime.fetch(WebFetchRequest(
        url: request.url ?? "",
        // The persistent source receipt store validates sourceID at the bridge
        // boundary. The HTTP runtime then independently re-validates each URL
        // and redirect before opening a network connection.
        sourceID: nil,
        maxCharacters: request.maxCharacters ?? 100_000
      ))
      return KimiNativeBridgeResponse(
        requestID: request.requestID,
        ok: true,
        output: result.content,
        metadata: [
          "url": result.url,
          "title": result.title,
          "contentType": result.contentType,
          "status": String(result.statusCode),
          "truncated": result.truncated ? "true" : "false",
          "elapsedMS": String(result.elapsedMilliseconds)
        ]
      )
    case .browserVerify:
      guard let plan = request.browserPlan else { throw KimiNativeBridgeValidationError.missingBrowserPlan }
      if plan.steps.contains(where: requiresHighRiskApproval) { try requireApproval() }
      let directory = try artifactsDirectory(request)
      let controller = await MainActor.run { () -> BrowserVerificationController in
        _ = NSApplication.shared
        return BrowserVerificationController()
      }
      let result = await controller.run(plan: plan, artifactsDirectory: directory)
      return KimiNativeBridgeResponse(
        requestID: request.requestID,
        ok: result.passed,
        output: result.passed ? "浏览器验证通过。" : "浏览器验证未通过：\(result.repairSummary)",
        metadata: [
          "artifactCount": String(result.artifacts.count),
          "artifactsDirectory": directory.path,
          "currentURL": result.currentURL?.absoluteString ?? ""
        ],
        browserResult: result,
        error: result.passed ? nil : result.repairSummary
      )
    case .computerInspect:
      let diagnostics = ComputerUseController.diagnostics()
      return KimiNativeBridgeResponse(
        requestID: request.requestID,
        ok: true,
        output: diagnostics.message,
        metadata: ["ready": diagnostics.isReady ? "true" : "false", "adapter": "computer-use"]
      )
    case .computerScreenshot, .computerClick, .computerTypeText, .computerPressKey:
      try requireApproval()
      let result = try await ComputerUseController.executeHarnessRequest(toolRequest(for: request))
      return KimiNativeBridgeResponse(requestID: request.requestID, ok: true, output: result.output, metadata: result.metadata)
    }
  }

  private static func webRuntime(requiresSearchProvider: Bool) async throws -> WebRuntime {
    let runtime = WebRuntime(
      searchPriority: requiresSearchProvider ? ["kimi_official"] : [],
      fetchPriority: ["http"]
    )
    try await runtime.register(fetch: HTTPWebFetchProvider())
    guard requiresSearchProvider else { return runtime }

    let provider = KimiOfficialWebProvider(
      apiKey: try kimiAPIKey(),
      baseURL: try kimiBaseURL(),
      modelID: kimiModelID()
    )
    try await runtime.register(search: provider)
    return runtime
  }

  private static func kimiAPIKey() throws -> String {
    if let environmentValue = ProcessInfo.processInfo.environment["KIMI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !environmentValue.isEmpty {
      return environmentValue
    }

    for service in KimiCodeAgentBranding.keychainServices {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "kimi.runtime.identity.apiKey",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
      ]
      var item: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &item)
      if status == errSecSuccess,
         let data = item as? Data,
         let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !value.isEmpty {
        return value
      }
    }
    throw WebRuntimeError.unavailable("Kimi API Key 未配置。请在连接设置中保存 API Key。")
  }

  private static func kimiBaseURL() throws -> URL {
    let raw = ProcessInfo.processInfo.environment["KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL"]
      ?? ProcessInfo.processInfo.environment["KIMI_BASE_URL"]
      ?? KimiRuntimeIdentityStore.defaultBaseURL
    guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          ["api.kimi.com", "api.moonshot.ai", "api.moonshot.cn", "api.moonshotai.cn"].contains(host),
          url.user == nil,
          url.password == nil,
          url.query == nil,
          url.fragment == nil else {
      throw WebRuntimeError.unavailable("Kimi 官方联网地址无效。")
    }
    return url
  }

  private static func kimiModelID() -> String {
    let value = ProcessInfo.processInfo.environment["KIMI_AGENT_OFFICIAL_TOOLS_MODEL"]
      ?? ProcessInfo.processInfo.environment["KIMI_MODEL"]
      ?? KimiRuntimeIdentityStore.defaultModelID
    return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? KimiRuntimeIdentityStore.defaultModelID
      : value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func webSourceStore() -> WebSourceReceiptStore {
    let directory = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
      .flatMap { value in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("Kimi Code Agent", isDirectory: true)
        .appendingPathComponent("engine-state", isDirectory: true)
    return WebSourceReceiptStore(directory: directory.appendingPathComponent("native-web", isDirectory: true))
  }

  private static func requiresHighRiskApproval(_ step: BrowserVerificationStep) -> Bool {
    if step.requiresApproval { return true }
    return switch step.kind {
    case .click, .typeText, .pressKey: true
    case .open, .navigate, .inspect, .scroll, .screenshot, .collectConsole, .collectNetwork: false
    }
  }

  private static func requireApproval() throws {
    guard ProcessInfo.processInfo.environment["KIMI_NATIVE_BRIDGE_APPROVED"] == "1" else {
      throw NSError(domain: "KimiNativeBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "高风险原生操作尚未经过审批。"])
    }
  }

  private static func artifactsDirectory(_ request: KimiNativeBridgeRequest) throws -> URL {
    let directory = request.artifactsDirectory
      .flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("Kimi Code Agent", isDirectory: true)
        .appendingPathComponent("engine-artifacts", isDirectory: true)
        .appendingPathComponent(request.requestID, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
  }

  private static func toolRequest(for request: KimiNativeBridgeRequest) -> ToolExecutionRequest {
    let toolID: String
    var input: [String: String] = [:]
    switch request.operation {
    case .webSearch, .webFetch:
      fatalError("Web operations do not convert to Computer Use requests")
    case .computerScreenshot:
      toolID = "computer_use.screenshot"
    case .computerClick:
      toolID = "computer_use.click"
      input["x"] = request.x.map { String($0) } ?? ""
      input["y"] = request.y.map { String($0) } ?? ""
    case .computerTypeText:
      toolID = "computer_use.type_text"
      input["text"] = request.text ?? ""
    case .computerPressKey:
      toolID = "computer_use.press_key"
      input["key"] = request.key ?? ""
    case .browserVerify, .computerInspect:
      fatalError("Unsupported native tool conversion")
    }
    return ToolExecutionRequest(taskID: UUID(), sessionID: UUID(), agentID: "kimi-native-bridge", toolID: toolID, input: input)
  }

  private static func emit(_ response: KimiNativeBridgeResponse) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(response)) ?? Data("{\"ok\":false,\"error\":\"编码失败\"}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
