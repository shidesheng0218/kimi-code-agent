import Foundation

public enum DiffDecision: String, Codable, Sendable {
  case accepted
  case rejected
}

public struct DiffComment: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let filePath: String
  public let line: Int
  public let text: String
  public let createdAt: Date

  public init(id: UUID = UUID(), filePath: String, line: Int, text: String, createdAt: Date = .now) {
    self.id = id
    self.filePath = filePath
    self.line = line
    self.text = text
    self.createdAt = createdAt
  }
}

public struct DiffReviewState: Codable, Equatable, Sendable {
  public var fileDecisions: [String: DiffDecision]
  public var hunkDecisions: [String: DiffDecision]
  public var comments: [DiffComment]

  public init(fileDecisions: [String: DiffDecision] = [:], hunkDecisions: [String: DiffDecision] = [:], comments: [DiffComment] = []) {
    self.fileDecisions = fileDecisions
    self.hunkDecisions = hunkDecisions
    self.comments = comments
  }

  public mutating func acceptFile(_ path: String) {
    fileDecisions[path] = .accepted
  }

  public mutating func rejectFile(_ path: String) {
    fileDecisions[path] = .rejected
  }

  public mutating func acceptHunk(_ id: String) {
    hunkDecisions[id] = .accepted
  }

  public mutating func rejectHunk(_ id: String) {
    hunkDecisions[id] = .rejected
  }

  public mutating func addComment(_ comment: DiffComment) {
    comments.append(comment)
  }
}
