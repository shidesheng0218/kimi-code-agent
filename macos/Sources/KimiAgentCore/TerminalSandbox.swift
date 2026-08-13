import Darwin
import Foundation

/// Describes the OS-level boundary used by local terminal workers. The
/// Harness permission gate still decides whether a command may run; this
/// profile is the second line of defense once the process has started.
public struct TerminalSandboxConfiguration: Codable, Equatable, Sendable {
  public let workspaceURL: URL
  public let scratchURL: URL
  public let allowNetwork: Bool
  public let enabled: Bool
  /// Explicitly denied read locations. The Harness already validates ordinary
  /// file-tool paths against the Worktree; this OS boundary prevents shell,
  /// Skill, Hook, MCP and Plugin subprocesses from harvesting credentials if
  /// a command is compromised.
  public let protectedReadURLs: [URL]

  private enum CodingKeys: String, CodingKey {
    case workspaceURL, scratchURL, allowNetwork, enabled, protectedReadURLs
  }

  public init(
    workspaceURL: URL,
    scratchURL: URL,
    allowNetwork: Bool = false,
    enabled: Bool = true,
    protectedReadURLs: [URL]? = nil
  ) {
    let canonicalWorkspaceURL = Self.canonicalURL(workspaceURL)
    self.workspaceURL = canonicalWorkspaceURL
    self.scratchURL = Self.canonicalURL(scratchURL)
    self.allowNetwork = allowNetwork
    self.enabled = enabled
    self.protectedReadURLs = (protectedReadURLs ?? Self.defaultProtectedReadURLs())
      .map(Self.canonicalURL)
      .filter { $0.path != canonicalWorkspaceURL.path && !$0.path.hasPrefix(canonicalWorkspaceURL.path + "/") }
  }

  public static func strict(
    workspaceURL: URL,
    scratchURL: URL,
    allowNetwork: Bool = false,
    protectedReadURLs: [URL]? = nil
  ) -> TerminalSandboxConfiguration {
    TerminalSandboxConfiguration(
      workspaceURL: workspaceURL,
      scratchURL: scratchURL,
      allowNetwork: allowNetwork,
      enabled: true,
      protectedReadURLs: protectedReadURLs
    )
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      workspaceURL: try values.decode(URL.self, forKey: .workspaceURL),
      scratchURL: try values.decode(URL.self, forKey: .scratchURL),
      allowNetwork: try values.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false,
      enabled: try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      protectedReadURLs: try values.decodeIfPresent([URL].self, forKey: .protectedReadURLs)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(workspaceURL, forKey: .workspaceURL)
    try values.encode(scratchURL, forKey: .scratchURL)
    try values.encode(allowNetwork, forKey: .allowNetwork)
    try values.encode(enabled, forKey: .enabled)
    try values.encode(protectedReadURLs, forKey: .protectedReadURLs)
  }

  /// `sandbox-exec` is available on macOS development systems. If a future
  /// macOS removes it, callers can disable this boundary while retaining the
  /// Harness policy and should surface that downgrade in diagnostics.
  public static var isSupported: Bool {
    FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
  }

  public func profile() -> String {
    guard enabled else { return "(version 1) (allow default)" }
    let workspace = Self.profilePath(workspaceURL.path)
    let scratch = Self.profilePath(scratchURL.path)
    let networkRule = allowNetwork ? "\n    (allow network*)" : "\n    (deny network*)"
    let protectedReadRules = protectedReadURLs.map(Self.protectedReadRule).joined(separator: "\n")
    return """
    (version 1)
    (allow default)
    (deny file-write*)
    (allow file-write* (subpath "\(workspace)"))
    (allow file-write* (subpath "\(scratch)"))\(networkRule)
    (allow file-write* (literal "/dev/null"))
    \(protectedReadRules)
    """
  }

  /// Returns the physical path used by Seatbelt for a caller supplied working
  /// directory. The caller is still responsible for ensuring the directory is
  /// inside `workspaceURL`; this function only prevents `/var` aliases from
  /// bypassing or breaking the OS-level rule.
  public func canonicalizedURL(_ url: URL) -> URL {
    Self.canonicalURL(url)
  }

  private static func profilePath(_ path: String) -> String {
    // sandbox profiles use quoted Scheme strings. Escape backslash and quote
    // so a user-selected workspace cannot alter the profile itself.
    path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private static func protectedReadRule(for url: URL) -> String {
    let path = profilePath(url.path)
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
      ? "(deny file-read* (literal \"\(path)\"))"
      : "(deny file-read* (subpath \"\(path)\"))"
  }

  private static func defaultProtectedReadURLs() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      home.appendingPathComponent(".ssh", isDirectory: true),
      home.appendingPathComponent(".gnupg", isDirectory: true),
      home.appendingPathComponent(".aws", isDirectory: true),
      home.appendingPathComponent(".kube", isDirectory: true),
      home.appendingPathComponent(".config/gcloud", isDirectory: true),
      home.appendingPathComponent(".config/gh", isDirectory: true),
      home.appendingPathComponent(".config/git", isDirectory: true),
      home.appendingPathComponent(".git-credentials"),
      home.appendingPathComponent(".netrc"),
      home.appendingPathComponent(".npmrc"),
      home.appendingPathComponent(".pypirc"),
      home.appendingPathComponent("Library/Keychains", isDirectory: true)
    ]
  }

  /// Seatbelt compares the physical path, not necessarily the symlinked path
  /// received from Foundation (`/var` is `/private/var` on macOS). Resolve the
  /// nearest existing ancestor with `realpath` so planned scratch directories
  /// can be canonicalized before they are created.
  private static func canonicalURL(_ url: URL) -> URL {
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
    var resolved = URL(fileURLWithPath: String(cString: resolvedPointer), isDirectory: true)
    for component in missingComponents {
      resolved.appendPathComponent(component, isDirectory: true)
    }
    // Do not call `standardizedFileURL` here: Foundation converts the physical
    // `/private/var` path back to `/var`, while Seatbelt evaluates `/private`.
    return resolved
  }
}
