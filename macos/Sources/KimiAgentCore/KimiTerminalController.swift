import Foundation

private final class KimiTerminalOutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = ""

  func append(_ text: String) {
    guard !text.isEmpty else { return }
    lock.lock()
    value.append(text)
    if value.count > 200_000 {
      value = "…(较早终端输出已截断)\n" + String(value.suffix(200_000))
    }
    lock.unlock()
  }

  func snapshot() -> String {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Owns native PTYs for the right-hand terminal pane.  UI code only sees an
/// opaque tab ID and never touches `Process` or `FileHandle` directly.
public actor KimiTerminalController {
  private var handles: [UUID: TerminalPTYHandle] = [:]
  private var outputs: [UUID: KimiTerminalOutputBox] = [:]

  public init() {}

  @discardableResult
  public func open(
    cwd: URL,
    shellPath: String = "/bin/zsh",
    rows: Int = 32,
    columns: Int = 120
  ) throws -> UUID {
    let id = UUID()
    let box = KimiTerminalOutputBox()
    let handle = try TerminalPTYRunner.start(
      configuration: TerminalPTYConfiguration(
        command: "",
        cwd: cwd,
        shellPath: shellPath,
        rows: rows,
        columns: columns,
        interactive: true
      ),
      onOutput: { output in box.append(output.text) }
    )
    handles[id] = handle
    outputs[id] = box
    return id
  }

  public func write(_ input: String, to id: UUID) throws {
    guard let handle = handles[id] else { throw KimiTerminalError.missingSession(id) }
    guard handle.isRunning else { throw KimiTerminalError.notRunning(id) }
    handle.write(input)
  }

  public func resize(_ metrics: TerminalViewportMetrics, for id: UUID) throws {
    guard let handle = handles[id] else { throw KimiTerminalError.missingSession(id) }
    handle.resize(rows: metrics.rows, columns: metrics.columns)
  }

  public func output(for id: UUID) -> String {
    outputs[id]?.snapshot() ?? ""
  }

  public func waitForOutput(contains needle: String, in id: UUID, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    while Date() < deadline {
      if output(for: id).contains(needle) { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return output(for: id).contains(needle)
  }

  public func close(_ id: UUID) {
    handles[id]?.terminate()
    handles.removeValue(forKey: id)
    outputs.removeValue(forKey: id)
  }

  public func closeAll() {
    for handle in handles.values { handle.terminate() }
    handles.removeAll()
    outputs.removeAll()
  }
}

public enum KimiTerminalError: LocalizedError, Equatable, Sendable {
  case missingSession(UUID)
  case notRunning(UUID)

  public var errorDescription: String? {
    switch self {
    case let .missingSession(id): "找不到终端会话：\(id.uuidString)"
    case let .notRunning(id): "终端会话已停止：\(id.uuidString)"
    }
  }
}
