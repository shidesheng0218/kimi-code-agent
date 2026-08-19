import Foundation

public enum KimiHeadlessRuntimeFactory {
  public static func makeConfiguration(
    resourcesDirectory: URL,
    applicationSupportDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> KimiRuntimeConfiguration? {
    let nativeRuntimeBinaryURL = configuredRuntimeURL(
      environment["KIMI_RUNTIME_BINARY"],
      fallback: resourcesDirectory.appendingPathComponent("runtime/kimi-agent")
    )
    let bunURL = configuredRuntimeURL(
      environment["KIMI_BUN_PATH"],
      fallback: resourcesDirectory.appendingPathComponent("runtime/bun")
    ) ?? ManagedRuntimeLocator.bunPath(environment: environment).map(URL.init(fileURLWithPath:))
    guard nativeRuntimeBinaryURL != nil || bunURL != nil else { return nil }

    let engineRoot = URL(fileURLWithPath: environment["KIMI_RUNTIME_ROOT"] ?? resourcesDirectory.appendingPathComponent("engine", isDirectory: true).path, isDirectory: true)
    let entrypoint = URL(fileURLWithPath: environment["KIMI_RUNTIME_ENTRY"] ?? engineRoot.appendingPathComponent("src/index.ts").path)
    if nativeRuntimeBinaryURL == nil && !(fileManager.fileExists(atPath: entrypoint.path) || environment["KIMI_RUNTIME_ENTRY"] != nil) {
      return nil
    }

    let port = Int(environment["KIMI_RUNTIME_PORT"] ?? "") ?? Int.random(in: 20_000...45_000)
    let configuredToken = environment["KIMI_RUNTIME_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let token = configuredToken.isEmpty ? UUID().uuidString : configuredToken
    let endpoint = KimiRuntimeEndpoint(port: port, token: token)
    // Contain every engine-writable location inside the app's own sandbox
    // directory so nothing leaks into ~/.config, ~/.local, or other shared
    // XDG paths.
    let runtimeHome = applicationSupportDirectory.appendingPathComponent("runtime", isDirectory: true)
    let dataHome = runtimeHome.appendingPathComponent("data", isDirectory: true)
    let configHome = runtimeHome.appendingPathComponent("config", isDirectory: true)
    let stateHome = runtimeHome.appendingPathComponent("state", isDirectory: true)
    let pluginPath = environment["KIMI_RUNTIME_PLUGIN"] ?? resourcesDirectory.appendingPathComponent("kimi-native-plugin.mjs").path
    // OPENCODE_CONFIG_CONTENT is a virtual config source. The engine resolves
    // path plugins relative to a config file only when it sees a file URL;
    // passing an absolute filesystem path here makes the loader treat the
    // .mjs file as a directory and silently drops the plugin. Keep the
    // process environment explicit while emitting the canonical file URL.
    let plugin = filePluginSpec(pluginPath)
    let bridge = environment["KIMI_NATIVE_BRIDGE"] ?? resourcesDirectory.appendingPathComponent("native/KimiNativeBridge").path
    let modelID = environment["KIMI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? environment["KIMI_MODEL"]!
      : KimiRuntimeIdentityStore.defaultModelID
    let baseURL = environment["KIMI_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? environment["KIMI_BASE_URL"]!
      : KimiRuntimeIdentityStore.defaultBaseURL
    let apiKey = environment["KIMI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (try? MacKeychainCredentialVault().read(key: "kimi.runtime.identity.apiKey")) ?? ""
    let commandArguments: [String]
    let executableURL: URL
    if let nativeRuntimeBinaryURL {
      executableURL = nativeRuntimeBinaryURL
      commandArguments = ["serve", "--hostname", endpoint.host, "--port", String(endpoint.port)]
    } else {
      executableURL = bunURL!
      commandArguments = ["run", "--conditions=browser", entrypoint.path, "serve", "--hostname", endpoint.host, "--port", String(endpoint.port)]
    }
    var runtimeEnvironment: [String: String] = [
      "OPENCODE_SERVER_PASSWORD": token,
      "OPENCODE_SERVER_USERNAME": "kimi",
      "OPENCODE_CLIENT": "kimi-code-agent",
      "XDG_DATA_HOME": dataHome.path,
      "XDG_CONFIG_HOME": configHome.path,
      "XDG_STATE_HOME": stateHome.path,
      "KIMI_RUNTIME_PLUGIN": plugin,
      "KIMI_NATIVE_BRIDGE": bridge,
      "KIMI_APPLICATION_SUPPORT_DIR": applicationSupportDirectory.path
    ]
    if !apiKey.isEmpty { runtimeEnvironment["KIMI_API_KEY"] = apiKey }
    let config: [String: Any] = [
      "model": "moonshotai-cn/\(modelID)",
      "small_model": "moonshotai-cn/\(modelID)",
      "plugin": ["{env:KIMI_RUNTIME_PLUGIN}"],
      "provider": [
        "moonshotai-cn": [
          "name": "Kimi / Moonshot AI",
          "api": baseURL,
          "npm": "@ai-sdk/openai-compatible",
          "env": ["KIMI_API_KEY"],
          "options": ["apiKey": "{env:KIMI_API_KEY}", "baseURL": baseURL, "timeout": 120000, "headerTimeout": 15000, "chunkTimeout": 30000, "setCacheKey": true],
          "models": [modelID: ["name": modelID, "reasoning": true, "tool_call": true, "interleaved": "reasoning_content", "limit": ["context": 262144, "output": 16384], "modalities": ["input": ["text", "image"], "output": ["text"]]]]
        ]
      ],
      "permission": ["read": "allow", "glob": "allow", "grep": "allow", "list": "allow", "websearch": "allow", "webfetch": "allow", "task": "allow", "bash": "ask", "edit": "ask", "external_directory": "ask", "question": "ask", "skill": "ask"],
      "compaction": ["auto": true, "prune": true, "tail_turns": 8, "preserve_recent_tokens": 24000],
      "tool_output": ["max_lines": 2000, "max_bytes": 51200]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
      runtimeEnvironment["OPENCODE_CONFIG_CONTENT"] = text
    }

    return KimiRuntimeConfiguration(
      executableURL: executableURL,
      arguments: commandArguments,
      // A packaged app ships only the standalone engine binary, not the
      // engine source tree, so engineRoot may not exist. Spawning a process
      // with a missing working directory throws before exec; fall back to the
      // always-present, contained Application Support directory instead.
      workingDirectory: fileManager.fileExists(atPath: engineRoot.path) ? engineRoot : applicationSupportDirectory,
      environment: runtimeEnvironment,
      endpoint: endpoint
    )
  }

  private static func configuredRuntimeURL(_ raw: String?, fallback: URL) -> URL? {
    if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let url = URL(fileURLWithPath: raw)
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
  }

  private static func filePluginSpec(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("file://") { return value }
    return URL(fileURLWithPath: value).absoluteString
  }
}
