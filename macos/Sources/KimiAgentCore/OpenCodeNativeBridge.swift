import Foundation

public enum OpenCodeNativeBridgeOperation: String, Codable, CaseIterable, Sendable {
  case webSearch = "web.search"
  case webFetch = "web.fetch"
  case browserVerify = "browser.verify"
  case computerInspect = "computer.inspect"
  case computerScreenshot = "computer.screenshot"
  case computerClick = "computer.click"
  case computerTypeText = "computer.type_text"
  case computerPressKey = "computer.press_key"
}

public enum OpenCodeNativeBridgeValidationError: LocalizedError, Equatable, Sendable {
  case emptyRequestID
  case missingBrowserPlan
  case missingCoordinates
  case missingText
  case missingKey
  case missingQuery
  case missingURL

  public var errorDescription: String? {
    switch self {
    case .emptyRequestID: "原生桥接请求缺少 requestID。"
    case .missingBrowserPlan: "浏览器验证请求缺少 plan。"
    case .missingCoordinates: "Computer Use 点击请求必须同时包含 x 和 y。"
    case .missingText: "Computer Use 输入请求缺少 text。"
    case .missingKey: "Computer Use 按键请求缺少 key。"
    case .missingQuery: "Web Search 请求缺少 query。"
    case .missingURL: "Web Fetch 请求缺少 URL。"
    }
  }
}

public struct OpenCodeNativeBridgeRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let operation: OpenCodeNativeBridgeOperation
  public let browserPlan: BrowserVerificationPlan?
  public let artifactsDirectory: String?
  public let x: Double?
  public let y: Double?
  public let text: String?
  public let key: String?
  public let query: String?
  public let maxResults: Int?
  public let url: String?
  public let sourceID: String?
  public let maxCharacters: Int?

  public init(
    requestID: String,
    operation: OpenCodeNativeBridgeOperation,
    browserPlan: BrowserVerificationPlan? = nil,
    artifactsDirectory: String? = nil,
    x: Double? = nil,
    y: Double? = nil,
    text: String? = nil,
    key: String? = nil,
    query: String? = nil,
    maxResults: Int? = nil,
    url: String? = nil,
    sourceID: String? = nil,
    maxCharacters: Int? = nil
  ) {
    self.requestID = requestID
    self.operation = operation
    self.browserPlan = browserPlan
    self.artifactsDirectory = artifactsDirectory
    self.x = x
    self.y = y
    self.text = text
    self.key = key
    self.query = query
    self.maxResults = maxResults
    self.url = url
    self.sourceID = sourceID
    self.maxCharacters = maxCharacters
  }

  public func validate() throws {
    guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OpenCodeNativeBridgeValidationError.emptyRequestID
    }
    switch operation {
    case .webSearch:
      guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OpenCodeNativeBridgeValidationError.missingQuery
      }
    case .webFetch:
      guard let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OpenCodeNativeBridgeValidationError.missingURL
      }
      _ = try WebFetchPolicy.validate(url: url)
    case .browserVerify:
      guard browserPlan != nil else { throw OpenCodeNativeBridgeValidationError.missingBrowserPlan }
    case .computerClick:
      guard x != nil, y != nil else { throw OpenCodeNativeBridgeValidationError.missingCoordinates }
    case .computerTypeText:
      guard let text, !text.isEmpty else { throw OpenCodeNativeBridgeValidationError.missingText }
    case .computerPressKey:
      guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw OpenCodeNativeBridgeValidationError.missingKey
      }
    case .computerInspect, .computerScreenshot:
      break
    }
  }
}

public struct OpenCodeNativeBridgeResponse: Codable, Equatable, Sendable {
  public let requestID: String
  public let ok: Bool
  public let output: String
  public let metadata: [String: String]
  public let browserResult: BrowserVerificationResult?
  public let error: String?

  public init(
    requestID: String,
    ok: Bool,
    output: String = "",
    metadata: [String: String] = [:],
    browserResult: BrowserVerificationResult? = nil,
    error: String? = nil
  ) {
    self.requestID = requestID
    self.ok = ok
    self.output = output
    self.metadata = metadata
    self.browserResult = browserResult
    self.error = error
  }

  public static func failure(requestID: String, error: String) -> OpenCodeNativeBridgeResponse {
    OpenCodeNativeBridgeResponse(requestID: requestID, ok: false, error: error)
  }
}
