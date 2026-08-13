import Foundation

public struct TaskBudget: Codable, Equatable, Sendable {
  public let maxCost: Decimal
  public let maxInputTokens: Int
  public let maxOutputTokens: Int
  public let maxWallTimeSeconds: Int
  public let maxRepairRounds: Int

  public init(maxCost: Decimal, maxInputTokens: Int, maxOutputTokens: Int, maxWallTimeSeconds: Int, maxRepairRounds: Int) {
    self.maxCost = max(0, maxCost)
    self.maxInputTokens = max(1, maxInputTokens)
    self.maxOutputTokens = max(1, maxOutputTokens)
    self.maxWallTimeSeconds = max(1, maxWallTimeSeconds)
    self.maxRepairRounds = max(0, maxRepairRounds)
  }

  public static let standard = TaskBudget(maxCost: 1, maxInputTokens: 12_000, maxOutputTokens: 4_000, maxWallTimeSeconds: 600, maxRepairRounds: 3)
}

public enum ModelTier: String, Codable, Sendable {
  case fast
  case balanced
  case reasoning
}

public struct ModelRoute: Codable, Equatable, Sendable {
  public let tier: ModelTier
  public let maximumOutputTokens: Int
  public let reason: String

  public init(tier: ModelTier, maximumOutputTokens: Int, reason: String) {
    self.tier = tier
    self.maximumOutputTokens = max(1, maximumOutputTokens)
    self.reason = reason
  }
}

/// Deterministic first-pass routing keeps simple requests off the expensive
/// path. A provider-specific selector may map a tier to a configured model.
public enum ModelRouter {
  public static func route(intent: TaskIntent, promptLength: Int, budget: TaskBudget) -> ModelRoute {
    let tier: ModelTier
    switch intent {
    case .conversation, .explanation:
      tier = promptLength < 2_000 ? .fast : .balanced
    case .explore, .webResearch, .review, .test:
      tier = .balanced
    case .plan, .implement, .debug, .browserVerification, .computerUse, .externalCollaboration:
      tier = .reasoning
    }
    let cap: Int
    switch tier {
    case .fast: cap = min(budget.maxOutputTokens, 900)
    case .balanced: cap = min(budget.maxOutputTokens, 2_000)
    case .reasoning: cap = budget.maxOutputTokens
    }
    return ModelRoute(tier: tier, maximumOutputTokens: cap, reason: "intent=\(intent.rawValue); promptLength=\(promptLength)")
  }
}

public struct UsageLedgerEntry: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let operationID: UUID
  public let stage: AgentKind
  public let provider: String
  public let model: String
  public let inputTokens: Int
  public let outputTokens: Int
  public let cachedTokens: Int
  public let latencyMS: Int
  public let estimatedCost: Decimal
  public let qualityScore: Double?
  public let createdAt: Date

  public init(
    id: UUID = UUID(), operationID: UUID, stage: AgentKind, provider: String, model: String,
    inputTokens: Int, outputTokens: Int, cachedTokens: Int = 0, latencyMS: Int,
    estimatedCost: Decimal, qualityScore: Double?, createdAt: Date = .now
  ) {
    self.id = id
    self.operationID = operationID
    self.stage = stage
    self.provider = provider
    self.model = model
    self.inputTokens = max(0, inputTokens)
    self.outputTokens = max(0, outputTokens)
    self.cachedTokens = max(0, cachedTokens)
    self.latencyMS = max(0, latencyMS)
    self.estimatedCost = max(0, estimatedCost)
    self.qualityScore = qualityScore.map { min(max($0, 0), 1) }
    self.createdAt = createdAt
  }
}

public final class UsageLedger: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [UsageLedgerEntry] = []
  private let fileURL: URL?

  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    if let fileURL, let data = try? Data(contentsOf: fileURL), let restored = try? JSONDecoder().decode([UsageLedgerEntry].self, from: data) {
      entries = restored
    }
  }

  public func append(_ entry: UsageLedgerEntry) throws {
    lock.lock()
    entries.append(entry)
    let snapshot = entries
    lock.unlock()
    if let fileURL {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }
  }

  public func snapshot() -> [UsageLedgerEntry] {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  public func totalCost(operationID: UUID? = nil) -> Decimal {
    lock.lock()
    defer { lock.unlock() }
    return entries.lazy.filter { operationID == nil || $0.operationID == operationID }.reduce(Decimal.zero) { $0 + $1.estimatedCost }
  }

  public func contains(operationID: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.contains { $0.operationID == operationID }
  }
}
