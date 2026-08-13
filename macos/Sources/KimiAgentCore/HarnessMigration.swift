import Foundation

public struct HarnessMigrationResult: Codable, Equatable, Sendable {
  public let version: Int
  public let didBackup: Bool
  public let backedUpFiles: [String]
  public let migratedAt: Date

  public init(version: Int, didBackup: Bool, backedUpFiles: [String], migratedAt: Date = .now) {
    self.version = version
    self.didBackup = didBackup
    self.backedUpFiles = backedUpFiles
    self.migratedAt = migratedAt
  }
}

/// Performs the one-time, lossless transition from legacy snapshots to the
/// Harness repository. It only copies files and writes a marker; the caller
/// remains responsible for importing domain records.
public final class HarnessMigrationCoordinator: @unchecked Sendable {
  public static let currentVersion = 3
  private let directory: URL
  private let fileManager: FileManager

  public init(directory: URL, fileManager: FileManager = .default) {
    self.directory = directory.standardizedFileURL
    self.fileManager = fileManager
  }

  public func prepare() throws -> HarnessMigrationResult {
    let harnessDirectory = directory.appendingPathComponent("harness-v3", isDirectory: true)
    let markerURL = harnessDirectory.appendingPathComponent("migration.json")
    if let data = try? Data(contentsOf: markerURL),
       let existing = try? JSONDecoder().decode(HarnessMigrationResult.self, from: data) {
      return HarnessMigrationResult(
        version: existing.version,
        didBackup: false,
        backedUpFiles: existing.backedUpFiles,
        migratedAt: existing.migratedAt
      )
    }

    try fileManager.createDirectory(at: harnessDirectory, withIntermediateDirectories: true)
    let backupDirectory = harnessDirectory.appendingPathComponent("backups", isDirectory: true)
    try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

    let candidates: [(source: URL, name: String)] = [
      (directory.appendingPathComponent("state.json"), "state.json"),
      (directory.appendingPathComponent("session-events.jsonl"), "session-events.jsonl"),
      (directory.appendingPathComponent("harness-v2/events.jsonl"), "harness-v2-events.jsonl"),
      (directory.appendingPathComponent("harness-v2-events.jsonl"), "harness-v2-events.jsonl")
    ]
    var copied: [String] = []
    for candidate in candidates where fileManager.fileExists(atPath: candidate.source.path) {
      let destination = backupDirectory.appendingPathComponent(candidate.name + ".backup")
      guard !fileManager.fileExists(atPath: destination.path) else { continue }
      try fileManager.copyItem(at: candidate.source, to: destination)
      copied.append(candidate.name)
    }

    let result = HarnessMigrationResult(
      version: Self.currentVersion,
      didBackup: !copied.isEmpty,
      backedUpFiles: copied.sorted()
    )
    let data = try JSONEncoder().encode(result)
    try data.write(to: markerURL, options: .atomic)
    return result
  }
}
