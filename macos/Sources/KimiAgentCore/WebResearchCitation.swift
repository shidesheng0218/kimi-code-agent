import Foundation

public enum WebResearchCitationStatus: String, Codable, CaseIterable, Sendable {
  case notApplicable
  case pending
  case verified
  case needsReview
}

public struct WebResearchCitationCheck: Equatable, Sendable {
  public let isValid: Bool
  public let matchedSourceCount: Int
  public let unmatchedURLs: [String]
  public let requiresReview: Bool

  public init(isValid: Bool, matchedSourceCount: Int, unmatchedURLs: [String], requiresReview: Bool) {
    self.isValid = isValid
    self.matchedSourceCount = matchedSourceCount
    self.unmatchedURLs = unmatchedURLs
    self.requiresReview = requiresReview
  }
}

public enum WebResearchCitationVerifier {
  public static func answerText(from events: [AgentEvent]) -> String {
    events
      .filter { event in
        event.kind == .output &&
          event.payload["contentType"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "thinking"
      }
      .compactMap { $0.payload["text"] }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined()
  }

  public static func validate(answer: String, sources: [WebResearchSource]) -> WebResearchCitationCheck {
    guard !sources.isEmpty else {
      return WebResearchCitationCheck(isValid: true, matchedSourceCount: 0, unmatchedURLs: [], requiresReview: false)
    }
    let urls = extractURLs(from: answer)
    let verifiableSources = sources.filter { source in
      source.status == .fetched && !(source.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    let knownURLs = Set(verifiableSources.map { normalize($0.url) })
    let matched = urls.filter { knownURLs.contains(normalize($0)) }
    let unmatched = urls.filter { !knownURLs.contains(normalize($0)) }
    let valid = !matched.isEmpty && unmatched.isEmpty
    return WebResearchCitationCheck(
      isValid: valid,
      matchedSourceCount: matched.count,
      unmatchedURLs: unmatched,
      requiresReview: !valid
    )
  }

  private static func extractURLs(from text: String) -> [String] {
    let pattern = #"https?://[^\s)\]}>，。！？、]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let swiftRange = Range(match.range, in: text) else { return nil }
      return String(text[swiftRange])
    }
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
  }
}
