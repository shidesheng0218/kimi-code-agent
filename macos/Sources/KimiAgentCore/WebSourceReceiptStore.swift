import Foundation

/// Persists the source-to-URL relationship across one-shot native bridge
/// processes. The runtime session owns the actual Tool receipt; this small
/// local cache only prevents a later `web.fetch` call from substituting a
/// different URL for a source ID returned by `web.search`.
public final class WebSourceReceiptStore: @unchecked Sendable {
  private struct StoredSource: Codable {
    let source: WebSource
    let expiresAt: Date
  }

  private let directory: URL
  private let sourceTTL: TimeInterval
  private let fileManager: FileManager
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let lock = NSLock()

  public init(
    directory: URL,
    sourceTTL: TimeInterval = 600,
    fileManager: FileManager = .default
  ) {
    self.directory = directory.standardizedFileURL
    self.sourceTTL = min(max(sourceTTL, 60), 3_600)
    self.fileManager = fileManager
    encoder.outputFormatting = [.sortedKeys]
  }

  public func record(_ sources: [WebSource]) throws {
    lock.lock()
    defer { lock.unlock() }
    var entries = try load().filter { $0.value.expiresAt > .now }
    let expiresAt = Date().addingTimeInterval(sourceTTL)
    for source in sources {
      _ = try WebFetchPolicy.validate(url: source.url)
      entries[source.id] = StoredSource(source: source, expiresAt: expiresAt)
    }
    try save(entries)
  }

  public func validate(sourceID: String, url: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let stored = try load()[sourceID] else {
      throw WebRuntimeError.providerFailure("Web 来源不存在或已过期，请先重新搜索")
    }
    guard stored.expiresAt > .now else {
      throw WebRuntimeError.providerFailure("Web 来源已过期，请先重新搜索")
    }
    guard stored.source.url == url else {
      throw WebRuntimeError.providerFailure("sourceID 与 URL 不匹配")
    }
  }

  private var fileURL: URL {
    directory.appendingPathComponent("web-source-receipts.json", isDirectory: false)
  }

  private func load() throws -> [String: StoredSource] {
    guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return [:] }
    return try decoder.decode([String: StoredSource].self, from: data)
  }

  private func save(_ entries: [String: StoredSource]) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let temporaryURL = directory.appendingPathComponent(".web-source-receipts-\(UUID().uuidString).tmp")
    let data = try encoder.encode(entries)
    guard fileManager.createFile(atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
      throw WebRuntimeError.providerFailure("无法保存 Web 来源回执")
    }
    defer { try? fileManager.removeItem(at: temporaryURL) }
    if fileManager.fileExists(atPath: fileURL.path) {
      _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: fileURL)
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}
