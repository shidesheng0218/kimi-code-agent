import Foundation

public enum WebResearchSourceStatus: String, Codable, CaseIterable, Sendable {
  case discovered
  case fetched
  case failed
}

public struct WebResearchSource: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var title: String
  public var url: String
  public var snippet: String
  public var domain: String
  public var publishedAt: String?
  public var status: WebResearchSourceStatus
  public var summary: String?
  public var failureMessage: String?
  public var updatedAt: Date

  public init(
    id: String? = nil,
    title: String,
    url: String,
    snippet: String = "",
    domain: String? = nil,
    publishedAt: String? = nil,
    status: WebResearchSourceStatus = .discovered,
    summary: String? = nil,
    failureMessage: String? = nil,
    updatedAt: Date = .now
  ) {
    self.id = id ?? url
    self.title = title
    self.url = url
    self.snippet = snippet
    self.domain = domain ?? URL(string: url)?.host(percentEncoded: false) ?? ""
    self.publishedAt = publishedAt
    self.status = status
    self.summary = summary
    self.failureMessage = failureMessage
    self.updatedAt = updatedAt
  }
}

public struct WebResearchUsageRecord: Codable, Equatable, Sendable {
  public var searchCount: Int
  public var cachedSearchCount: Int
  public var fetchCount: Int
  public var cachedFetchCount: Int
  public var fetchedChars: Int
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int
  public var provider: String?
  public var sourceCount: Int
  public var lastUpdatedAt: Date?

  public init(
    searchCount: Int = 0,
    cachedSearchCount: Int = 0,
    fetchCount: Int = 0,
    cachedFetchCount: Int = 0,
    fetchedChars: Int = 0,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    totalTokens: Int = 0,
    provider: String? = nil,
    sourceCount: Int = 0,
    lastUpdatedAt: Date? = nil
  ) {
    self.searchCount = searchCount
    self.cachedSearchCount = cachedSearchCount
    self.fetchCount = fetchCount
    self.cachedFetchCount = cachedFetchCount
    self.fetchedChars = fetchedChars
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.provider = provider
    self.sourceCount = sourceCount
    self.lastUpdatedAt = lastUpdatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case searchCount, cachedSearchCount, fetchCount, cachedFetchCount, fetchedChars
    case inputTokens, outputTokens, totalTokens, provider, sourceCount, lastUpdatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      searchCount: try container.decodeIfPresent(Int.self, forKey: .searchCount) ?? 0,
      cachedSearchCount: try container.decodeIfPresent(Int.self, forKey: .cachedSearchCount) ?? 0,
      fetchCount: try container.decodeIfPresent(Int.self, forKey: .fetchCount) ?? 0,
      cachedFetchCount: try container.decodeIfPresent(Int.self, forKey: .cachedFetchCount) ?? 0,
      fetchedChars: try container.decodeIfPresent(Int.self, forKey: .fetchedChars) ?? 0,
      inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
      outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
      totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0,
      provider: try container.decodeIfPresent(String.self, forKey: .provider),
      sourceCount: try container.decodeIfPresent(Int.self, forKey: .sourceCount) ?? 0,
      lastUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
    )
  }
}

public struct WebResearchUsageSnapshot: Codable, Equatable, Sendable {
  public let provider: String
  public let searches: Int
  public let cachedSearches: Int
  public let fetches: Int
  public let cachedFetches: Int
  public let fetchedChars: Int
  public let inputTokens: Int
  public let outputTokens: Int
  public let totalTokens: Int
  public let toolCalls: Int

  public init(
    provider: String = "",
    searches: Int = 0,
    cachedSearches: Int = 0,
    fetches: Int = 0,
    cachedFetches: Int = 0,
    fetchedChars: Int = 0,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    totalTokens: Int = 0,
    toolCalls: Int = 0
  ) {
    self.provider = provider
    self.searches = searches
    self.cachedSearches = cachedSearches
    self.fetches = fetches
    self.cachedFetches = cachedFetches
    self.fetchedChars = fetchedChars
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.toolCalls = toolCalls
  }
}

public enum WebResearchEvidence {
  private struct WireSource: Decodable {
    let title: String?
    let url: String?
    let snippet: String?
    let description: String?
    let date: String?
    let publishedAt: String?
  }

