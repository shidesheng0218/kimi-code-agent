import Foundation

public enum PluginWorkerState: String, Codable, CaseIterable, Sendable {
  case registered
  case starting
  case running
  case reconnecting
  case failed
  case stopped
}

public struct PluginWorkerStatus: Codable, Equatable, Sendable {
  public let pluginID: String
  public var state: PluginWorkerState
  public var restartCount: Int
  public var lastError: String?
  public var protocolVersion: String?
  public var capabilities: [String]
  public var updatedAt: Date

  public init(
    pluginID: String,
    state: PluginWorkerState = .registered,
    restartCount: Int = 0,
    lastError: String? = nil,
    protocolVersion: String? = nil,
    capabilities: [String] = [],
    updatedAt: Date = .now
  ) {
    self.pluginID = pluginID
    self.state = state
    self.restartCount = restartCount
    self.lastError = lastError
    self.protocolVersion = protocolVersion
    self.capabilities = Array(Set(capabilities)).sorted()
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case pluginID, state, restartCount, lastError, protocolVersion, capabilities, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      pluginID: try container.decode(String.self, forKey: .pluginID),
      state: try container.decodeIfPresent(PluginWorkerState.self, forKey: .state) ?? .registered,
      restartCount: try container.decodeIfPresent(Int.self, forKey: .restartCount) ?? 0,
      lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
      protocolVersion: try container.decodeIfPresent(String.self, forKey: .protocolVersion),
      capabilities: try container.decodeIfPresent([String].self, forKey: .capabilities) ?? [],
      updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    )
  }
}

public enum PluginWorkerError: LocalizedError, Equatable {
  case missingWorker(URL)
  case unknownPlugin(String)
  case restartLimitReached(String)
  case notRunning(String)
  case handshakeTimeout(String)

  public var errorDescription: String? {
    switch self {
    case let .missingWorker(url): "插件 Worker 不存在：\(url.path)"
    case let .unknownPlugin(id): "找不到插件：\(id)"
    case let .restartLimitReached(id): "插件 Worker 已达到最大重启次数：\(id)"
    case let .notRunning(id): "插件 Worker 尚未运行：\(id)"
    case let .handshakeTimeout(id): "插件 Worker 握手超时：\(id)"
    }
  }
}

