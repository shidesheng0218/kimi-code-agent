import Foundation

public struct TerminalSearchMatch: Equatable, Sendable, Identifiable {
  public let id: String
  public let line: Int
  public let column: Int
  public let length: Int
  public let snippet: String

  public init(line: Int, column: Int, length: Int, snippet: String) {
    self.line = line
    self.column = column
    self.length = length
    self.snippet = snippet
    self.id = "\(line):\(column):\(length)"
  }
}

public struct TerminalSearchQuery: Equatable, Sendable {
  public var text: String
  public var caseSensitive: Bool

  public init(text: String, caseSensitive: Bool = false) {
    self.text = text
    self.caseSensitive = caseSensitive
  }

  public func matches(in transcript: String) -> [TerminalSearchMatch] {
    let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    var results: [TerminalSearchMatch] = []
    for (lineNumber, line) in transcript.components(separatedBy: .newlines).enumerated() {
      var start = line.startIndex
      while start < line.endIndex,
            let range = line.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive], range: start..<line.endIndex) {
        let column = line.distance(from: line.startIndex, to: range.lowerBound)
        let length = line.distance(from: range.lowerBound, to: range.upperBound)
        results.append(TerminalSearchMatch(line: lineNumber + 1, column: column + 1, length: length, snippet: line))
        start = range.upperBound > start ? range.upperBound : line.index(after: start)
      }
    }
    return results
  }
}

public enum TerminalTranscriptExporter {
  public static func plainText(_ transcript: String) -> String {
    TerminalScreenBuffer.render(transcript)
  }

  public static func html(_ transcript: String) -> String {
    let escaped = plainText(transcript)
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
    return "<pre style=\"background:#111;color:#eee;padding:16px;font-family:Menlo,monospace\">\(escaped)</pre>"
  }
}

public enum TerminalPaneOrientation: String, Codable, CaseIterable, Sendable {
  case horizontal
  case vertical
}

public struct TerminalPaneLayout: Codable, Equatable, Sendable {
  public var orientation: TerminalPaneOrientation
  public var panes: [UUID]
  public var ratios: [Double]

  public init(orientation: TerminalPaneOrientation = .horizontal, panes: [UUID] = [], ratios: [Double] = []) {
    self.orientation = orientation
    self.panes = panes
    self.ratios = ratios.isEmpty ? Array(repeating: 1.0 / Double(max(1, panes.count)), count: panes.count) : ratios
  }

  public static func single(_ id: UUID) -> Self {
    TerminalPaneLayout(orientation: .horizontal, panes: [id], ratios: [1])
  }

  public mutating func split(_ orientation: TerminalPaneOrientation, with id: UUID) {
    guard !panes.contains(id) else { return }
    self.orientation = orientation
    panes.append(id)
    ratios = Array(repeating: 1.0 / Double(panes.count), count: panes.count)
  }

  public mutating func close(_ id: UUID) {
    panes.removeAll { $0 == id }
    ratios = panes.isEmpty ? [] : Array(repeating: 1.0 / Double(panes.count), count: panes.count)
  }
}

public enum SSHCredentialReference: Codable, Equatable, Sendable {
  case keychain(account: String, service: String)
  case sshAgent
  case file(path: String)

  public var displayName: String {
    switch self {
    case .keychain(let account, _): return "macOS Keychain · \(account)"
    case .sshAgent: return "ssh-agent"
    case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
    }
  }

  public var secretValue: String? { nil }

  private enum CodingKeys: String, CodingKey { case kind, account, service, path }
  private enum Kind: String, Codable { case keychain, sshAgent, file }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .keychain: self = .keychain(account: try values.decode(String.self, forKey: .account), service: try values.decode(String.self, forKey: .service))
    case .sshAgent: self = .sshAgent
    case .file: self = .file(path: try values.decode(String.self, forKey: .path))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .keychain(let account, let service):
      try values.encode(Kind.keychain, forKey: .kind); try values.encode(account, forKey: .account); try values.encode(service, forKey: .service)
    case .sshAgent: try values.encode(Kind.sshAgent, forKey: .kind)
    case .file(let path): try values.encode(Kind.file, forKey: .kind); try values.encode(path, forKey: .path)
    }
  }
}

public struct TerminalReconnectPolicy: Codable, Equatable, Sendable {
  public var initialDelaySeconds: Int
  public var maximumDelaySeconds: Int
  public var maximumAttempts: Int

  public static let `default` = Self(initialDelaySeconds: 1, maximumDelaySeconds: 30, maximumAttempts: 6)

  public init(initialDelaySeconds: Int = 1, maximumDelaySeconds: Int = 30, maximumAttempts: Int = 6) {
    self.initialDelaySeconds = max(1, initialDelaySeconds)
    self.maximumDelaySeconds = max(self.initialDelaySeconds, maximumDelaySeconds)
    self.maximumAttempts = max(0, maximumAttempts)
  }

  public func delay(forAttempt attempt: Int) -> Int {
    let exponent = max(0, attempt - 1)
    return min(maximumDelaySeconds, initialDelaySeconds * (1 << min(exponent, 10)))
  }
}

public struct TmuxSessionRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let windowCount: Int
  public let lastActivity: String

  public init(name: String, windowCount: Int, lastActivity: String) {
    self.name = name
    self.windowCount = max(0, windowCount)
    self.lastActivity = lastActivity
  }

  public static func parse(_ output: String) -> [TmuxSessionRecord] {
    output.split(separator: "\n").compactMap { line in
      let values = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
      guard let rawName = values.first, !rawName.isEmpty else { return nil }
      return TmuxSessionRecord(
        name: String(rawName),
        windowCount: values.count > 1 ? Int(values[1]) ?? 0 : 0,
        lastActivity: values.count > 2 ? String(values[2]) : ""
      )
    }
  }
}

public struct TerminalResourceScheduler: Sendable {
  public let maxConcurrent: Int
  public let memoryLimitMB: Int

  public init(maxConcurrent: Int = 4, memoryLimitMB: Int = 8_192) {
    self.maxConcurrent = max(1, maxConcurrent)
    self.memoryLimitMB = max(256, memoryLimitMB)
  }

  public func canStart(cpuLoad: Double, memoryMB: Int, runningCount: Int = 0) -> Bool {
    max(0, min(1, cpuLoad)) < 0.9 && memoryMB >= 0 && memoryMB <= memoryLimitMB && runningCount < maxConcurrent
  }
}

public enum TerminalPasteSafety {
  public static func requiresApproval(for text: String) -> Bool {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }
    if normalized.contains("\n") || normalized.contains("\r") { return true }
    let patterns = ["sudo ", "rm -rf", "git push", "git reset --hard", "chmod 777", "shutdown", "reboot"]
    return patterns.contains { normalized.localizedCaseInsensitiveContains($0) }
  }
}