  public static func extractSources(from event: AgentEvent) -> [WebResearchSource] {
    guard let action = event.payload["webResearchAction"], action == "search" || action == "fetch" else { return [] }
    if action == "fetch", let fetched = fetchSource(from: event) {
      return [fetched]
    }
    guard let rawSources = event.payload["sources"], let data = rawSources.data(using: .utf8),
          let values = try? JSONDecoder().decode([WireSource].self, from: data) else { return [] }
    return values.compactMap { value in
      guard let url = value.url?.trimmingCharacters(in: .whitespacesAndNewlines),
            let parsedURL = URL(string: url),
            let scheme = parsedURL.scheme?.lowercased(), (scheme == "https" || scheme == "http"),
            parsedURL.host(percentEncoded: false) != nil else { return nil }
      return WebResearchSource(
        title: value.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? url,
        url: url,
        snippet: value.snippet ?? value.description ?? "",
        publishedAt: value.date ?? value.publishedAt,
        status: action == "fetch" ? .fetched : .discovered
      )
    }
  }

  private static func fetchSource(from event: AgentEvent) -> WebResearchSource? {
    guard let rawArguments = event.payload["arguments"],
          let argumentData = rawArguments.data(using: .utf8),
          let arguments = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any],
          let url = arguments["url"] as? String,
          let parsedURL = URL(string: url),
          let scheme = parsedURL.scheme?.lowercased(), (scheme == "https" || scheme == "http"),
          let host = parsedURL.host(percentEncoded: false) else { return nil }
    let structuredContent = event.payload["webResearchContent"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rawOutput = event.payload["output"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let summarySource = structuredContent.isEmpty ? rawOutput : structuredContent
    let limitedSummary = summarySource.isEmpty ? nil : String(summarySource.prefix(800))
    return WebResearchSource(
      title: host,
      url: url,
      status: event.kind == .error ? .failed : .fetched,
      summary: limitedSummary,
      failureMessage: event.kind == .error ? limitedSummary : nil
    )
  }

  public static func merging(_ existing: [WebResearchSource], with additions: [WebResearchSource]) -> [WebResearchSource] {
    var values = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    for source in additions {
      if var prior = values[source.id] {
        prior.title = source.title.isEmpty ? prior.title : source.title
        prior.snippet = source.snippet.isEmpty ? prior.snippet : source.snippet
        prior.publishedAt = source.publishedAt ?? prior.publishedAt
        prior.status = source.status == .fetched ? .fetched : prior.status
        prior.summary = source.summary ?? prior.summary
        prior.failureMessage = source.failureMessage ?? prior.failureMessage
        prior.updatedAt = source.updatedAt
        values[source.id] = prior
      } else {
        values[source.id] = source
      }
    }
    return values.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(50).map { $0 }
  }

  public static func updatingUsage(_ usage: WebResearchUsageRecord, event: AgentEvent, sourceCount: Int) -> WebResearchUsageRecord {
    var result = usage
    guard event.kind == .toolFinished || event.kind == .error else { return result }
    switch event.payload["webResearchAction"] {
    case "search": result.searchCount += 1
    case "fetch": result.fetchCount += 1
    default: return result
    }
    result.sourceCount = sourceCount
    result.lastUpdatedAt = .now
    return result
  }

  public static func mergingUsage(
    _ usage: WebResearchUsageRecord,
    snapshot: WebResearchUsageSnapshot,
    sourceCount: Int
  ) -> WebResearchUsageRecord {
    var result = usage
    result.provider = snapshot.provider.isEmpty ? result.provider : snapshot.provider
    result.searchCount = max(result.searchCount, snapshot.searches)
    result.cachedSearchCount = max(result.cachedSearchCount, snapshot.cachedSearches)
    result.fetchCount = max(result.fetchCount, snapshot.fetches)
    result.cachedFetchCount = max(result.cachedFetchCount, snapshot.cachedFetches)
    result.fetchedChars = max(result.fetchedChars, snapshot.fetchedChars)
    result.inputTokens = max(result.inputTokens, snapshot.inputTokens)
    result.outputTokens = max(result.outputTokens, snapshot.outputTokens)
    result.totalTokens = max(result.totalTokens, snapshot.totalTokens)
    result.sourceCount = sourceCount
    result.lastUpdatedAt = .now
    return result
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