/// Owns plugin process handles and lifecycle state. The process protocol is
/// intentionally narrow: plugins may expose JSON-RPC on their stdio, but they
/// never receive a SwiftUI reference or an unscoped capability.
public actor PluginWorkerSupervisor {
  private var plugins: [String: KimiPluginDescriptor] = [:]
  private var statuses: [String: PluginWorkerStatus] = [:]
  private var processes: [String: Process] = [:]
  private var inputHandles: [String: FileHandle] = [:]
  private var outputHandles: [String: FileHandle] = [:]
  private let maxRestarts: Int
  private let stateFileURL: URL?

  public init(maxRestarts: Int = 3, stateFileURL: URL? = nil) {
    self.maxRestarts = max(0, maxRestarts)
    self.stateFileURL = stateFileURL
    if let stateFileURL,
       let data = try? Data(contentsOf: stateFileURL),
       let values = try? JSONDecoder().decode([PluginWorkerStatus].self, from: data) {
      self.statuses = Dictionary(uniqueKeysWithValues: values.map { ($0.pluginID, $0) })
    }
  }

  public func register(_ plugin: KimiPluginDescriptor) {
    plugins[plugin.id] = plugin
    if statuses[plugin.id] == nil {
      statuses[plugin.id] = PluginWorkerStatus(pluginID: plugin.id)
    }
    persistStatuses()
  }

  public func start(
    pluginID: String,
    nodeExecutable: String = "node",
    sandbox: TerminalSandboxConfiguration? = nil
  ) throws {
    guard let plugin = plugins[pluginID] else { throw PluginWorkerError.unknownPlugin(pluginID) }
    let workerURL = plugin.rootURL.appendingPathComponent(".kimi-plugin/worker.js")
    guard FileManager.default.fileExists(atPath: workerURL.path) else { throw PluginWorkerError.missingWorker(workerURL) }
    if let process = processes[pluginID], process.isRunning { return }
    var status = statuses[pluginID] ?? PluginWorkerStatus(pluginID: pluginID)
    status.state = .starting
    status.updatedAt = .now
    statuses[pluginID] = status
    persistStatuses()

    let process = Process()
    let effectiveSandbox = sandbox ?? TerminalSandboxConfiguration.strict(
      workspaceURL: plugin.rootURL,
      scratchURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-plugin-worker-\(plugin.id)-\(UUID().uuidString)", isDirectory: true)
    )
    var environment = ProcessInfo.processInfo.environment
    if effectiveSandbox.enabled, TerminalSandboxConfiguration.isSupported {
      try FileManager.default.createDirectory(at: effectiveSandbox.scratchURL, withIntermediateDirectories: true)
      let profileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-plugin-worker-\(UUID().uuidString).sb")
      try effectiveSandbox.profile().write(to: profileURL, atomically: true, encoding: .utf8)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = ["-f", profileURL.path, "/usr/bin/env", nodeExecutable, workerURL.path]
      process.currentDirectoryURL = effectiveSandbox.canonicalizedURL(plugin.rootURL)
      environment["HOME"] = effectiveSandbox.scratchURL.path
      environment["ZDOTDIR"] = effectiveSandbox.scratchURL.path
      environment["HISTFILE"] = "/dev/null"
      process.terminationHandler = { [weak self] process in
        try? FileManager.default.removeItem(at: profileURL)
        guard let self else { return }
        Task { await self.handleTermination(pluginID: pluginID, status: process.terminationStatus) }
      }
    } else {
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [nodeExecutable, workerURL.path]
      process.currentDirectoryURL = plugin.rootURL
      process.terminationHandler = { [weak self] process in
        guard let self else { return }
        Task { await self.handleTermination(pluginID: pluginID, status: process.terminationStatus) }
      }
    }
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      processes[pluginID] = process
      inputHandles[pluginID] = input.fileHandleForWriting
      outputHandles[pluginID] = output.fileHandleForReading
      status.state = .running
      status.updatedAt = .now
      statuses[pluginID] = status
      persistStatuses()
    } catch {
      status.state = .failed
      status.lastError = error.localizedDescription
      statuses[pluginID] = status
      persistStatuses()
      throw error
    }
  }

  /// Performs a scoped JSON-RPC initialize exchange after the sandboxed
  /// process is running. The worker only declares capabilities; it never
  /// receives an unrestricted host object or permission grant.
  public func performHandshake(
    pluginID: String,
    requiredCapabilities: Set<String> = [],
    timeoutSeconds: TimeInterval = 3
  ) async throws -> PluginWorkerHandshake {
    guard processes[pluginID]?.isRunning == true,
          let input = inputHandles[pluginID],
          let output = outputHandles[pluginID] else {
      throw PluginWorkerError.notRunning(pluginID)
    }
    do {
      try input.write(contentsOf: PluginWorkerProtocol.initializeRequest())
      let data = try await readHandshakeLine(from: output, timeoutSeconds: timeoutSeconds)
      let handshake = try PluginWorkerProtocol.decodeHandshake(
        data,
        requiredCapabilities: requiredCapabilities
      )
      var status = statuses[pluginID] ?? PluginWorkerStatus(pluginID: pluginID)
      status.state = .running
      status.lastError = nil
      status.protocolVersion = handshake.protocolVersion
      status.capabilities = handshake.capabilities
      status.updatedAt = .now
      statuses[pluginID] = status
      persistStatuses()
      return handshake
    } catch {
      try? markFailure(pluginID: pluginID, message: error.localizedDescription)
      throw error
    }
  }

  public func stop(pluginID: String) {
    processes.removeValue(forKey: pluginID)?.terminate()
    inputHandles.removeValue(forKey: pluginID)
    outputHandles.removeValue(forKey: pluginID)
    var status = statuses[pluginID] ?? PluginWorkerStatus(pluginID: pluginID)
    status.state = .stopped
    status.updatedAt = .now
    statuses[pluginID] = status
    persistStatuses()
  }

  public func markFailure(pluginID: String, message: String) throws {
    var status = statuses[pluginID] ?? PluginWorkerStatus(pluginID: pluginID)
    guard status.restartCount < maxRestarts else {
      status.state = .failed
      status.lastError = message
      statuses[pluginID] = status
      persistStatuses()
      throw PluginWorkerError.restartLimitReached(pluginID)
    }
    status.restartCount += 1
    status.state = .reconnecting
    status.lastError = message
    status.updatedAt = .now
    statuses[pluginID] = status
    persistStatuses()
  }

  public func state(pluginID: String) -> PluginWorkerState? { statuses[pluginID]?.state }

  public func status(pluginID: String) -> PluginWorkerStatus? { statuses[pluginID] }

  public func snapshot() -> [PluginWorkerStatus] {
    statuses.values.sorted { $0.pluginID < $1.pluginID }
  }

  private func handleTermination(pluginID: String, status terminationStatus: Int32) {
    processes.removeValue(forKey: pluginID)
    inputHandles.removeValue(forKey: pluginID)
    outputHandles.removeValue(forKey: pluginID)
    guard var status = statuses[pluginID], status.state != .stopped else { return }
    status.state = terminationStatus == 0 ? .stopped : .failed
    if terminationStatus != 0 { status.lastError = "Worker exit \(terminationStatus)" }
    status.updatedAt = .now
    statuses[pluginID] = status
    persistStatuses()
  }

  private func persistStatuses() {
    guard let stateFileURL,
          let data = try? JSONEncoder().encode(statuses.values.sorted { $0.pluginID < $1.pluginID }) else { return }
    try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: stateFileURL, options: .atomic)
  }

  private func readHandshakeLine(from output: FileHandle, timeoutSeconds: TimeInterval) async throws -> Data {
    try await PluginWorkerHandshakeReader.read(from: output, timeoutSeconds: timeoutSeconds)
  }
}

private final class PluginWorkerHandshakeReader: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data, Error>?
  private var settled = false
  private weak var output: FileHandle?

  static func read(from output: FileHandle, timeoutSeconds: TimeInterval) async throws -> Data {
    let reader = PluginWorkerHandshakeReader(output: output)
    return try await withCheckedThrowingContinuation { continuation in
      reader.lock.lock()
      reader.continuation = continuation
      reader.lock.unlock()
      output.readabilityHandler = { [weak reader] handle in
        let data = handle.availableData
        guard let reader else { return }
        if data.isEmpty {
          reader.finish(.failure(PluginWorkerProtocolError.malformedResponse))
          return
        }
        let line = Data(data.prefix(while: { $0 != 0x0A }))
        reader.finish(.success(line))
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeoutSeconds) * 1_000_000_000))
        reader.finish(.failure(PluginWorkerError.handshakeTimeout("worker")))
      }
    }
  }

  private init(output: FileHandle) {
    self.output = output
  }

  private func finish(_ result: Result<Data, Error>) {
    lock.lock()
    guard !settled, let continuation else {
      lock.unlock()
      return
    }
    settled = true
    self.continuation = nil
    let output = self.output
    lock.unlock()
    output?.readabilityHandler = nil
    continuation.resume(with: result)
  }
}
