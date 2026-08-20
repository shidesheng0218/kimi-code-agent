import Foundation

public enum KimiActivityKind: String, Codable, Sendable {
  case sessionCreated
  case promptSent
  case replyReceived
}

public struct KimiActivityRecord: Codable, Equatable, Sendable {
  public let kind: KimiActivityKind
  public let date: Date
  public let project: String?

  public init(kind: KimiActivityKind, date: Date = .now, project: String? = nil) {
    self.kind = kind
    self.date = date
    self.project = project
  }
}

/// Append-only JSONL activity log backing the home-screen statistics. Lives
/// next to the rest of the app's state; records are written by the kernel at
/// the same points where user-visible events are published, so the numbers on
/// the home screen always reflect real activity.
public actor KimiActivityStatsStore {
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func record(_ entry: KimiActivityRecord) {
    guard let data = try? JSONEncoder.kimiActivity.encode(entry),
          let line = String(data: data, encoding: .utf8) else { return }
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      }
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((line + "\n").utf8))
    } catch {
      // Statistics must never break the product path.
    }
  }

  public func records() -> [KimiActivityRecord] {
    guard let data = try? Data(contentsOf: fileURL),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
      guard let lineData = line.data(using: .utf8) else { return nil }
      return try? JSONDecoder.kimiActivity.decode(KimiActivityRecord.self, from: lineData)
    }
  }
}

public struct KimiActivityStats: Equatable, Sendable {
  public var sessionCount: Int = 0
  public var messageCount: Int = 0
  public var activeDays: Int = 0
  public var currentStreak: Int = 0
  public var longestStreak: Int = 0
  /// Hour of day (0-23) with the most activity, if any.
  public var peakHour: Int?
  /// Activity count per day (start-of-day keys), for the heatmap.
  public var dailyCounts: [Date: Int] = [:]

  public init() {}
}

/// Everything the home dashboard renders, merged from the activity log and
/// the Harness event log. Each field keeps its most reliable source:
/// streaks and the heatmap come from the activity aggregator (seeded with
/// real session timestamps), while tool-call and model-usage numbers come
/// from recorded Harness events.
public struct KimiHomeStats: Equatable, Sendable {
  public var sessionCount: Int = 0
  public var messageCount: Int = 0
  public var toolCallCount: Int = 0
  public var activeDays: Int = 0
  public var currentStreak: Int = 0
  public var longestStreak: Int = 0
  public var peakHour: Int?
  public var favoriteModel: String?
  public var dailyCounts: [Date: Int] = [:]
  public var modelUsage: [String: Int] = [:]

  public init() {}

  /// The single busiest day, used for the insight line under the heatmap.
  public var busiestDayCount: Int? { dailyCounts.values.max() }
}

public enum KimiActivityAggregator {
  /// Aggregates recorded activity plus the persisted session list. Sessions
  /// seed the heatmap with their `updatedAt` dates so a pre-stats install
  /// still shows its real history.
  public static func aggregate(
    records: [KimiActivityRecord],
    sessions: [KimiSessionSummary],
    now: Date = .now,
    calendar: Calendar = .current,
    rangeDays: Int? = nil
  ) -> KimiActivityStats {
    var stats = KimiActivityStats()
    let cutoff = rangeDays.flatMap { calendar.date(byAdding: .day, value: -$0, to: now) }
    let scoped = cutoff.map { limit in records.filter { $0.date >= limit } } ?? records

    stats.sessionCount = sessions.count
    stats.messageCount = scoped.filter { $0.kind == .promptSent || $0.kind == .replyReceived }.count

    var dayCounts: [Date: Int] = [:]
    for record in scoped {
      dayCounts[calendar.startOfDay(for: record.date), default: 0] += 1
    }
    // Seed from session timestamps so history predating the stats log is not
    // erased; a session counts as one unit of activity on its day.
    for session in sessions where cutoff.map({ session.updatedAt >= $0 }) ?? true {
      let day = calendar.startOfDay(for: session.updatedAt)
      dayCounts[day, default: 0] += 1
    }
    stats.dailyCounts = dayCounts
    stats.activeDays = dayCounts.keys.count

    var hourCounts: [Int: Int] = [:]
    for record in scoped {
      hourCounts[calendar.component(.hour, from: record.date), default: 0] += 1
    }
    stats.peakHour = hourCounts.max(by: { $0.value < $1.value }).map(\.key)

    let activeDaySet = Set(dayCounts.keys)
    let today = calendar.startOfDay(for: now)
    // Current streak: walk backwards from today; a today with no activity yet
    // still counts the streak ending yesterday (standard contribution-rule).
    var cursor = activeDaySet.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    var current = 0
    while activeDaySet.contains(cursor) {
      current += 1
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
    }
    stats.currentStreak = current

    var longest = 0
    var run = 0
    var previous: Date?
    for day in activeDaySet.sorted() {
      if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
        run += 1
      } else {
        run = 1
      }
      longest = max(longest, run)
      previous = day
    }
    stats.longestStreak = longest
    return stats
  }
}

private extension JSONEncoder {
  static let kimiActivity: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
}

private extension JSONDecoder {
  static let kimiActivity: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
