import Foundation

public enum BrowserVerificationStepKind: String, Codable, CaseIterable, Sendable {
  case open
  case navigate
  case inspect
  case click
  case typeText
  case pressKey
  case scroll
  case screenshot
  case collectConsole
  case collectNetwork
}

public struct BrowserVerificationStep: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: BrowserVerificationStepKind
  public let url: URL?
  public let selector: String?
  public let text: String?
  public let key: String?
  public let artifactName: String?
  public let requiresApproval: Bool
  public let timeoutSeconds: Int

  public init(
    id: UUID = UUID(),
    kind: BrowserVerificationStepKind,
    url: URL? = nil,
    selector: String? = nil,
    text: String? = nil,
    key: String? = nil,
    artifactName: String? = nil,
    requiresApproval: Bool = false,
    timeoutSeconds: Int = 30
  ) {
    self.id = id
    self.kind = kind
    self.url = url
    self.selector = selector
    self.text = text
    self.key = key
    self.artifactName = artifactName
    self.requiresApproval = requiresApproval
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct BrowserVerificationPlan: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var allowedDomains: [String]
  public var steps: [BrowserVerificationStep]
  public var stopOnFailure: Bool
  public var maxRepairRounds: Int

  public init(
    id: UUID = UUID(),
    allowedDomains: [String] = [],
    steps: [BrowserVerificationStep],
    stopOnFailure: Bool = true,
    maxRepairRounds: Int = 3
  ) {
    self.id = id
    self.allowedDomains = allowedDomains
    self.steps = steps
    self.stopOnFailure = stopOnFailure
    self.maxRepairRounds = maxRepairRounds
  }

  public func requiresApproval(for url: URL) -> Bool {
    guard let host = url.host(percentEncoded: false)?.lowercased() else {
      // File URLs carry no host and can render local documents (bank
      // statements, notes, downloaded pages) whose content the model could
      // read back through inspect/screenshot; never auto-approve them.
      return true
    }
    if BrowserDomainPolicy.isLocal(host: host) {
      return false
    }
    return !allowedDomains.contains { BrowserDomainPolicy.matches(host: host, domain: $0) }
  }
}

public enum BrowserArtifactKind: String, Codable, CaseIterable, Sendable {
  case screenshot
  case consoleError
  case networkError
  case domSnapshot
}

public struct BrowserArtifact: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let kind: BrowserArtifactKind
  public let name: String
  public let path: String?
  public let text: String?

  public init(id: UUID = UUID(), kind: BrowserArtifactKind, name: String, path: String? = nil, text: String? = nil) {
    self.id = id
    self.kind = kind
    self.name = name
    self.path = path
    self.text = text
  }
}

public struct BrowserVerificationTrace: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let stepKind: BrowserVerificationStepKind
  public let message: String
  public let timestamp: Date

  public init(id: UUID = UUID(), stepKind: BrowserVerificationStepKind, message: String, timestamp: Date = .now) {
    self.id = id
    self.stepKind = stepKind
    self.message = message
    self.timestamp = timestamp
  }
}

public struct BrowserVerificationResult: Codable, Equatable, Sendable {
  public let passed: Bool
  public let currentURL: URL?
  public let artifacts: [BrowserArtifact]
  public let timeline: [BrowserVerificationTrace]

  public init(passed: Bool, currentURL: URL? = nil, artifacts: [BrowserArtifact] = [], timeline: [BrowserVerificationTrace] = []) {
    self.passed = passed
    self.currentURL = currentURL
    self.artifacts = artifacts
    self.timeline = timeline
  }

  public var repairSummary: String {
    var parts: [String] = []
    if let currentURL {
      parts.append("当前页面：\(currentURL.absoluteString)")
    }
    for artifact in artifacts {
      switch artifact.kind {
      case .screenshot:
        if let path = artifact.path { parts.append("截图：\(path)") }
      case .consoleError, .networkError, .domSnapshot:
        if let text = artifact.text, !text.isEmpty { parts.append("\(artifact.name)：\(text)") }
      }
    }
    for trace in timeline.suffix(3) {
      parts.append("\(trace.stepKind.rawValue)：\(trace.message)")
    }
    return parts.joined(separator: "\n")
  }
}

public enum BrowserDomainPolicy {
  public static func isLocal(host: String) -> Bool {
    let normalized = host.lowercased()
    return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1" || normalized.hasSuffix(".localhost")
  }

  public static func matches(host: String, domain: String) -> Bool {
    let normalizedHost = host.lowercased()
    let normalizedDomain = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedDomain.isEmpty else { return false }
    return normalizedHost == normalizedDomain || normalizedHost.hasSuffix("." + normalizedDomain)
  }
}
