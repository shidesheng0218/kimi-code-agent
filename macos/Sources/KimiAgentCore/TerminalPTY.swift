import Darwin
import Foundation

public struct TerminalPTYConfiguration: Sendable {
  public let command: String
  public let interactive: Bool
  public let cwd: URL
  public let shellPath: String
  public let environment: [String: String]
  public let rows: Int
  public let columns: Int
  public let sandbox: TerminalSandboxConfiguration?

  public init(
    command: String,
    cwd: URL,
    shellPath: String = "/bin/zsh",
    environment: [String: String] = [:],
    rows: Int = 32,
    columns: Int = 120,
    interactive: Bool = false,
    sandbox: TerminalSandboxConfiguration? = nil
  ) {
    self.command = command
    self.interactive = interactive
    self.cwd = cwd
    self.shellPath = shellPath
    self.environment = environment
    self.rows = max(2, rows)
    self.columns = max(20, columns)
    self.sandbox = sandbox
  }
}

public struct TerminalPTYOutput: Sendable {
  public let text: String
  public let isError: Bool

  public init(text: String, isError: Bool = false) {
    self.text = text
    self.isError = isError
  }
}

public struct TerminalPTYResult: Sendable {
  public let output: String
  public let exitCode: Int32
  public let timedOut: Bool

  public init(output: String, exitCode: Int32, timedOut: Bool = false) {
    self.output = output
    self.exitCode = exitCode
    self.timedOut = timedOut
  }
}

public final class TerminalPTYHandle: @unchecked Sendable {
  private let process: Process
  private let master: FileHandle
  private let onOutput: ((TerminalPTYOutput) -> Void)?
  private let lock = NSLock()
  private let decoder = TerminalUTF8StreamDecoder()
  private var output = ""
  private var didClose = false

  init(process: Process, master: FileHandle, onOutput: ((TerminalPTYOutput) -> Void)?) {
    self.process = process
    self.master = master
    self.onOutput = onOutput
    master.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.append(data)
    }
  }

  public var isRunning: Bool { process.isRunning }

  public func write(_ input: String) {
    guard let data = input.data(using: .utf8), !data.isEmpty else { return }
    write(data)
  }

  public func write(_ data: Data) {
    guard !data.isEmpty else { return }
    try? master.write(contentsOf: data)
  }

  public func sendControl(_ byte: UInt8) {
    try? master.write(contentsOf: Data([byte]))
  }

  public func resize(rows: Int, columns: Int) {
    var size = winsize(
      ws_row: UInt16(max(2, rows)),
      ws_col: UInt16(max(20, columns)),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
    _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &size)
    if process.isRunning { _ = kill(process.processIdentifier, SIGWINCH) }
  }

  public func terminate() {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    if getpgid(pid) == pid {
      _ = kill(-pid, SIGHUP)
    } else {
      _ = kill(pid, SIGHUP)
    }
    process.terminate()
  }

  public func interrupt() {
    sendControl(3)
  }

  public func wait(timeout: TimeInterval? = nil) -> TerminalPTYResult {
    var timedOut = false
    if let timeout {
      let deadline = Date().addingTimeInterval(max(0.1, timeout))
      while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning {
        timedOut = true
        terminate()
      }
    }
    process.waitUntilExit()
    drain()
    lock.lock()
    let value = output
    let status = process.terminationStatus
    lock.unlock()
    return TerminalPTYResult(output: value, exitCode: status, timedOut: timedOut)
  }

  deinit {
    master.readabilityHandler = nil
    if process.isRunning { terminate() }
    try? master.close()
  }

  private func append(_ data: Data) {
    let text = decoder.append(data)
    guard !text.isEmpty else { return }
    lock.lock()
    output += text
    lock.unlock()
    onOutput?(TerminalPTYOutput(text: text))
  }

  private func drain() {
    master.readabilityHandler = nil
    while true {
      do {
        guard let data = try master.read(upToCount: 65_536), !data.isEmpty else { break }
        append(data)
      } catch {
        // A PTY reports EIO/EAGAIN once the child closes or no bytes remain.
        break
      }
    }
    let remainder = decoder.finish()
    guard !remainder.isEmpty else { return }
    lock.lock()
    output += remainder
    lock.unlock()
    onOutput?(TerminalPTYOutput(text: remainder))
  }
}

public enum TerminalPTYRunner {
  public static func start(
    configuration: TerminalPTYConfiguration,
    onOutput: ((TerminalPTYOutput) -> Void)? = nil
  ) throws -> TerminalPTYHandle {
    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(
      ws_row: UInt16(configuration.rows),
      ws_col: UInt16(configuration.columns),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
    guard openpty(&master, &slave, nil, nil, &size) == 0 else {
      throw NSError(domain: "TerminalPTY", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }

    let inputFD = dup(slave)
    let outputFD = dup(slave)
    let errorFD = dup(slave)
    close(slave)
    guard inputFD >= 0, outputFD >= 0, errorFD >= 0 else {
      close(master)
      throw NSError(domain: "TerminalPTY", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法复制 PTY 从端"])
    }

    let process = Process()
    var environment = ProcessInfo.processInfo.environment.merging(configuration.environment, uniquingKeysWith: { _, new in new })
    let shellArguments = configuration.interactive ? ["-li"] : ["-lc", configuration.command]
    if let sandbox = configuration.sandbox, sandbox.enabled, TerminalSandboxConfiguration.isSupported {
      try FileManager.default.createDirectory(at: sandbox.scratchURL, withIntermediateDirectories: true)
      let profileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-pty-sandbox-\(UUID().uuidString).sb")
      try sandbox.profile().write(to: profileURL, atomically: true, encoding: .utf8)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = ["-f", profileURL.path, configuration.shellPath] + shellArguments
      process.currentDirectoryURL = sandbox.canonicalizedURL(configuration.cwd)
      process.terminationHandler = { _ in try? FileManager.default.removeItem(at: profileURL) }
      environment["HOME"] = sandbox.scratchURL.path
      environment["ZDOTDIR"] = sandbox.scratchURL.path
      environment["HISTFILE"] = "/dev/null"
    } else {
      process.executableURL = URL(fileURLWithPath: configuration.shellPath)
      process.arguments = shellArguments
      process.currentDirectoryURL = configuration.cwd
    }
    process.environment = environment
    process.standardInput = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
    process.standardOutput = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
    process.standardError = FileHandle(fileDescriptor: errorFD, closeOnDealloc: true)

    do {
      try process.run()
    } catch {
      close(master)
      throw error
    }

    // Make the shell a process-group leader when the platform permits it so Ctrl-C/close can clean up
    // interactive children such as vim, top and pagers as one unit.
    _ = setpgid(process.processIdentifier, process.processIdentifier)

    let handle = TerminalPTYHandle(
      process: process,
      master: FileHandle(fileDescriptor: master, closeOnDealloc: true),
      onOutput: onOutput
    )
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    handle.resize(rows: configuration.rows, columns: configuration.columns)
    return handle
  }
}
