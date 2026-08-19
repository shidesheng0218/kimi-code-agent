import Foundation

/// One-time migration that folds every legacy engine data location into the
/// contained `runtime/` directory inside Application Support. Older builds
/// let the embedded engine use its default XDG locations (`~/.config`,
/// `~/.local/share`, `~/.local/state`) plus an `opencode-state` directory next
/// to Application Support. This migrator moves whatever exists into the new
/// homes chosen by `KimiHeadlessRuntimeFactory` without ever overwriting
/// existing data: when both a legacy source and the new target exist, the
/// legacy copy is preserved under `runtime/legacy/` instead.
public enum KimiRuntimeDataMigrator {
  public struct Report: Equatable, Sendable {
    public var moved: [String] = []
    public var preserved: [String] = []
    public var failed: [String] = []

    public init() {}
  }

  @discardableResult
  public static func migrateIfNeeded(
    applicationSupportDirectory: URL,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> Report {
    var report = Report()
    let runtimeHome = applicationSupportDirectory.appendingPathComponent("runtime", isDirectory: true)
    let legacyHome = runtimeHome.appendingPathComponent("legacy", isDirectory: true)

    // (legacy source, new target). Targets mirror the XDG homes configured in
    // the factory; the engine appends its own leaf directory underneath.
    let moves: [(source: URL, target: URL)] = [
      (
        homeDirectory.appendingPathComponent(".local/share/opencode", isDirectory: true),
        runtimeHome.appendingPathComponent("data/opencode", isDirectory: true)
      ),
      (
        homeDirectory.appendingPathComponent(".config/opencode", isDirectory: true),
        runtimeHome.appendingPathComponent("config/opencode", isDirectory: true)
      ),
      (
        homeDirectory.appendingPathComponent(".local/state/opencode", isDirectory: true),
        runtimeHome.appendingPathComponent("state/opencode", isDirectory: true)
      ),
      (
        applicationSupportDirectory.appendingPathComponent("opencode-state", isDirectory: true),
        runtimeHome.appendingPathComponent("state", isDirectory: true)
      ),
    ]

    // The fusion-era `Application Support/opencode` directory was never read
    // by the engine (no XDG_CONFIG_HOME pointed at it), so activating it now
    // would change behavior. Preserve it inert under runtime/legacy instead.
    let fusionEraConfig = applicationSupportDirectory.appendingPathComponent("opencode", isDirectory: true)
    if fileManager.fileExists(atPath: fusionEraConfig.path) {
      let stash = legacyHome.appendingPathComponent("app-support-opencode", isDirectory: true)
      if !fileManager.fileExists(atPath: stash.path) {
        do {
          try fileManager.createDirectory(at: legacyHome, withIntermediateDirectories: true)
          try fileManager.moveItem(at: fusionEraConfig, to: stash)
          report.moved.append("\(fusionEraConfig.path) -> \(stash.path)")
        } catch {
          report.failed.append(fusionEraConfig.path)
        }
      } else {
        report.preserved.append(fusionEraConfig.path)
      }
    }

    for (source, target) in moves {
      guard fileManager.fileExists(atPath: source.path) else { continue }
      if fileManager.fileExists(atPath: target.path) {
        // Both exist: keep the new target authoritative and stash the legacy
        // copy under runtime/legacy so nothing is silently discarded.
        let stash = legacyHome.appendingPathComponent(source.lastPathComponent + "-legacy", isDirectory: true)
        guard !fileManager.fileExists(atPath: stash.path) else {
          report.preserved.append(source.path)
          continue
        }
        do {
          try fileManager.createDirectory(at: legacyHome, withIntermediateDirectories: true)
          try fileManager.moveItem(at: source, to: stash)
          report.moved.append("\(source.path) -> \(stash.path)")
        } catch {
          report.failed.append(source.path)
        }
        continue
      }
      do {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: target)
        report.moved.append("\(source.path) -> \(target.path)")
      } catch {
        report.failed.append(source.path)
      }
    }

    // Remove now-empty legacy parent shells (`~/.local/state` etc. are shared
    // system locations, so only prune directories we created and left empty).
    for shell in [
      homeDirectory.appendingPathComponent(".local/state/opencode", isDirectory: true),
      applicationSupportDirectory.appendingPathComponent("opencode-state", isDirectory: true),
    ] where fileManager.fileExists(atPath: shell.path) {
      if (try? fileManager.contentsOfDirectory(atPath: shell.path).isEmpty) == true {
        try? fileManager.removeItem(at: shell)
      }
    }
    return report
  }
}
