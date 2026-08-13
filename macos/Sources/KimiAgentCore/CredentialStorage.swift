import Foundation

public enum CredentialStorageMode: String, Codable, CaseIterable, Sendable {
  case keychain
  case localFile
}

public enum CredentialStoragePolicy {
  public static func defaultMode(
    environment: [String: String],
    hasStableSigningIdentity: Bool
  ) -> CredentialStorageMode {
    switch environment["KIMI_CREDENTIAL_STORAGE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "keychain":
      return .keychain
    case "file", "local", "local-file":
      return .localFile
    default:
      return hasStableSigningIdentity ? .keychain : .localFile
    }
  }
}

public final class FileCredentialVault: CredentialVault, @unchecked Sendable {
  private let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
    encoder.outputFormatting = [.sortedKeys]
  }

  public func read(key: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return try loadValues()[key]
  }

  public func write(_ value: String, key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var values = try loadValues()
    values[key] = value
    try save(values)
  }

  public func delete(key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    var values = try loadValues()
    values.removeValue(forKey: key)
    try save(values)
  }

  private func loadValues() throws -> [String: String] {
    guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [:] }
    return try decoder.decode([String: String].self, from: data)
  }

  private func save(_ values: [String: String]) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let data = try encoder.encode(values)
    // Create the temporary file with 0600 before the atomic rename so the
    // secret never exists with umask-default (world-readable) permissions.
    let temporaryURL = directory.appendingPathComponent(".credentials.tmp-\(UUID().uuidString)")
    guard fileManager.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw NSError(domain: "FileCredentialVault", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法写入凭据文件。"])
    }
    defer { try? fileManager.removeItem(at: temporaryURL) }
    _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}
