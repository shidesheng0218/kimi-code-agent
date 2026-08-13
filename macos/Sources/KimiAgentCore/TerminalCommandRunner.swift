import Foundation

/// Decodes terminal bytes without replacing or dropping a Unicode scalar when
/// the PTY/pipe splits it across reads. `String(data:, encoding:)` returns
/// nil for those partial chunks, which used to make Chinese and Emoji vanish
/// from the transcript.
public final class TerminalUTF8StreamDecoder: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()

  public init() {}

  public func append(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }
    lock.lock()
    pending.append(data)
    let completeLength = Self.completePrefixLength(in: pending)
    guard completeLength > 0 else {
      lock.unlock()
      return ""
    }
    let complete = pending.prefix(completeLength)
    pending.removeFirst(completeLength)
    lock.unlock()
    return String(decoding: complete, as: UTF8.self)
  }

  /// Flushes a final invalid fragment as replacement characters after the
  /// underlying stream closes. Normal streaming never loses an incomplete
  /// suffix merely because the process happened to exit between reads.
  public func finish() -> String {
    lock.lock()
    let remainder = pending
    pending.removeAll(keepingCapacity: false)
    lock.unlock()
    return String(decoding: remainder, as: UTF8.self)
  }

  private static func completePrefixLength(in data: Data) -> Int {
    let bytes = Array(data)
    guard !bytes.isEmpty else { return 0 }

    var continuationCount = 0
    var cursor = bytes.count
    while cursor > 0, bytes[cursor - 1] & 0b1100_0000 == 0b1000_0000 {
      continuationCount += 1
      cursor -= 1
    }

    let leadingIndex: Int
    if continuationCount == 0 {
      leadingIndex = bytes.count - 1
    } else {
      // A stream ending only in continuation bytes is malformed rather than
      // an incomplete scalar, so return it to the replacement decoder.
      guard cursor > 0 else { return bytes.count }
      leadingIndex = cursor - 1
    }

    let leadingByte = bytes[leadingIndex]
    let scalarLength: Int?
    switch leadingByte {
    case 0xC2...0xDF: scalarLength = 2
    case 0xE0...0xEF: scalarLength = 3
    case 0xF0...0xF4: scalarLength = 4
    default: scalarLength = nil
    }
    guard let scalarLength else { return bytes.count }

    let observedLength = bytes.count - leadingIndex
    return observedLength < scalarLength ? leadingIndex : bytes.count
  }
}

public struct TerminalProcessOutput: Sendable {
  public let stream: TerminalOutputStream
  public let text: String

  public init(stream: TerminalOutputStream, text: String) {
    self.stream = stream
    self.text = text
  }
}

public struct TerminalCommandResult: Sendable {
  public let standardOutput: String
  public let standardError: String
  public let exitCode: Int32

  public init(standardOutput: String, standardError: String, exitCode: Int32) {
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.exitCode = exitCode
  }
}

public final class TerminalCommandHandle: @unchecked Sendable {
  private let process: Process
  private let stdin: Pipe
  private let stdout: Pipe
  private let stderr: Pipe
  private let onOutput: ((TerminalProcessOutput) -> Void)?
  private let lock = NSLock()
  private let standardOutputDecoder = TerminalUTF8StreamDecoder()
  private let standardErrorDecoder = TerminalUTF8StreamDecoder()
  private var standardOutput = ""
  private var standardError = ""

  init(process: Process, stdin: Pipe, stdout: Pipe, stderr: Pipe, onOutput: ((TerminalProcessOutput) -> Void)?) {
    self.process = process
    self.stdin = stdin
    self.stdout = stdout
    self.stderr = stderr
    self.onOutput = onOutput
    observe(stdout.fileHandleForReading, stream: .standardOutput)
    observe(stderr.fileHandleForReading, stream: .standardError)
  }

  public var isRunning: Bool { process.isRunning }

  public func write(_ input: String) {
    guard process.isRunning, let data = input.data(using: .utf8) else { return }
    stdin.fileHandleForWriting.write(data)
  }

  public func closeStandardInput() {
    try? stdin.fileHandleForWriting.close()
  }

