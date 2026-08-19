import Foundation

public struct OpenCodeSession: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var title: String?
  public var directory: String?

  public init(id: String, title: String? = nil, directory: String? = nil) {
    self.id = id
    self.title = title
    self.directory = directory
  }
}

public struct CreateSessionInput: Codable, Sendable {
  public let directory: String?
  public let title: String?

  public init(directory: String? = nil, title: String? = nil) {
    self.directory = directory
    self.title = title
  }
}

public struct OpenCodePromptInput: Codable, Sendable {
  public let sessionID: String
  public let text: String
  public let directory: String?

  public init(sessionID: String, text: String, directory: String? = nil) {
    self.sessionID = sessionID
    self.text = text
    self.directory = directory
  }
}

public struct OpenCodeSteerInput: Codable, Sendable {
  public let sessionID: String
  public let text: String
  public let directory: String?

  public init(sessionID: String, text: String, directory: String? = nil) {
    self.sessionID = sessionID
    self.text = text
    self.directory = directory
  }
}

public struct PermissionResponse: Codable, Sendable {
  public let sessionID: String
  public let requestID: String
  public let reply: String
  public let message: String?

  public init(sessionID: String, requestID: String, reply: String, message: String? = nil) {
    self.sessionID = sessionID
    self.requestID = requestID
    self.reply = reply
    self.message = message
  }
}

public protocol OpenCodeSessionClient: Sendable {
  func createSession(_ input: CreateSessionInput) async throws -> OpenCodeSession
  func prompt(_ input: OpenCodePromptInput) async throws
  func steer(_ input: OpenCodeSteerInput) async throws
  func abort(sessionID: String) async throws
  func respondPermission(_ input: PermissionResponse) async throws
  func listSessions(directory: String?) async throws -> [OpenCodeSession]
  func subscribeEvents(sessionID: String) async throws -> AsyncThrowingStream<OpenCodeEvent, Error>
}

public final class URLSessionOpenCodeSessionClient: OpenCodeSessionClient, @unchecked Sendable {
  private let endpoint: OpenCodeRuntimeEndpoint
  private let directory: String?
  private let session: URLSession

  public init(endpoint: OpenCodeRuntimeEndpoint, directory: String? = nil, session: URLSession = .shared) {
    self.endpoint = endpoint
    self.directory = directory
    self.session = session
  }

  public func createSession(_ input: CreateSessionInput) async throws -> OpenCodeSession {
    let body: [String: Any] = [
      "directory": input.directory ?? directory as Any,
      "title": input.title as Any
    ]
    return try await request(path: "/session", method: "POST", body: body)
  }

  public func prompt(_ input: OpenCodePromptInput) async throws {
    let body: [String: Any] = [
      "parts": [["type": "text", "text": input.text]],
      "directory": input.directory ?? directory as Any
    ]
    _ = try await requestData(path: "/session/\(input.sessionID)/prompt_async", method: "POST", body: body)
  }

  public func steer(_ input: OpenCodeSteerInput) async throws {
    try await prompt(OpenCodePromptInput(sessionID: input.sessionID, text: input.text, directory: input.directory))
  }

  public func abort(sessionID: String) async throws {
    _ = try await requestData(path: "/session/\(sessionID)/abort", method: "POST", body: ["directory": directory as Any])
  }

  public func respondPermission(_ input: PermissionResponse) async throws {
    _ = try await requestData(path: "/session/\(input.sessionID)/permissions/\(input.requestID)", method: "POST", body: [
      "response": input.reply,
      "message": input.message as Any,
      "directory": directory as Any
    ])
  }

  public func listSessions(directory: String? = nil) async throws -> [OpenCodeSession] {
    let query = (directory ?? self.directory).map { "?directory=\(Self.escape($0))" } ?? ""
    return try await request(path: "/session\(query)", method: "GET", body: nil)
  }

  public func subscribeEvents(sessionID: String) async throws -> AsyncThrowingStream<OpenCodeEvent, Error> {
    let url = endpoint.baseURL.appendingPathComponent("event")
    var request = URLRequest(url: url)
    request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
    if let directory { request.url = Self.url(url, adding: ["directory": directory]) }
    let eventRequest = request

    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await session.bytes(for: eventRequest)
          guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenCodeRuntimeError.invalidResponse
          }
          var dataLines: [String] = []
          for try await line in bytes.lines {
            if line.hasPrefix("data:") {
              dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.isEmpty, !dataLines.isEmpty {
              let data = Data(dataLines.joined(separator: "\n").utf8)
              if let event = OpenCodeEventBridge.decodeSSEData(data, sessionID: sessionID), event.sessionID == sessionID {
                continuation.yield(event)
              }
              dataLines.removeAll()
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func request<T: Decodable>(path: String, method: String, body: [String: Any]?) async throws -> T {
    let data = try await requestData(path: path, method: method, body: body)
    do { return try JSONDecoder().decode(T.self, from: data) }
    catch { throw OpenCodeRuntimeError.requestFailed("OpenCode 响应解析失败：\(error.localizedDescription)") }
  }

  private func requestData(path: String, method: String, body: [String: Any]?) async throws -> Data {
    guard let url = URL(string: path, relativeTo: endpoint.baseURL)?.absoluteURL else { throw OpenCodeRuntimeError.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw OpenCodeRuntimeError.requestFailed("OpenCode HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
      }
      return data
    } catch let error as OpenCodeRuntimeError {
      throw error
    } catch {
      throw OpenCodeRuntimeError.requestFailed(error.localizedDescription)
    }
  }

  private static func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
  }

  private static func url(_ url: URL, adding values: [String: String]) -> URL {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.url ?? url
  }
}
