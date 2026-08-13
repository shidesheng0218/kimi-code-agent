import Foundation

/// Validation shared by the SSH editor and the runtime adapter.
public enum SSHProfileValidation {
  public static func validate(_ profile: SSHProfile) -> [String] {
    var issues: [String] = []
    if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("请输入配置名称")
    }
    if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("请输入主机地址")
    } else if profile.host.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) {
      issues.append("主机地址不能包含空格或引号")
    }
    if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append("请输入用户名")
    } else if profile.username.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) {
      issues.append("用户名不能包含空格或引号")
    }
    if !(1...65_535).contains(profile.port) { issues.append("端口必须在 1–65535 之间") }
    if profile.shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append("请输入远程 Shell") }
    return issues
  }
}

public enum TerminalSSHRecovery: Equatable, Sendable {
  case none
  case tmux(sessionName: String)
}

public struct TerminalViewportMetrics: Equatable, Sendable {
  public var rows: Int
  public var columns: Int

  public init(rows: Int, columns: Int) {
    self.rows = max(2, rows)
    self.columns = max(20, columns)
  }

  public static func from(width: Double, height: Double, characterWidth: Double = 8, characterHeight: Double = 18) -> Self {
    let safeCharacterWidth = max(1, characterWidth)
    let safeCharacterHeight = max(1, characterHeight)
    return Self(
      rows: Int(floor(max(2, height) / safeCharacterHeight)),
      columns: Int(floor(max(20, width) / safeCharacterWidth))
    )
  }
}

/// Deterministic queue policy. A session owns one shell stream, while different sessions may run in parallel.
public struct TerminalQueueScheduler: Sendable {
  public let maxConcurrent: Int

  public init(maxConcurrent: Int = 4) {
    self.maxConcurrent = max(1, maxConcurrent)
  }

  public func startableJobs(from jobs: [TerminalCommandJob]) -> [TerminalCommandJob] {
    let running = Set(jobs.filter { $0.status == .running }.map(\.sessionID))
    let availableSlots = max(0, maxConcurrent - running.count)
    guard availableSlots > 0 else { return [] }
    var reserved = running
    var selected: [TerminalCommandJob] = []
    for job in jobs.sorted(by: {
      if $0.priority != $1.priority { return $0.priority > $1.priority }
      return $0.createdAt < $1.createdAt
    }) where job.status == .queued {
      guard !reserved.contains(job.sessionID) else { continue }
      selected.append(job)
      reserved.insert(job.sessionID)
      if selected.count == availableSlots { break }
    }
    return selected
  }
}

public extension TerminalEnvironmentProfile {
  /// Names are persisted so the UI can redact secrets without ever displaying their values.
  var redactedVariables: [String: String] {
    Dictionary(uniqueKeysWithValues: variables.map { key, value in
      let isSecret = secretVariableNames.contains { $0.caseInsensitiveCompare(key) == .orderedSame }
      return (key, isSecret ? "••••••••" : value)
    })
  }
}