  public func terminate() {
    if process.isRunning { process.terminate() }
  }

  public func wait() -> TerminalCommandResult {
    process.waitUntilExit()
    drain(stdout.fileHandleForReading, stream: .standardOutput)
    drain(stderr.fileHandleForReading, stream: .standardError)
    flush(stream: .standardOutput)
    flush(stream: .standardError)
    lock.lock()
    defer { lock.unlock() }
    return TerminalCommandResult(standardOutput: standardOutput, standardError: standardError, exitCode: process.terminationStatus)
  }

  private func observe(_ handle: FileHandle, stream: TerminalOutputStream) {
    handle.readabilityHandler = { [weak self] file in
      let data = file.availableData
      guard !data.isEmpty else {
        file.readabilityHandler = nil
        return
      }
      self?.append(data, stream: stream)
    }
  }

  private func drain(_ handle: FileHandle, stream: TerminalOutputStream) {
    handle.readabilityHandler = nil
    let data = handle.readDataToEndOfFile()
    if !data.isEmpty { append(data, stream: stream) }
  }

  private func append(_ data: Data, stream: TerminalOutputStream) {
    let text = decoder(for: stream).append(data)
    guard !text.isEmpty else { return }
    lock.lock()
    switch stream {
    case .standardOutput: standardOutput += text
    case .standardError: standardError += text
    }
    lock.unlock()
    onOutput?(TerminalProcessOutput(stream: stream, text: text))
  }

  private func flush(stream: TerminalOutputStream) {
    let text = decoder(for: stream).finish()
    guard !text.isEmpty else { return }
    lock.lock()
    switch stream {
    case .standardOutput: standardOutput += text
    case .standardError: standardError += text
    }
    lock.unlock()
    onOutput?(TerminalProcessOutput(stream: stream, text: text))
  }

  private func decoder(for stream: TerminalOutputStream) -> TerminalUTF8StreamDecoder {
    switch stream {
    case .standardOutput: standardOutputDecoder
    case .standardError: standardErrorDecoder
    }
  }
}

public enum TerminalCommandRunner {
  public static func start(
    command: String,
    cwd: URL,
    environment: [String: String] = [:],
    input: String? = nil,
    sandbox: TerminalSandboxConfiguration? = nil,
    onOutput: ((TerminalProcessOutput) -> Void)? = nil
  ) throws -> TerminalCommandHandle {
    let process = Process()
    var effectiveEnvironment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })
    if let sandbox, sandbox.enabled, TerminalSandboxConfiguration.isSupported {
      try FileManager.default.createDirectory(at: sandbox.scratchURL, withIntermediateDirectories: true)
      let profileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-sandbox-\(UUID().uuidString).sb")
      try sandbox.profile().write(to: profileURL, atomically: true, encoding: .utf8)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
      process.arguments = ["-f", profileURL.path, "/bin/zsh", "-lc", command]
      process.terminationHandler = { _ in try? FileManager.default.removeItem(at: profileURL) }
      effectiveEnvironment["HOME"] = sandbox.scratchURL.path
      effectiveEnvironment["ZDOTDIR"] = sandbox.scratchURL.path
      effectiveEnvironment["HISTFILE"] = "/dev/null"
    } else {
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-lc", command]
    }
    process.currentDirectoryURL = cwd
    process.environment = effectiveEnvironment

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let handle = TerminalCommandHandle(process: process, stdin: stdin, stdout: stdout, stderr: stderr, onOutput: onOutput)
    if let input, !input.isEmpty { handle.write(input) }
    handle.closeStandardInput()
    return handle
  }

  public static func run(command: String, cwd: URL, environment: [String: String] = [:], input: String? = nil) throws -> TerminalCommandResult {
    try start(command: command, cwd: cwd, environment: environment, input: input).wait()
  }

  public static func run(
    command: String,
    cwd: URL,
    environment: [String: String] = [:],
    input: String? = nil,
    sandbox: TerminalSandboxConfiguration?
  ) throws -> TerminalCommandResult {
    try start(command: command, cwd: cwd, environment: environment, input: input, sandbox: sandbox).wait()
  }
}
