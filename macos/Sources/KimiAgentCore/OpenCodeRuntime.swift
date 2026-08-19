import Foundation

public struct OpenCodeRuntimeEndpoint: Codable, Equatable, Sendable {
  public let host: String
  public let port: Int
  public let token: String

  public init(host: String = "127.0.0.1", port: Int, token: String) {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    self.host = ["127.0.0.1", "localhost", "::1"].contains(normalizedHost.lowercased()) ? normalizedHost : "127.0.0.1"
    self.port = min(max(port, 1), 65_535)
    self.token = token
  }

  public var baseURL: URL {
    URL(string: "http://\(host):\(port)")!
  }

  public var authorizationHeader: String {
    let credentials = Data("opencode:\(token)".utf8).base64EncodedString()
    return "Basic \(credentials)"
  }
}

public struct OpenCodeRuntimeConfiguration: Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectory: URL?
  public let environment: [String: String]
  public let endpoint: OpenCodeRuntimeEndpoint
  public let healthTimeout: TimeInterval
  public let restartLimit: Int
  public let restartDelay: TimeInterval

  public init(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String] = [:],
    endpoint: OpenCodeRuntimeEndpoint,
    healthTimeout: TimeInterval = 30,
    restartLimit: Int = 3,
    restartDelay: TimeInterval = 0.5
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.endpoint = endpoint
    self.healthTimeout = min(max(healthTimeout, 1), 120)
    self.restartLimit = min(max(restartLimit, 0), 10)
    self.restartDelay = min(max(restartDelay, 0.01), 30)
  }
}

public enum OpenCodeRuntimeError: LocalizedError, Equatable, Sendable {
  case alreadyRunning
  case notRunning
  case healthTimeout(URL)
  case invalidResponse
  case requestFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning: "OpenCode 后台运行时已经在运行。"
    case .notRunning: "OpenCode 后台运行时尚未启动。"
    case let .healthTimeout(url): "OpenCode 后台运行时未在规定时间内就绪：\(url.absoluteString)"
    case .invalidResponse: "OpenCode 后台运行时返回了无效响应。"
    case let .requestFailed(message): message
    }
  }
}

/// Owns the OpenCode server process without exposing Process management to the
/// SwiftUI layer. The production bundle supplies the executable and runtime;
/// development may point this at a local Bun/Node command.
public actor OpenCodeRuntimeSupervisor {
  private let configuration: OpenCodeRuntimeConfiguration
  private var process: KimiProcessHandle?
  private var state: KimiRuntimeState = .stopped
  private var monitorTask: Task<Void, Never>?
  private var intentionalStop = false
  private var unexpectedExitRestarts = 0

  public init(configuration: OpenCodeRuntimeConfiguration) {
    self.configuration = configuration
  }

  public func snapshot() -> (state: KimiRuntimeState, endpoint: OpenCodeRuntimeEndpoint) {
    (state, configuration.endpoint)
  }

  public func start() throws -> OpenCodeRuntimeEndpoint {
    try launch(resetRestartCount: true)
  }

  public func unexpectedExitRestartCount() -> Int {
    unexpectedExitRestarts
  }

  private func launch(resetRestartCount: Bool) throws -> OpenCodeRuntimeEndpoint {
    guard process?.isRunning != true else { throw OpenCodeRuntimeError.alreadyRunning }
    if resetRestartCount { unexpectedExitRestarts = 0 }
    intentionalStop = false
    state = .starting
    let command = KimiCommand(executableURL: configuration.executableURL, arguments: configuration.arguments)
    do {
      process = try KimiProcessRunner.start(
        command,
        workingDirectory: configuration.workingDirectory,
        environment: configuration.environment
      )
      if let process { beginMonitoring(process) }
      return configuration.endpoint
    } catch {
      state = .failed
      throw error
    }
  }

  public func markReady() {
    guard process?.isRunning == true else { return }
    state = .ready
  }

  public func markDegraded() {
    guard process?.isRunning == true else { return }
    state = .degraded
  }

  public func stop() {
    intentionalStop = true
    monitorTask?.cancel()
    monitorTask = nil
    guard let process else {
      state = .stopped
      return
    }
    state = .stopping
    process.terminate()
    self.process = nil
    state = .stopped
  }

  public func restart() throws -> OpenCodeRuntimeEndpoint {
    stop()
    return try start()
  }

  public func waitUntilReady() async throws {
    guard process?.isRunning == true else { throw OpenCodeRuntimeError.notRunning }
    let deadline = Date().addingTimeInterval(configuration.healthTimeout)
    while Date() < deadline {
      if await Self.isHealthy(configuration.endpoint) {
        state = .ready
        return
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    state = .degraded
    throw OpenCodeRuntimeError.healthTimeout(configuration.endpoint.baseURL)
  }

  private static func isHealthy(_ endpoint: OpenCodeRuntimeEndpoint) async -> Bool {
    for path in ["/global/health", "/api/health"] {
      guard let url = URL(string: path, relativeTo: endpoint.baseURL)?.absoluteURL else { continue }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue(endpoint.authorizationHeader, forHTTPHeaderField: "Authorization")
      request.timeoutInterval = 2
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
          return true
        }
      } catch {}
    }
    return false
  }

  private func beginMonitoring(_ handle: KimiProcessHandle) {
    monitorTask?.cancel()
    let pid = handle.processIdentifier
    monitorTask = Task { [weak self] in
      guard let self else { return }
      await self.monitorUnexpectedExit(processID: pid)
    }
  }

  private func monitorUnexpectedExit(processID: Int32) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(50))
      guard let current = process, current.processIdentifier == processID else { return }
      guard !current.isRunning else { continue }
      guard !intentionalStop else { return }
      guard unexpectedExitRestarts < configuration.restartLimit else {
        state = .failed
        return
      }
      unexpectedExitRestarts += 1
      state = .starting
      try? await Task.sleep(for: .seconds(configuration.restartDelay))
      guard !Task.isCancelled, !intentionalStop else { return }
      do {
        _ = try launch(resetRestartCount: false)
      } catch {
        state = .failed
      }
      return
    }
  }
}
