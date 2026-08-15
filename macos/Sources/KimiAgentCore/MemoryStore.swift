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
  /// Stable semantic subject used for scope precedence and conflict audits.
  public let key: String?
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
    expiresAt: Date? = nil, isEnabled: Bool = true, key: String? = nil
  ) {
    self.id = id
    self.scope = scope
    self.scopeKey = scopeKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.key = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.kind = kind
    self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    self.provenance = provenance
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.expiresAt = expiresAt
    self.isEnabled = isEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case id, scope, scopeKey, key, kind, content, provenance, createdAt, updatedAt, expiresAt, isEnabled
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
      isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
      key: try container.decodeIfPresent(String.self, forKey: .key)
    )
  }
}

public struct MemoryConflict: Equatable, Sendable, Identifiable {
  public let key: String
  public let records: [MemoryRecord]

  public var id: String { key }

  public init(key: String, records: [MemoryRecord]) {
    self.key = key
    self.records = records
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

  /// Projects a scoped, conflict-aware memory view for model context. The
  /// most specific scope wins for a shared key, while unkeyed records remain
  /// visible. Derived memory is never converted into an authorization rule.
  public func effectiveRecords(projectKey: String? = nil, taskKey: String? = nil, at date: Date = .now) -> [MemoryRecord] {
    let candidates = matchingRecords(projectKey: projectKey, taskKey: taskKey, at: date)
      .sorted { lhs, rhs in
        let lhsScope = scopePriority(lhs.scope)
        let rhsScope = scopePriority(rhs.scope)
        if lhsScope != rhsScope { return lhsScope > rhsScope }
        let lhsProvenance = provenancePriority(lhs.provenance)
        let rhsProvenance = provenancePriority(rhs.provenance)
        if lhsProvenance != rhsProvenance { return lhsProvenance > rhsProvenance }
        return lhs.updatedAt > rhs.updatedAt
      }
    var seenKeys = Set<String>()
    return candidates.filter { record in
      guard let key = record.key?.lowercased(), !key.isEmpty else { return true }
      return seenKeys.insert(key).inserted
    }
  }

  public func conflicts(projectKey: String? = nil, taskKey: String? = nil, at date: Date = .now) -> [MemoryConflict] {
    let grouped = Dictionary(grouping: matchingRecords(projectKey: projectKey, taskKey: taskKey, at: date).compactMap { record -> (String, MemoryRecord)? in
      guard let key = record.key?.lowercased(), !key.isEmpty else { return nil }
      return (key, record)
    }, by: \.0)
    return grouped.compactMap { key, values in
      let records = values.map(\.1).sorted { scopePriority($0.scope) > scopePriority($1.scope) }
      let contents = Set(records.map { $0.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
      return contents.count > 1 ? MemoryConflict(key: key, records: records) : nil
    }.sorted { $0.key < $1.key }
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

  private func matchingRecords(projectKey: String?, taskKey: String?, at date: Date) -> [MemoryRecord] {
    let project = projectKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let task = taskKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    lock.lock()
    defer { lock.unlock() }
    return values.filter { record in
      guard record.isEnabled, (record.expiresAt == nil || record.expiresAt! > date) else { return false }
      switch record.scope {
      case .user:
        return true
      case .project:
        return project != nil && record.scopeKey == project
      case .task:
        return task != nil && record.scopeKey == task
      }
    }
  }

  private func scopePriority(_ scope: MemoryScope) -> Int {
    switch scope {
    case .user: 1
    case .project: 2
    case .task: 3
    }
  }

  private func provenancePriority(_ provenance: MemoryProvenance) -> Int {
    switch provenance {
    case .sessionDerived: 1
    case .projectRule: 2
    case .userConfirmed: 3
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
