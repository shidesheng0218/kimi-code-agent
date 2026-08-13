import Foundation

public enum PermissionScope: String, Codable, CaseIterable, Sendable {
  case readWorkspace
  case writeWorkspace
  case executeCommand
  case network
  case browser
  case systemComputerUse
  case destructiveOperation
}

public enum PermissionDecision: String, Codable, CaseIterable, Sendable {
  case allow
  case ask
  case deny
}

public enum PermissionRememberScope: String, Codable, CaseIterable, Sendable {
  case task
  case never
}

public struct PermissionEvaluation: Equatable, Sendable {
  public let decision: PermissionDecision
  public let remember: PermissionRememberScope
  public let reason: String
  public let fingerprint: String

  public init(
    decision: PermissionDecision,
    remember: PermissionRememberScope,
    reason: String,
    fingerprint: String
  ) {
    self.decision = decision
    self.remember = remember
    self.reason = reason
    self.fingerprint = fingerprint
  }
}

public final class ApprovalMemory: @unchecked Sendable {
  private let lock = NSLock()
  private var approvals: [UUID: Set<String>] = [:]

  public init() {}

  public func contains(taskID: UUID, fingerprint: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return approvals[taskID]?.contains(normalize(fingerprint)) ?? false
  }

  public func remember(taskID: UUID, fingerprint: String) {
    lock.lock()
    approvals[taskID, default: []].insert(normalize(fingerprint))
    lock.unlock()
  }

  public func clear(taskID: UUID) {
    lock.lock()
    approvals.removeValue(forKey: taskID)
    lock.unlock()
  }

  private func normalize(_ value: String) -> String {
    value
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }
}

public struct PermissionPolicy: Sendable {
  public let workspaceURL: URL

  public init(workspacePath: String) {
    workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
  }

  public func decision(for scope: PermissionScope, path: String? = nil, command: String? = nil) -> PermissionDecision {
    switch scope {
    case .readWorkspace:
      return isInsideWorkspace(path) ? .allow : .deny
    case .writeWorkspace:
      return isInsideWorkspace(path) ? .allow : .deny
    case .executeCommand:
      guard let command else { return .ask }
      return isDangerous(command) ? .deny : .ask
    case .network, .browser, .systemComputerUse, .destructiveOperation:
      return .ask
    }
  }

  public func decision(for scope: PermissionScope, path: String) -> PermissionDecision {
    decision(for: scope, path: path, command: nil)
  }

  public func approvalEvaluation(action: String, description: String, workspacePath: String) -> PermissionEvaluation {
    let normalizedAction = normalizeApprovalText(action)
    let normalizedDescription = normalizeApprovalText(description)
    let fingerprint = [normalizedAction, normalizedDescription, normalizeApprovalText(workspacePath)]
      .filter { !$0.isEmpty }
      .joined(separator: " | ")
    let combined = [normalizedAction, normalizedDescription].joined(separator: " ")

    if isDangerous(combined) || containsAny(combined, patterns: [
      "rm -rf /",
      "rm -rf ~",
      "diskutil erase",
      "mkfs",
      "git reset --hard",
      "git clean -fdx"
    ]) {
      return PermissionEvaluation(
        decision: .deny,
        remember: .never,
        reason: "拒绝危险的破坏性操作。",
        fingerprint: fingerprint
      )
    }

    if containsAny(combined, patterns: ["credential", "token", "secret", "keychain", ".ssh", "password"]) {
      return PermissionEvaluation(
        decision: .ask,
        remember: .never,
        reason: "请求访问敏感凭据。",
        fingerprint: fingerprint
      )
    }

    if isReadOnlyPublicWebApproval(action: action, description: description) {
      return PermissionEvaluation(
        decision: .allow,
        remember: .task,
        reason: "公开网页读取是只读操作，已自动允许。",
        fingerprint: publicWebFingerprint(action: action, description: description, workspacePath: workspacePath)
      )
    }

    if containsAny(combined, patterns: ["network", "download", "http", "request", "fetch", "websearch", "browse", "url", "联网", "搜索"]) {
      return PermissionEvaluation(
        decision: .ask,
        remember: .never,
        reason: "请求访问外部网络服务。",
        fingerprint: fingerprint
      )
    }

    if containsAny(combined, patterns: ["readfile", "read file", "read ", "open file", "查看文件", "读取文件", "list files", "ls ", "grep ", "find "]) {
      return PermissionEvaluation(
        decision: .allow,
        remember: .task,
        reason: "读取工作区内的文件。",
        fingerprint: fingerprint
      )
    }

    if containsAny(combined, patterns: ["writefile", "write file", "edit", "modify", "patch", "update file", "apply patch", "diff", "写入", "修改", "编辑"]) {
      return PermissionEvaluation(
        decision: .ask,
        remember: .task,
        reason: "修改工作区内的文件。",
        fingerprint: fingerprint
      )
    }

    if containsAny(combined, patterns: ["browser", "click", "type", "navigate", "screenshot", "computer use", "鼠标", "键盘", "浏览器"]) {
      return PermissionEvaluation(
        decision: .ask,
        remember: .task,
        reason: "执行浏览器或系统交互。",
        fingerprint: fingerprint
      )
    }

    if containsAny(combined, patterns: ["bash", "shell", "command", "run", "execute", "terminal", "命令"]) {
      return PermissionEvaluation(
        decision: .ask,
        remember: .task,
        reason: "运行本地命令。",
        fingerprint: fingerprint
      )
    }

    return PermissionEvaluation(
      decision: .ask,
      remember: .task,
      reason: "请求执行工具操作。",
      fingerprint: fingerprint
    )
  }

