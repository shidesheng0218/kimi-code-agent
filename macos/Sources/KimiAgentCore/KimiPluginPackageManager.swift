import Foundation

public struct KimiPluginInstallReceipt: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let pluginID: String
  public let installedVersion: String
  public let targetURL: URL
  public let backupURL: URL?
  public let installedAt: Date

  public init(
    id: UUID = UUID(),
    pluginID: String,
    installedVersion: String,
    targetURL: URL,
    backupURL: URL? = nil,
    installedAt: Date = .now
  ) {
    self.id = id
    self.pluginID = pluginID
    self.installedVersion = installedVersion
    self.targetURL = targetURL
    self.backupURL = backupURL
    self.installedAt = installedAt
  }
}

public enum KimiPluginPackageError: LocalizedError, Equatable {
  case missingManifest(URL)
  case invalidIdentifier(String)
  case invalidSource(URL)
  case missingBackup(String)

  public var errorDescription: String? {
    switch self {
    case let .missingManifest(url): "插件缺少 .kimi-plugin/plugin.json：\(url.path)"
    case let .invalidIdentifier(value): "插件 ID 不安全：\(value)"
    case let .invalidSource(url): "插件来源无效：\(url.path)"
    case let .missingBackup(id): "插件 \(id) 没有可回滚备份。"
    }
  }
}

/// Filesystem-only Plugin lifecycle manager. Network/Git download remains a
/// separate acquisition concern; once a source directory is available, this
/// manager validates the manifest, stages the copy, and swaps it without
/// destructive replacement. Every update retains the prior package for an
/// explicit rollback.
public final class KimiPluginPackageManager: @unchecked Sendable {
  private let pluginsRoot: URL
  private let backupRoot: URL
  private let fileManager: FileManager

  public init(projectDirectory: URL, fileManager: FileManager = .default) {
    self.pluginsRoot = projectDirectory
      .appendingPathComponent(".kimi-agent", isDirectory: true)
      .appendingPathComponent("plugins", isDirectory: true)
    self.backupRoot = pluginsRoot.appendingPathComponent(".backups", isDirectory: true)
    self.fileManager = fileManager
  }

  public func pluginURL(id: String) -> URL {
    pluginsRoot.appendingPathComponent(safeDirectoryName(for: id), isDirectory: true)
  }

  @discardableResult
  public func install(sourceURL: URL) throws -> KimiPluginInstallReceipt {
    let source = sourceURL.standardizedFileURL
    guard fileManager.fileExists(atPath: source.path) else {
      throw KimiPluginPackageError.invalidSource(source)
    }
    let sourceManifest = try manifest(at: source)
    let target = pluginURL(id: sourceManifest.id)
    guard source.path != target.standardizedFileURL.path else {
      throw KimiPluginPackageError.invalidSource(source)
    }

    try fileManager.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
    let staging = pluginsRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
    try fileManager.copyItem(at: source, to: staging)
    do {
      let stagedManifest = try manifest(at: staging)
      guard stagedManifest.id == sourceManifest.id, stagedManifest.version == sourceManifest.version else {
        throw KimiPluginPackageError.invalidSource(source)
      }

      var backup: URL?
      if fileManager.fileExists(atPath: target.path) {
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let previousVersion = (try? manifest(at: target).version) ?? "unknown"
        backup = backupRoot.appendingPathComponent(
          "\(safeDirectoryName(for: sourceManifest.id))-\(previousVersion)-\(UUID().uuidString)",
          isDirectory: true
        )
        try fileManager.moveItem(at: target, to: backup!)
      }

      do {
        try fileManager.moveItem(at: staging, to: target)
      } catch {
        if let backup, !fileManager.fileExists(atPath: target.path) {
          try? fileManager.moveItem(at: backup, to: target)
        }
        throw error
      }
      return KimiPluginInstallReceipt(
        pluginID: sourceManifest.id,
        installedVersion: sourceManifest.version,
        targetURL: target,
        backupURL: backup
      )
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  /// Restores the backup retained by an update. The currently installed
  /// version is itself moved to the backups directory first, so rollback is
  /// recoverable instead of deleting the newer package.
  public func rollback(_ receipt: KimiPluginInstallReceipt) throws {
    guard let backup = receipt.backupURL, fileManager.fileExists(atPath: backup.path) else {
      throw KimiPluginPackageError.missingBackup(receipt.pluginID)
    }
    let target = pluginURL(id: receipt.pluginID)
    if fileManager.fileExists(atPath: target.path) {
      try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
      let currentVersion = (try? manifest(at: target).version) ?? "current"
      let rollbackBackup = backupRoot.appendingPathComponent(
        "\(safeDirectoryName(for: receipt.pluginID))-\(currentVersion)-rollback-\(UUID().uuidString)",
        isDirectory: true
      )
      try fileManager.moveItem(at: target, to: rollbackBackup)
    }
    do {
      try fileManager.moveItem(at: backup, to: target)
    } catch {
      throw error
    }
  }

  /// Removes a package from discovery without destroying it. Callers may
  /// present the returned backup folder as a recoverable uninstall receipt.
  @discardableResult
  public func uninstall(id: String) throws -> URL? {
    let target = pluginURL(id: id)
    guard fileManager.fileExists(atPath: target.path) else { return nil }
    try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    let backup = backupRoot.appendingPathComponent(
      "\(safeDirectoryName(for: id))-uninstall-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.moveItem(at: target, to: backup)
    return backup
  }

  private func manifest(at root: URL) throws -> KimiPluginManifest {
    let manifestURL = root.appendingPathComponent(".kimi-plugin/plugin.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw KimiPluginPackageError.missingManifest(manifestURL)
    }
    return try JSONDecoder().decode(KimiPluginManifest.self, from: Data(contentsOf: manifestURL))
  }

  private func safeDirectoryName(for identifier: String) -> String {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard !trimmed.isEmpty,
          trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          trimmed != ".", trimmed != ".." else {
      return "invalid-plugin-id"
    }
    return trimmed
  }
}
