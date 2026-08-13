import Foundation

public enum IntegrationProvider: String, Codable, CaseIterable, Sendable, Identifiable {
  case github
  case gitlab

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    }
  }

  public var environmentKey: String {
    switch self {
    case .github: "KIMI_GITHUB_TOKEN"
    case .gitlab: "KIMI_GITLAB_TOKEN"
    }
  }

  public var defaultHost: String {
    switch self {
    case .github: "github.com"
    case .gitlab: "gitlab.com"
    }
  }
}

public struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
  public let provider: IntegrationProvider
  public var accountName: String
  public var defaultRepository: String?
  public var connectedAt: Date?
  public var lastSyncedAt: Date?
  public var tokenStatus: String
  public var isConnected: Bool

  public var id: String { provider.rawValue }

  public init(
    provider: IntegrationProvider,
    accountName: String = "",
    defaultRepository: String? = nil,
    connectedAt: Date? = nil,
    lastSyncedAt: Date? = nil,
    tokenStatus: String = "missing",
    isConnected: Bool = false
  ) {
    self.provider = provider
    self.accountName = accountName
    self.defaultRepository = defaultRepository
    self.connectedAt = connectedAt
    self.lastSyncedAt = lastSyncedAt
    self.tokenStatus = tokenStatus
    self.isConnected = isConnected
  }
}

public protocol CredentialVault: AnyObject, Sendable {
  func read(key: String) throws -> String?
  func write(_ value: String, key: String) throws
  func delete(key: String) throws
}

public final class InMemoryCredentialVault: CredentialVault, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]

  public init() {}

  public func read(key: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  public func write(_ value: String, key: String) throws {
    lock.lock()
    values[key] = value
    lock.unlock()
  }

  public func delete(key: String) throws {
    lock.lock()
    values.removeValue(forKey: key)
    lock.unlock()
  }
}

public final class IntegrationAccountStore: @unchecked Sendable {
  private let vault: CredentialVault
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(vault: CredentialVault) {
    self.vault = vault
    encoder.outputFormatting = [.sortedKeys]
  }

  public func connect(
    provider: IntegrationProvider,
    accountName: String,
    credential: String,
    defaultRepository: String? = nil
  ) throws {
    let trimmedCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCredential.isEmpty else {
      throw NSError(domain: "IntegrationAccountStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "凭据不能为空。"])
    }
    try vault.write(trimmedCredential, key: credentialKey(for: provider))
    let record = AccountRecord(
      provider: provider,
      accountName: accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.title : accountName,
      defaultRepository: defaultRepository?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      connectedAt: .now,
      lastSyncedAt: .now,
      tokenStatus: "valid",
      isConnected: true
    )
    try writeRecord(record)
  }

  public func disconnect(provider: IntegrationProvider) throws {
    let previous = try account(for: provider)
    try vault.delete(key: credentialKey(for: provider))
    try writeRecord(AccountRecord(
      provider: provider,
      accountName: previous?.accountName ?? "",
      defaultRepository: previous?.defaultRepository,
      connectedAt: previous?.connectedAt,
      lastSyncedAt: previous?.lastSyncedAt,
      tokenStatus: "missing",
      isConnected: false
    ))
  }

  public func account(for provider: IntegrationProvider) throws -> AccountRecord? {
    guard let data = try vault.read(key: metadataKey(for: provider))?.data(using: .utf8) else {
      return AccountRecord(provider: provider)
    }
    return try decoder.decode(AccountRecord.self, from: data)
  }

  public func accounts() throws -> [AccountRecord] {
    try IntegrationProvider.allCases.compactMap { try account(for: $0) }
  }

  public func credential(for provider: IntegrationProvider) throws -> String? {
    try vault.read(key: credentialKey(for: provider))
  }

  public func runtimeEnvironment() throws -> [String: String] {
    var environment: [String: String] = [:]
    for provider in IntegrationProvider.allCases {
      if let token = try credential(for: provider), !token.isEmpty {
        environment[provider.environmentKey] = token
      }
    }
    return environment
  }

  private func writeRecord(_ record: AccountRecord) throws {
    let data = try encoder.encode(record)
    try vault.write(String(data: data, encoding: .utf8) ?? "{}", key: metadataKey(for: record.provider))
  }

  private func metadataKey(for provider: IntegrationProvider) -> String {
    "integration.\(provider.rawValue).metadata"
  }

  private func credentialKey(for provider: IntegrationProvider) -> String {
    "integration.\(provider.rawValue).token"
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
