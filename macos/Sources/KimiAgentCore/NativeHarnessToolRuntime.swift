import Darwin
import Foundation

public enum NativeHarnessToolError: LocalizedError, Equatable {
  case invalidPath(String)
  case outsideWorkspace(String)
  case missingInput(String)
  case unsupportedTool(String)
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case let .invalidPath(path): "无效路径：\(path)"
    case let .outsideWorkspace(path): "路径不在当前工作区内：\(path)"
    case let .missingInput(key): "工具缺少参数：\(key)"
    case let .unsupportedTool(id): "Native Harness 尚未支持工具：\(id)"
    case let .commandFailed(message): message
    }
  }
}

/// Harness-owned local tool runtime. It deliberately enforces the workspace
/// boundary before dispatching any filesystem or shell side effect.
public final class NativeHarnessToolRuntime: ToolExecutor, @unchecked Sendable {
  public typealias SpecializedToolHandler = @Sendable (ToolExecutionRequest) async throws -> ToolExecutionResult

  public let workspaceURL: URL
  private let fileManager: FileManager
  private let browserHandler: SpecializedToolHandler?
  private let computerUseHandler: SpecializedToolHandler?
  private let mcpHandler: SpecializedToolHandler?

  /// Browser, MCP, and Computer Use execute outside the Core target (WKWebView,
  /// system accessibility APIs, and MCP workers respectively). The concrete
  /// adapters are injected here so all calls still use this single Harness
  /// runtime and therefore pass through ToolExecutionCoordinator's permission,
  /// intent, receipt, cancellation, and recovery boundaries.
  public init(
    workspaceURL: URL,
    fileManager: FileManager = .default,
    browserHandler: SpecializedToolHandler? = nil,
    computerUseHandler: SpecializedToolHandler? = nil,
    mcpHandler: SpecializedToolHandler? = nil
  ) {
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.fileManager = fileManager
    self.browserHandler = browserHandler
    self.computerUseHandler = computerUseHandler
    self.mcpHandler = mcpHandler
  }

  public static func webFetchExitCode(for status: Int) -> Int32 {
    (200..<300).contains(status) ? 0 : Int32(status)
  }

  public func execute(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    switch request.toolID {
    case "read", "read_file":
      return try read(request)
    case "search", "search_code":
      return try search(request)
    case "write", "write_file":
      return try write(request)
    case "shell", "run_shell":
      return try await shell(request)
    case "web.fetch", "web_fetch", "network.fetch":
      return try await fetch(request)
    case "browser":
      return try await executeSpecialized(request, handler: browserHandler)
    case "computer_use.inspect", "computer_use.screenshot", "computer_use.click", "computer_use.click_element", "computer_use.type_text", "computer_use.press_key":
      return try await executeSpecialized(request, handler: computerUseHandler)
    case "mcp":
      return try await executeSpecialized(request, handler: mcpHandler)
    default:
      if request.toolID.hasPrefix("mcp.") {
        return try await executeSpecialized(request, handler: mcpHandler)
      }
      throw NativeHarnessToolError.unsupportedTool(request.toolID)
    }
  }

  private func executeSpecialized(
    _ request: ToolExecutionRequest,
    handler: SpecializedToolHandler?
  ) async throws -> ToolExecutionResult {
    guard let handler else {
      throw NativeHarnessToolError.unsupportedTool(request.toolID)
    }
    return try await handler(request)
  }

  private func read(_ request: ToolExecutionRequest) throws -> ToolExecutionResult {
    let path = try input(request, key: "path")
    let url = try resolve(path)
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let content = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    return ToolExecutionResult(output: content, metadata: ["path": url.path, "bytes": String(data.count)])
  }