  private func isInsideWorkspace(_ path: String?) -> Bool {
    guard let path else { return false }
    let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
    let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
    return candidate == workspaceURL.path || candidate.hasPrefix(root)
  }

  private func isDangerous(_ command: String) -> Bool {
    let normalized = command.lowercased()
    let blockedFragments = [
      "rm -rf /",
      "rm -rf ~",
      "sudo ",
      "mkfs",
      "diskutil erase",
      "git reset --hard",
      "git clean -fdx"
    ]
    return blockedFragments.contains { normalized.contains($0) }
  }

  private func normalizeApprovalText(_ value: String) -> String {
    value
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }

  private func containsAny(_ value: String, patterns: [String]) -> Bool {
    patterns.contains { value.contains($0.lowercased()) }
  }

  private func isReadOnlyPublicWebApproval(action: String, description: String) -> Bool {
    let normalizedAction = normalizeApprovalText(action)
    let normalizedDescription = normalizeApprovalText(description)
    let combined = [normalizedAction, normalizedDescription].joined(separator: " ")
    guard containsAny(combined, patterns: ["fetchurl", "web fetch", "web.fetch", "web_fetch", "network.fetch", "websearch", "web search", "web.search", "web_search", "搜索", "抓取"]) else {
      return false
    }
    if containsAny(combined, patterns: ["post", "put", "patch", "delete", "upload", "login", "credential", "token", "secret", "password", "写入", "登录", "上传"]) {
      return false
    }
    if let url = firstHTTPURL(in: description) {
      return isPublicHTTPURL(url)
    }
    // Web Search has no target URL and is read-only by definition; compatibility
    // FetchURL events sometimes hide the already-authorized source URL in the
    // runtime payload. Only exact known action names qualify here: substring
    // matching would let a server-named MCP tool (for example
    // "WebFetch_Export_Docs") auto-approve without user interaction.
    switch normalizedAction {
    case "websearch", "web search", "web.search", "web_search", "fetchurl", "web fetch", "web.fetch", "web_fetch":
      return true
    default:
      return false
    }
  }

  private func publicWebFingerprint(action: String, description: String, workspacePath: String) -> String {
    let normalizedAction = normalizeApprovalText(action)
    if let url = firstHTTPURL(in: description), let host = normalizedPublicHost(url.host) {
      if containsAny(normalizedAction, patterns: ["fetchurl", "web fetch", "web.fetch", "web_fetch", "network.fetch"]) {
        return "web.fetch:\(host)"
      }
    }
    if containsAny(normalizedAction, patterns: ["websearch", "web search", "web.search", "web_search"]) {
      return "web.search"
    }
    return [normalizedAction, normalizeApprovalText(workspacePath)].filter { !$0.isEmpty }.joined(separator: " | ")
  }

