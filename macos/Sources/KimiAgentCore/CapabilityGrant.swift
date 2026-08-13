import Foundation

public enum CapabilityAction: String, Codable, CaseIterable, Sendable {
  case read
  case search
  case write
  case execute
  case network
  case browser
  case computerUse
  case destructive
}

public enum CapabilityGrantScope: String, Codable, CaseIterable, Sendable {
  case once
  case task
  case project
  case session
  case permanent
}

public struct CapabilityGrant: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let subjectID: UUID
  public let resource: String
  public let actions: [CapabilityAction]
  public let scope: CapabilityGrantScope
  public let expiresAt: Date?
  public let grantedAt: Date

  public init(
    id: UUID = UUID(),
    subjectID: UUID,
    resource: String,
    actions: [CapabilityAction],
    scope: CapabilityGrantScope,
    expiresAt: Date? = nil,
    grantedAt: Date = .now
  ) {
    self.id = id
    self.subjectID = subjectID
    self.resource = URL(fileURLWithPath: resource).standardizedFileURL.path
    self.actions = actions
    self.scope = scope
    self.expiresAt = expiresAt
    self.grantedAt = grantedAt
  }

  public func allows(action: CapabilityAction, resource candidate: String, subjectID: UUID, now: Date = .now) -> Bool {
    guard self.subjectID == subjectID,
          actions.contains(action),
          expiresAt.map({ $0 > now }) ?? true else { return false }
    let root = resource.hasSuffix("/") ? resource : resource + "/"
    let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
    return path == resource || path.hasPrefix(root)
  }
}
