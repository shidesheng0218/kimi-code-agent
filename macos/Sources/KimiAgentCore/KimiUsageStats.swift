import Foundation

public enum KimiUsageStatsRange: String, Codable, CaseIterable, Sendable {
  case all
  case thirtyDays
  case sevenDays

  public var days: Int? {
    switch self {
    case .all: nil
    case .thirtyDays: 30
    case .sevenDays: 7
    }
  }
}

/// Aggregated usage for the home dashboard. Computed from the recorded
/// Harness event log, so every number traces back to real recorded work.
public struct KimiUsageStats: Codable, Equatable, Sendable {
  public var totalSessions: Int = 0
  public var totalMessages: Int = 0
  public var totalToolCalls: Int = 0
  public var modelUsage: [String: Int] = [:]
  /// `yyyy-MM-dd` (local) -> activity points (messages + tool calls).
  public var dailyActivity: [String: Int] = [:]
  /// Hour of day (0-23) -> message count, for the peak-hour card.
  public var hourlyMessages: [Int: Int] = [:]

  public init() {}

  public var activeDays: Int { dailyActivity.values.filter { $0 > 0 }.count }

  public var favoriteModel: String? {
    modelUsage.max(by: { $0.value < $1.value })?.key
  }

  public var peakHour: Int? {
    hourlyMessages.max(by: { $0.value < $1.value })?.key
  }
}

public enum KimiUsageStatsComputer {
  static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.locale = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

  public static func compute(
    events: [HarnessEvent],
    range: KimiUsageStatsRange = .all,
    now: Date = .now
  ) -> KimiUsageStats {
    var stats = KimiUsageStats()
    let calendar = Calendar.current
    let cutoff: Date? = range.days.flatMap {
      calendar.date(byAdding: .day, value: -($0 - 1), to: calendar.startOfDay(for: now))
    }
    var sessions = Set<UUID>()
    for event in events {
      if let cutoff, event.timestamp < cutoff { continue }
      sessions.insert(event.sessionID)
      switch event.kind {
      case .operationAccepted:
        stats.totalMessages += 1
        bump(&stats, at: event.timestamp, calendar: calendar, countHour: true)
      case .assistantMessage:
        stats.totalMessages += 1
        bump(&stats, at: event.timestamp, calendar: calendar, countHour: true)
        if let model = decodeModelID(from: event.payload) {
          stats.modelUsage[model, default: 0] += 1
        }
      case .toolCallDeclared:
        stats.totalToolCalls += 1
        bump(&stats, at: event.timestamp, calendar: calendar, countHour: false)
      default:
        break
      }
    }
    stats.totalSessions = sessions.count
    return stats
  }

  private static func bump(
    _ stats: inout KimiUsageStats,
    at date: Date,
    calendar: Calendar,
    countHour: Bool
  ) {
    stats.dailyActivity[dayKey(date), default: 0] += 1
    if countHour {
      stats.hourlyMessages[calendar.component(.hour, from: date), default: 0] += 1
    }
  }

  private static func decodeModelID(from payload: Data?) -> String? {
    guard let payload,
          let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    for key in ["model", "modelID", "modelId"] {
      if let value = object[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }
}

public extension KimiUsageStats {
  /// Current and longest consecutive-active-day streaks.
  func streaks(now: Date = .now) -> (current: Int, longest: Int) {
    let calendar = Calendar.current
    let days = Set(dailyActivity.filter { $0.value > 0 }.keys)
    guard !days.isEmpty else { return (0, 0) }
    func has(_ date: Date) -> Bool { days.contains(KimiUsageStatsComputer.dayKey(date)) }

    var current = 0
    var cursor = calendar.startOfDay(for: now)
    // Today may not have activity yet; the streak then counts back from yesterday.
    if !has(cursor), let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) {
      cursor = yesterday
    }
    while has(cursor) {
      current += 1
      guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = previous
    }

    var longest = 0
    var run = 0
    var previous: Date?
    for key in days.sorted() {
      guard let date = KimiUsageStatsComputer.dayFormatter.date(from: key) else { continue }
      if let previous,
         let expected = calendar.date(byAdding: .day, value: 1, to: previous),
         calendar.isDate(expected, inSameDayAs: date) {
        run += 1
      } else {
        run = 1
      }
      previous = date
      longest = max(longest, run)
    }
    return (current, longest)
  }
}