  private func firstHTTPURL(in value: String) -> URL? {
    let pattern = #"https?://[^\s，。；、）)\]\[\"'<>]+"#
    guard let range = value.range(of: pattern, options: .regularExpression) else { return nil }
    var raw = String(value[range])
    while let last = raw.last, ".,;:!?".contains(last) {
      raw.removeLast()
    }
    return URL(string: raw)
  }

  private func isPublicHTTPURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host?.lowercased(), !host.isEmpty else { return false }
    return !isPrivateHost(host)
  }

  private func normalizedPublicHost(_ host: String?) -> String? {
    guard let host = host?.lowercased(), !host.isEmpty, !isPrivateHost(host) else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private func isPrivateHost(_ host: String) -> Bool {
    var normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    if normalized.hasPrefix("["), normalized.hasSuffix("]") {
      normalized = String(normalized.dropFirst().dropLast())
    }
    if normalized == "localhost" || normalized == "ip6-localhost" || normalized.hasSuffix(".localhost") || normalized == "::1" || normalized == "0.0.0.0" || normalized == "::" {
      return true
    }
    if normalized.contains(":") {
      return Self.isUnsafeIPv6Literal(normalized)
    }
    let parts = normalized.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    let first = parts[0]
    let second = parts[1]
    return first == 10
      || first == 127
      || first == 0
      || (first == 100 && second >= 64 && second <= 127)
      || (first == 169 && second == 254)
      || (first == 172 && second >= 16 && second <= 31)
      || (first == 192 && second == 168)
      || (first == 192 && second == 0 && parts[2] == 2)
      || (first == 198 && second == 51 && parts[2] == 100)
      || (first == 203 && second == 0 && parts[2] == 113)
  }

  /// Conservative IPv6 literal classification: loopback, unspecified,
  /// IPv4-mapped/compatible forms of private addresses, link-local, ULA and
  /// multicast are never treated as public fetch targets.
  private static func isUnsafeIPv6Literal(_ host: String) -> Bool {
    let pieces = host.split(separator: "::", omittingEmptySubsequences: false)
    guard pieces.count <= 2 else { return true }
    func groups(_ part: Substring) -> [Int]? {
      guard !part.isEmpty else { return [] }
      var result: [Int] = []
      for raw in part.split(separator: ":") {
        if raw.contains(".") {
          let octets = raw.split(separator: ".").compactMap { Int($0) }
          guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else { return nil }
          result.append((octets[0] << 8) | octets[1])
          result.append((octets[2] << 8) | octets[3])
        } else {
          guard let value = Int(raw, radix: 16), (0...0xffff).contains(value) else { return nil }
          result.append(value)
        }
      }
      return result
    }
    var expanded: [Int]
    if pieces.count == 1 {
      guard let parsed = groups(pieces[0]), parsed.count == 8 else { return true }
      expanded = parsed
    } else {
      guard let head = groups(pieces[0]), let tail = groups(pieces[1]) else { return true }
      let missing = 8 - head.count - tail.count
      guard missing >= 1 else { return true }
      expanded = head + Array(repeating: 0, count: missing) + tail
    }
    if expanded.allSatisfy({ $0 == 0 }) { return true }
    if expanded.dropLast().allSatisfy({ $0 == 0 }) && expanded[7] == 1 { return true }
    let v4Mapped = expanded.prefix(5).allSatisfy { $0 == 0 } && expanded[5] == 0xffff
    let v4Compatible = expanded.prefix(6).allSatisfy { $0 == 0 }
    if v4Mapped || v4Compatible {
      let hi = expanded[6]
      let lo = expanded[7]
      return Self.isPrivateIPv4(hi >> 8, hi & 0xff, lo >> 8, lo & 0xff)
    }
    if (expanded[0] & 0xffc0) == 0xfe80 { return true }
    if (expanded[0] & 0xfe00) == 0xfc00 { return true }
    if (expanded[0] & 0xff00) == 0xff00 { return true }
    return false
  }

  private static func isPrivateIPv4(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Bool {
    a == 0 || a == 10 || a == 127
      || (a == 100 && b >= 64 && b <= 127)
      || (a == 169 && b == 254)
      || (a == 172 && b >= 16 && b <= 31)
      || (a == 192 && b == 168)
      || (a == 192 && b == 0 && c == 2)
      || (a == 198 && b == 51 && c == 100)
      || (a == 203 && b == 0 && c == 113)
  }
}
