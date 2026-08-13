import Foundation

public enum TaskEventSearch {
  public static func filter(events: [String], query: String) -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return events }
    return events.filter { $0.localizedCaseInsensitiveContains(trimmed) }
  }
}
