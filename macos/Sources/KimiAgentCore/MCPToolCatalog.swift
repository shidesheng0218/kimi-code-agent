import Foundation

public enum MCPWorkerState: String, Codable, CaseIterable, Sendable {
  case starting
  case healthy
  case degraded
  case reconnecting
  case unavailable
}

public struct MCPDiscoveredTool: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let serverID: String
  public let tool: MCPTool
  public let discoveredAt: Date

  public init(serverID: String, tool: MCPTool, discoveredAt: Date = .now) {
    self.serverID = serverID
    self.tool = tool
    self.id = "\(serverID):\(tool.name)"
    self.discoveredAt = discoveredAt
  }
}

public final class MCPToolCatalog: @unchecked Sendable {
  private let lock = NSLock()
  private var statuses: [String: MCPWorkerState] = [:]
  private var tools: [String: MCPDiscoveredTool] = [:]

  public init() {}

  public func register(serverID: String, status: MCPWorkerState, tools discovered: [MCPTool]) {
    lock.lock()
    statuses[serverID] = status
    // Re-registration replaces the server's tool set: tools that the server
    // no longer advertises must not stay discoverable or callable.
    for (key, item) in tools where item.serverID == serverID {
      tools.removeValue(forKey: key)
    }
    for tool in discovered {
      tools["\(serverID):\(tool.name)"] = MCPDiscoveredTool(serverID: serverID, tool: tool)
    }
    lock.unlock()
  }

  public func setStatus(serverID: String, status: MCPWorkerState) {
    lock.lock(); statuses[serverID] = status; lock.unlock()
  }

  public func status(serverID: String) -> MCPWorkerState? {
    lock.lock(); defer { lock.unlock() }; return statuses[serverID]
  }

  public func search(query: String, serverID: String? = nil) -> [MCPDiscoveredTool] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    lock.lock(); defer { lock.unlock() }
    return tools.values.filter { item in
      (serverID == nil || item.serverID == serverID) &&
      (needle.isEmpty || item.tool.name.lowercased().contains(needle) || item.tool.description.lowercased().contains(needle)) &&
      statuses[item.serverID] != .unavailable
    }.sorted { $0.id < $1.id }
  }

  public func all() -> [MCPDiscoveredTool] {
    search(query: "")
  }

  /// Returns a bounded, relevance-ranked subset for a model step. MCP tools
  /// remain discoverable through the catalog, but unrelated schemas are not
  /// injected into every prompt.
  public func relevant(query: String, serverID: String? = nil, limit: Int = 12) -> [MCPDiscoveredTool] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let terms = relevanceTerms(normalizedQuery)
    let candidates = search(query: "", serverID: serverID)
    guard !terms.isEmpty else { return Array(candidates.prefix(max(1, limit))) }
    let ranked = candidates.map { item -> (MCPDiscoveredTool, Int) in
      let haystack = "\(item.tool.name) \(item.tool.description)".lowercased()
      var score = 0
      if !normalizedQuery.isEmpty && haystack.contains(normalizedQuery) { score += 4 }
      for term in terms where haystack.contains(term) {
        score += term.count == 1 ? 1 : 2
      }
      return (item, score)
    }
    let matches = ranked
      .filter { $0.1 > 0 }
      .sorted { lhs, rhs in
        lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
      }
      .map(\.0)
    return Array((matches.isEmpty ? candidates : matches).prefix(max(1, limit)))
  }

  private func relevanceTerms(_ query: String) -> [String] {
    guard !query.isEmpty else { return [] }
    var terms: [String] = query
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count >= 2 }
    let cjk = query.filter { $0.unicodeScalars.contains { scalar in
      (0x4E00...0x9FFF).contains(Int(scalar.value))
    }}
    let chars = Array(cjk)
    if chars.count > 1 {
      terms.append(contentsOf: chars.map(String.init))
    }
    return Array(Set(terms))
  }
}

public struct MCPWorkerHealth: Codable, Equatable, Sendable {
  public let serverID: String
  public var status: MCPWorkerState
  public var restartCount: Int
  public var lastError: String?
  public var updatedAt: Date

  public init(serverID: String, status: MCPWorkerState = .starting, restartCount: Int = 0, lastError: String? = nil, updatedAt: Date = .now) {
    self.serverID = serverID
    self.status = status
    self.restartCount = restartCount
    self.lastError = lastError
    self.updatedAt = updatedAt
  }
}

/// Lifecycle-only worker supervisor. Concrete stdio/http clients remain
/// adapters; this actor owns health state, restart limits and cancellation.
public actor MCPWorkerSupervisor {
  private var healthByServer: [String: MCPWorkerHealth] = [:]
  private let maxRestarts: Int

  public init(maxRestarts: Int = 5) { self.maxRestarts = max(0, maxRestarts) }

  public func markStarting(serverID: String) {
    healthByServer[serverID] = MCPWorkerHealth(serverID: serverID, status: .starting)
  }

  public func markHealthy(serverID: String) {
    var health = healthByServer[serverID] ?? MCPWorkerHealth(serverID: serverID)
    health.status = .healthy; health.lastError = nil; health.updatedAt = .now
    healthByServer[serverID] = health
  }

  public func markFailure(serverID: String, message: String) -> Bool {
    var health = healthByServer[serverID] ?? MCPWorkerHealth(serverID: serverID)
    health.lastError = message
    health.updatedAt = .now
    guard health.restartCount < maxRestarts else {
      health.status = .unavailable
      healthByServer[serverID] = health
      return false
    }
    health.restartCount += 1
    health.status = .reconnecting
    healthByServer[serverID] = health
    return true
  }

  public func health(serverID: String) -> MCPWorkerHealth? { healthByServer[serverID] }

  public func snapshot() -> [MCPWorkerHealth] {
    healthByServer.values.sorted { $0.serverID < $1.serverID }
  }
}
