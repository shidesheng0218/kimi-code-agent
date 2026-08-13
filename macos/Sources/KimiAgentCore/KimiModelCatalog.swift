import Foundation

public struct KimiModelSummary: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let object: String
  public let ownedBy: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case object
    case ownedBy = "owned_by"
  }

  public var displayName: String {
    guard let ownedBy, !ownedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return id
    }
    return "\(id) · \(ownedBy)"
  }
}

public struct KimiModelCatalogResponse: Codable, Sendable {
  public let object: String?
  public let data: [KimiModelSummary]
}

public enum KimiModelCatalogError: Error, LocalizedError, Sendable {
  case invalidBaseURL
  case invalidResponse
  case httpStatus(Int, String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Base URL 必须是合法的 HTTP(S) 地址。"
    case .invalidResponse:
      return "模型列表请求返回了无效响应。"
    case let .httpStatus(status, body):
      return body.isEmpty ? "模型列表请求失败，HTTP \(status)。" : "模型列表请求失败，HTTP \(status)：\(body)"
    }
  }
}

public enum KimiModelCatalogClient {
  public static func fallbackModels() -> [KimiModelSummary] {
    [
      KimiModelSummary(id: "kimi-k2.7-code", object: "model", ownedBy: nil),
      KimiModelSummary(id: "kimi-k3", object: "model", ownedBy: nil)
    ]
  }

  public static func fetchModels(
    baseURL: String,
    apiKey: String,
    session: URLSession = .shared
  ) async throws -> [KimiModelSummary] {
    let requestURL = try modelsURL(baseURL: baseURL)
    var request = URLRequest(url: requestURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw KimiModelCatalogError.invalidResponse
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw KimiModelCatalogError.httpStatus(httpResponse.statusCode, body)
    }

    let decoded = try JSONDecoder().decode(KimiModelCatalogResponse.self, from: data)
    return decoded.data.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  public static func modelsURL(baseURL: String) throws -> URL {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          (scheme == "https" || scheme == "http"),
          url.host(percentEncoded: false) != nil else {
      throw KimiModelCatalogError.invalidBaseURL
    }
    return url.appendingPathComponent("models")
  }
}
