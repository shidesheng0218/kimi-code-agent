import Foundation

public enum MemoryScope: String, Codable, CaseIterable, Sendable {
  case user
  case project
  case task
}

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
  case fact
  case preference
  case failure
  case summary
}

public enum MemoryProvenance: String, Codable, CaseIterable, Sendable {
  case userConfirmed
  case projectRule
  case sessionDerived
}

public struct MemoryRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let scope: MemoryScope
  /// Project and task memories are isolated by this stable local key. User
  /// memories deliberately leave it nil and can be projected everywhere.
  public let scopeKey: String?
  public let kind: MemoryKind
  public var content: String
  public let provenance: MemoryProvenance
  public let createdAt: Date
  public var updatedAt: Date
  public var expiresAt: Date?
  public var isEnabled: Bool

  public init(
    id: UUID = UUID(), scope: MemoryScope, scopeKey: String? = nil, kind: MemoryKind, content: String,
    provenance: MemoryProvenance, createdAt: Date = .now, updatedAt: Date = .now,
    expiresAt: Date? = nil, isEnabled: Bool = true
  ) {
    self.id = id
    self.scope = scope
    self.scopeKey = scopeKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.kind = kind
    self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    self.provenance = provenance
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.expiresAt = expiresAt
    self.isEnabled = isEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case id, scope, scopeKey, kind, content, provenance, createdAt, updatedAt, expiresAt, isEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      scope: try container.decode(MemoryScope.self, forKey: .scope),
      scopeKey: try container.decodeIfPresent(String.self, forKey: .scopeKey),
      kind: try container.decode(MemoryKind.self, forKey: .kind),
      content: try container.decode(String.self, forKey: .content),
      provenance: try container.decode(MemoryProvenance.self, forKey: .provenance),
      createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now,
      updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now,
      expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
      isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    )
  }
}

public final class MemoryStore: @unchecked Sendable {
  private let lock = NSLock()
  private let fileURL: URL
  private var values: [MemoryRecord]

  public init(fileURL: URL) {
    self.fileURL = fileURL
    values = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([MemoryRecord].self, from: $0) } ?? []
  }

  public func upsert(_ record: MemoryRecord) throws {
    guard !record.content.isEmpty else { return }
    lock.lock()
    if let index = values.firstIndex(where: { $0.id == record.id }) {
      values[index] = record
    } else {
      values.append(record)
    }
    let snapshot = values
    lock.unlock()
    try persist(snapshot)
  }

  public func records(scope: MemoryScope? = nil, scopeKey: String? = nil, at date: Date = .now) -> [MemoryRecord] {
    let normalizedScopeKey = scopeKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    lock.lock()
    defer { lock.unlock() }
    return values.filter { record in
      record.isEnabled &&
      (scope == nil || record.scope == scope) &&
      (normalizedScopeKey == nil || record.scopeKey == normalizedScopeKey) &&
      (record.expiresAt == nil || record.expiresAt! > date)
    }.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func setEnabled(id: UUID, enabled: Bool) throws {
    lock.lock()
    guard let index = values.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
    values[index].isEnabled = enabled
    values[index].updatedAt = .now
    let snapshot = values
    lock.unlock()
    try persist(snapshot)
  }

  public func delete(id: UUID) throws {
    lock.lock()
    values.removeAll { $0.id == id }
    let snapshot = values
    lock.unlock()
    try persist(snapshot)
  }

  private func persist(_ snapshot: [MemoryRecord]) throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
