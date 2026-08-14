import Foundation

public enum WebSearchProvider: String, Codable, CaseIterable, Sendable, Identifiable {
  case kimiOfficial
  case brave
  case searxng

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .kimiOfficial: "Kimi 官方联网（推荐）"
    case .brave: "Brave Search"
    case .searxng: "SearxNG（自托管）"
    }
  }

  public var requiresAPIKey: Bool {
    self == .brave
  }

  public var usesKimiAPIKey: Bool {
    self == .kimiOfficial
  }

  public var runtimeIdentifier: String {
    switch self {
    case .kimiOfficial: "kimi_official"
    case .brave, .searxng: rawValue
    }
  }
}

public struct WebResearchSettingsRecord: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var provider: WebSearchProvider
  public var endpoint: String
  public var apiKeyStatus: String
  public var allowedDomains: [String]
  public var defaultResultLimit: Int
  public var updatedAt: Date?

  public init(
    isEnabled: Bool = true,
    provider: WebSearchProvider = .kimiOfficial,
    endpoint: String = WebResearchSettingsStore.defaultKimiOfficialEndpoint,
    apiKeyStatus: String = "usesKimiAPI",
    allowedDomains: [String] = [],
    defaultResultLimit: Int = 5,
    updatedAt: Date? = nil
  ) {
    self.isEnabled = isEnabled
    self.provider = provider
    self.endpoint = endpoint
    self.apiKeyStatus = apiKeyStatus
    self.allowedDomains = allowedDomains
    self.defaultResultLimit = min(max(defaultResultLimit, 1), 10)
    self.updatedAt = updatedAt
  }

  public var isReady: Bool {
    isEnabled && (!provider.requiresAPIKey || apiKeyStatus == "configured")
  }
}

public final class WebResearchSettingsStore: @unchecked Sendable {
  public static let defaultKimiOfficialEndpoint = "https://api.moonshot.cn/v1"
  public static let defaultBraveEndpoint = "https://api.search.brave.com/res/v1/web/search"

  private let vault: CredentialVault
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(vault: CredentialVault) {
    self.vault = vault
    encoder.outputFormatting = [.sortedKeys]
  }

  public func record() throws -> WebResearchSettingsRecord {
    var record = try loadRecord() ?? WebResearchSettingsRecord()
    if record.provider.usesKimiAPIKey {
      record.apiKeyStatus = "usesKimiAPI"
    } else if record.provider.requiresAPIKey {
      record.apiKeyStatus = (try apiKey()) == nil ? "missing" : "configured"
    } else {
      record.apiKeyStatus = "notRequired"
    }
    record.defaultResultLimit = min(max(record.defaultResultLimit, 1), 10)
    record.allowedDomains = normalizeDomains(record.allowedDomains)
    return record
  }

  public func save(
    provider: WebSearchProvider,
    apiKey: String,
    endpoint: String,
    allowedDomains: [String],
    defaultResultLimit: Int
  ) throws {
    let normalizedEndpoint = try normalizeEndpoint(endpoint, provider: provider)
    let normalizedDomains = normalizeDomains(allowedDomains)
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

    let apiKeyStatus: String
    if provider.usesKimiAPIKey {
      apiKeyStatus = "usesKimiAPI"
    } else if provider.requiresAPIKey {
      let keyToStore = trimmedKey.isEmpty ? try self.apiKey() : trimmedKey
      guard let keyToStore, !keyToStore.isEmpty else {
        throw NSError(domain: "WebResearchSettingsStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Brave Search API Key 不能为空。"])
      }
      if !trimmedKey.isEmpty {
        try vault.write(keyToStore, key: apiKeyKey)
      }
      apiKeyStatus = "configured"
    } else {
      apiKeyStatus = "notRequired"
    }

    try writeRecord(WebResearchSettingsRecord(
      isEnabled: true,
      provider: provider,
      endpoint: normalizedEndpoint,
      apiKeyStatus: apiKeyStatus,
      allowedDomains: normalizedDomains,
      defaultResultLimit: defaultResultLimit,
      updatedAt: .now
    ))
  }

  public func disconnect() throws {
    var record = try record()
    if record.provider.requiresAPIKey {
      try vault.delete(key: apiKeyKey)
    }
    record.isEnabled = false
    record.apiKeyStatus = record.provider.usesKimiAPIKey ? "usesKimiAPI" : record.provider.requiresAPIKey ? "missing" : "notRequired"
    record.updatedAt = .now
    try writeRecord(record)
  }

  public func apiKey() throws -> String? {
    let value = try vault.read(key: apiKeyKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  public func runtimeEnvironment() throws -> [String: String] {
    let record = try self.record()
    guard record.isEnabled else { return [:] }
    guard record.isReady else {
      throw NSError(domain: "WebResearchSettingsStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "Web Search 已启用，但搜索服务尚未配置完成。"])
    }

    var environment = [
      "KIMI_AGENT_WEB_SEARCH_PROVIDER": record.provider.runtimeIdentifier,
      "KIMI_AGENT_WEB_SEARCH_ENDPOINT": record.endpoint,
      "KIMI_AGENT_WEB_SEARCH_DEFAULT_RESULTS": String(record.defaultResultLimit)
    ]
    if record.provider.usesKimiAPIKey {
      environment["KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL"] = record.endpoint
    }
    if record.provider.requiresAPIKey, let apiKey = try apiKey() {
      environment["KIMI_AGENT_WEB_SEARCH_API_KEY"] = apiKey
    }
    return environment
  }

  private func loadRecord() throws -> WebResearchSettingsRecord? {
    guard let text = try vault.read(key: metadataKey), let data = text.data(using: .utf8) else {
      return nil
    }
    return try decoder.decode(WebResearchSettingsRecord.self, from: data)
  }

  private func writeRecord(_ record: WebResearchSettingsRecord) throws {
    let data = try encoder.encode(record)
    try vault.write(String(data: data, encoding: .utf8) ?? "{}", key: metadataKey)
  }

  private func normalizeEndpoint(_ endpoint: String, provider: WebSearchProvider) throws -> String {
    let fallback: String
    switch provider {
    case .kimiOfficial: fallback = Self.defaultKimiOfficialEndpoint
    case .brave: fallback = Self.defaultBraveEndpoint
    case .searxng: fallback = ""
    }
    let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = trimmed.isEmpty ? fallback : trimmed
    guard let url = URL(string: candidate),
          let scheme = url.scheme?.lowercased(),
          (scheme == "https" || (scheme == "http" && provider != .kimiOfficial)),
          url.host(percentEncoded: false) != nil else {
      throw NSError(
        domain: "WebResearchSettingsStore",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: provider == .kimiOfficial
          ? "Kimi 官方联网地址必须是 HTTPS URL，避免 API Key 明文传输。"
          : "搜索服务地址必须是合法的 HTTP(S) URL。"]
      )
    }
    return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private func normalizeDomains(_ domains: [String]) -> [String] {
    Array(Set(domains.compactMap { rawDomain in
      let value = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !value.isEmpty, !value.contains("/"), !value.contains(":"), !value.contains("@") else {
        return nil
      }
      return value
    })).sorted()
  }

  private var metadataKey: String {
    "web.research.settings.metadata"
  }

  private var apiKeyKey: String {
    "web.research.settings.apiKey"
  }
}