  private func search(_ request: ToolExecutionRequest) throws -> ToolExecutionResult {
    let query = try input(request, key: "query")
    let root = try resolve(request.input["path"] ?? ".")
    var matches: [String] = []
    guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
      return ToolExecutionResult(output: "", metadata: ["count": "0"])
    }
    for case let url as URL in enumerator {
      if matches.count >= 200 { break }
      if url.path.contains("/node_modules/") || url.path.contains("/.git/") { enumerator.skipDescendants(); continue }
      guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true else { continue }
      guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(query) else { continue }
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() where line.localizedCaseInsensitiveContains(query) {
        matches.append("\(url.path):\(index + 1):\(line)")
        if matches.count >= 200 { break }
      }
    }
    return ToolExecutionResult(output: matches.joined(separator: "\n"), metadata: ["count": String(matches.count)])
  }

  private func write(_ request: ToolExecutionRequest) throws -> ToolExecutionResult {
    let path = try input(request, key: "path")
    let content = try input(request, key: "content")
    let url = try resolve(path)
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url, options: .atomic)
    return ToolExecutionResult(output: "已写入 \(url.path)", metadata: ["path": url.path, "bytes": String(content.utf8.count)])
  }

  private func shell(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    let command = try input(request, key: "command")
    let cwd = try resolve(request.input["cwd"] ?? ".")
    // Agent shell execution is always protected by the same OS-level
    // boundary as queued terminal commands.  The Harness permission gate
    // remains the first line of defense; Seatbelt prevents a compromised
    // command or tool process from writing outside this Worktree and blocks
    // network access unless a future explicitly network-scoped executor is
    // used.  User-facing interactive terminals keep their normal PTY UX.
    let scratchURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kimi-harness-shell-\(request.id.uuidString)", isDirectory: true)
    let sandbox = TerminalSandboxConfiguration.strict(
      workspaceURL: workspaceURL,
      scratchURL: scratchURL,
      allowNetwork: false
    )
    do {
      let handle = try TerminalCommandRunner.start(
        command: command,
        cwd: cwd,
        sandbox: sandbox
      )
      let result = await Task.detached(priority: .userInitiated) {
        handle.wait()
      }.value
      try? fileManager.removeItem(at: scratchURL)
      return ToolExecutionResult(
        output: result.standardOutput + (result.standardError.isEmpty ? "" : "\n" + result.standardError),
        metadata: ["stderr": result.standardError, "sandbox": sandbox.enabled && TerminalSandboxConfiguration.isSupported ? "seatbelt" : "policy-only"],
        exitCode: result.exitCode
      )
    } catch {
      throw NativeHarnessToolError.commandFailed("无法启动命令：\(error.localizedDescription)")
    }
  }

  private func fetch(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    let rawURL = ["url", "href", "uri", "link", "sourceID", "source_id"]
      .compactMap { request.input[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty })
    guard let rawURL else { throw NativeHarnessToolError.missingInput("url") }
    guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw NativeHarnessToolError.invalidPath(rawURL)
    }
    // Network authorization is decided by ToolExecutionCoordinator before this
    // executor is reached. Once allowed, run one URL-scoped fetch in Seatbelt
    // rather than granting the desktop process an unbounded URLSession path.
    let scratchURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("kimi-harness-fetch-\(request.id.uuidString)", isDirectory: true)
    let sandbox = TerminalSandboxConfiguration.strict(
      workspaceURL: workspaceURL,
      scratchURL: scratchURL,
      allowNetwork: true
    )
    let marker = "__KIMI_HTTP_STATUS__"
    let command = "/usr/bin/curl --noproxy '*' --silent --show-error --location --connect-timeout 5 --max-time 15 --max-filesize 524288 --write-out '\\n\(marker)%{http_code}' \(shellQuote(url.absoluteString))"
    do {
      let handle = try TerminalCommandRunner.start(command: command, cwd: workspaceURL, sandbox: sandbox)
      let result = await Task.detached(priority: .userInitiated) { handle.wait() }.value
      try? fileManager.removeItem(at: scratchURL)
      let response = splitHTTPStatus(result.standardOutput, marker: marker)
      let status = response.status ?? (result.exitCode == 0 ? 0 : Int(result.exitCode))
      let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      let output = response.body + (stderr.isEmpty ? "" : (response.body.isEmpty ? "" : "\n") + stderr)
      return ToolExecutionResult(
        output: output,
        metadata: [
          "url": rawURL,
          "status": String(status),
          "transport": sandbox.enabled && TerminalSandboxConfiguration.isSupported ? "sandboxed-curl" : "policy-only-curl"
        ],
        exitCode: result.exitCode == 0 ? Self.webFetchExitCode(for: status) : result.exitCode
      )
    } catch {
      throw NativeHarnessToolError.commandFailed("Web Fetch 启动失败：\(error.localizedDescription)")
    }
  }

  private func splitHTTPStatus(_ output: String, marker: String) -> (body: String, status: Int?) {
    guard let range = output.range(of: marker, options: .backwards) else {
      return (output, nil)
    }
    let body = String(output[..<range.lowerBound]).trimmingCharacters(in: CharacterSet.newlines)
    let rawStatus = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return (body, Int(rawStatus))
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func input(_ request: ToolExecutionRequest, key: String) throws -> String {
    guard let value = request.input[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      throw NativeHarnessToolError.missingInput(key)
    }
    return value
  }

  private func resolve(_ rawPath: String) throws -> URL {
    let expanded = (rawPath as NSString).expandingTildeInPath
    let candidate = URL(fileURLWithPath: expanded, relativeTo: expanded.hasPrefix("/") ? nil : workspaceURL).standardizedFileURL
    let resolved = Self.canonicalFileURL(candidate)
    let root = Self.canonicalFileURL(workspaceURL)
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard resolved.path == root.path || resolved.path.hasPrefix(rootPath) else {
      throw NativeHarnessToolError.outsideWorkspace(rawPath)
    }
    return resolved
  }

  /// Resolves symlinks in the nearest existing ancestor and reappends the
  /// remaining components, so a symlink planted inside the workspace cannot
  /// redirect read/write/search outside the workspace boundary.
  private static func canonicalFileURL(_ url: URL) -> URL {
    let fileManager = FileManager.default
    var existingAncestor = url.standardizedFileURL
    var missingComponents: [String] = []
    while !fileManager.fileExists(atPath: existingAncestor.path), existingAncestor.path != "/" {
      missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
      existingAncestor.deleteLastPathComponent()
    }
    guard let resolvedPointer = realpath(existingAncestor.path, nil) else {
      return url.resolvingSymlinksInPath().standardizedFileURL
    }
    defer { free(resolvedPointer) }
    var resolved = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: false)
    for component in missingComponents {
      resolved.appendPathComponent(component)
    }
    return resolved.standardizedFileURL
  }
}
