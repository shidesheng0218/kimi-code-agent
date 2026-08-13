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
  public var updatedAt: Date

  public init(pluginID: String, state: PluginWorkerState = .registered, restartCount: Int = 0, lastError: String? = nil, updatedAt: Date = .now) {
    self.pluginID = pluginID
    self.state = state
    self.restartCount = restartCount
    self.lastError = lastError
    self.updatedAt = updatedAt
  }
}

public enum PluginWorkerError: LocalizedError, Equatable {
  case missingWorker(URL)
  case unknownPlugin(String)
  case restartLimitReached(String)

  public var errorDescription: String? {
    switch self {
    case let .missingWorker(url): "插件 Worker 不存在：\(url.path)"
    case let .unknownPlugin(id): "找不到插件：\(id)"
    case let .restartLimitReached(id): "插件 Worker 已达到最大重启次数：\(id)"
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
  private let maxRestarts: Int

  public init(maxRestarts: Int = 3) {
    self.maxRestarts = max(0, maxRestarts)
  }

  public func register(_ plugin: KimiPluginDescriptor) {
    plugins[plugin.id] = plugin
    if statuses[plugin.id] == nil {
      statuses[plugin.id] = PluginWorkerStatus(pluginID: plugin.id)
    }
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
    process.standardInput = Pipe()
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
      processes[pluginID] = process
      status.state = .running
      status.updatedAt = .now
      statuses[pluginID] = status
    } catch {
      status.state = .failed
      status.lastError = error.localizedDescription
      statuses[pluginID] = status
      throw error
    }
  }

  public func stop(pluginID: String) {
    processes.removeValue(forKey: pluginID)?.terminate()
    var status = statuses[pluginID] ?? PluginWorkerStatus(pluginID: pluginID)
    status.state = .stopped
    status.updatedAt = .now
    statuses[pluginID] = status
  }

  public func markFailure(pluginID: String, message: String) throws {
    var status = statuses[pluginID] ?? PluginWorkerStatus(pluginID: pluginID)
    guard status.restartCount < maxRestarts else {
      status.state = .failed
      status.lastError = message
      statuses[pluginID] = status
      throw PluginWorkerError.restartLimitReached(pluginID)
    }
    status.restartCount += 1
    status.state = .reconnecting
    status.lastError = message
    status.updatedAt = .now
    statuses[pluginID] = status
  }

  public func state(pluginID: String) -> PluginWorkerState? { statuses[pluginID]?.state }

  public func status(pluginID: String) -> PluginWorkerStatus? { statuses[pluginID] }

  public func snapshot() -> [PluginWorkerStatus] {
    statuses.values.sorted { $0.pluginID < $1.pluginID }
  }

  private func handleTermination(pluginID: String, status terminationStatus: Int32) {
    processes.removeValue(forKey: pluginID)
    guard var status = statuses[pluginID], status.state != .stopped else { return }
    status.state = terminationStatus == 0 ? .stopped : .failed
    if terminationStatus != 0 { status.lastError = "Worker exit \(terminationStatus)" }
    status.updatedAt = .now
    statuses[pluginID] = status
  }
}
