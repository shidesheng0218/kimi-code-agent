import Foundation

public struct KimiPluginManifest: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let version: String
  public let agents: [String]
  public let skills: [String]
  public let hooks: [String]
  public let mcpServers: [String]
  public let permissions: [String]

  public init(
    id: String,
    name: String,
    version: String,
    agents: [String] = [],
    skills: [String] = [],
    hooks: [String] = [],
    mcpServers: [String] = [],
    permissions: [String] = []
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.agents = agents
    self.skills = skills
    self.hooks = hooks
    self.mcpServers = mcpServers
    self.permissions = permissions
  }

  public var capabilities: [String] {
    [
      agents.isEmpty ? nil : "agents",
      skills.isEmpty ? nil : "skills",
      hooks.isEmpty ? nil : "hooks",
      mcpServers.isEmpty ? nil : "mcp"
    ].compactMap { $0 }
  }

  public func requiresApproval(for permission: String) -> Bool {
    !permissions.contains(permission)
  }
}

public enum KimiPluginScope: String, Codable, CaseIterable, Sendable {
  case project
  case user
}

public struct KimiPluginDescriptor: Codable, Equatable, Identifiable, Sendable {
  public var id: String { manifest.id }
  public let manifest: KimiPluginManifest
  public let rootURL: URL
  public let scope: KimiPluginScope
  public var isEnabled: Bool

  public init(manifest: KimiPluginManifest, rootURL: URL, scope: KimiPluginScope, isEnabled: Bool = true) {
    self.manifest = manifest
    self.rootURL = rootURL
    self.scope = scope
    self.isEnabled = isEnabled
  }
}

public enum KimiPluginRegistry {
  public static func discover(
    projectDirectory: URL,
    userDirectory: URL? = nil,
    fileManager: FileManager = .default
  ) -> [KimiPluginDescriptor] {
    let projectRoots = [
      projectDirectory.appendingPathComponent(".kimi-agent/plugins", isDirectory: true),
      projectDirectory.appendingPathComponent(".kimi/plugins", isDirectory: true)
    ]
    let userRoots = userDirectory.map { [$0.appendingPathComponent("plugins", isDirectory: true)] } ?? []
    let entries = projectRoots.map { ($0, KimiPluginScope.project) } + userRoots.map { ($0, KimiPluginScope.user) }

    return entries.flatMap { root, scope in
      guard let children = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) else { return [KimiPluginDescriptor]() }
      return children.compactMap { directory in
        let manifestURL = directory.appendingPathComponent(".kimi-plugin/plugin.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(KimiPluginManifest.self, from: data) else { return nil }
        return KimiPluginDescriptor(manifest: manifest, rootURL: directory, scope: scope)
      }
    }
    .sorted { lhs, rhs in
      if lhs.scope != rhs.scope { return lhs.scope == .project }
      return lhs.manifest.name.localizedCaseInsensitiveCompare(rhs.manifest.name) == .orderedAscending
    }
  }
}

public enum AgentRuleRegistry {
  public static func projectRules(projectDirectory: URL, fileManager: FileManager = .default) -> [AgentRule] {
    let candidates = [
      projectDirectory.appendingPathComponent("AGENTS.md"),
      projectDirectory.appendingPathComponent(".kimi-agent/rules.md"),
      projectDirectory.appendingPathComponent(".kimi/rules.md")
    ]
    guard let url = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return [] }
    return parse(url: url, fileManager: fileManager)
  }

  /// Loads inherited rules for a concrete file. Rules from the project root
  /// are applied first, then the nearest directory rules are appended. Duplicate
  /// normalized text is removed while preserving the first source.
  public static func rules(
    forFile fileURL: URL,
    projectDirectory: URL,
    fileManager: FileManager = .default
  ) -> [AgentRule] {
    let projectRoot = projectDirectory.standardizedFileURL
    let fileDirectory = fileURL.hasDirectoryPath ? fileURL : fileURL.deletingLastPathComponent()
    var directories: [URL] = []
    var cursor = fileDirectory.standardizedFileURL
    while cursor.path == projectRoot.path || cursor.path.hasPrefix(projectRoot.path + "/") {
      directories.append(cursor)
      if cursor.path == projectRoot.path { break }
      let parent = cursor.deletingLastPathComponent()
      if parent.path == cursor.path { break }
      cursor = parent
    }

    var merged: [AgentRule] = []
    var seen = Set<String>()
    for directory in directories.reversed() {
      let candidates = [
        directory.appendingPathComponent("AGENTS.md"),
        directory.appendingPathComponent(".kimi-agent/rules.md"),
        directory.appendingPathComponent(".kimi/rules.md")
      ]
      for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
        for rule in parse(url: candidate, fileManager: fileManager) {
          let key = rule.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
          if seen.insert(key).inserted { merged.append(rule) }
        }
        break
      }
    }
    return merged
  }

  private static func parse(url: URL, fileManager: FileManager) -> [AgentRule] {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return contents
      .components(separatedBy: .newlines)
      .compactMap { line -> AgentRule? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let text = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
        return text.isEmpty ? nil : AgentRule(text: text)
      }
  }
}

public struct AgentRule: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let text: String
  public let isEnabled: Bool

  public init(id: UUID = UUID(), text: String, isEnabled: Bool = true) {
    self.id = id
    self.text = text
    self.isEnabled = isEnabled
  }
}

public struct AgentRuleSet: Codable, Equatable, Sendable {
  public var system: [AgentRule]
  public var user: [AgentRule]
  public var project: [AgentRule]
  public var task: [AgentRule]

  public init(system: [AgentRule] = [], user: [AgentRule] = [], project: [AgentRule] = [], task: [AgentRule] = []) {
    self.system = system
    self.user = user
    self.project = project
    self.task = task
  }

  public var effectiveRules: [AgentRule] {
    (system + user + project + task).filter(\.isEnabled)
  }
}
