import Foundation

public enum FileChangeStatus: String, Codable, Sendable {
  case added
  case modified
  case deleted
  case renamed
}

public struct DiffHunk: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let oldStart: Int
  public let oldCount: Int
  public let newStart: Int
  public let newCount: Int
  public let lines: [String]

  public init(
    id: UUID = UUID(), oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [String]
  ) {
    self.id = id
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
    self.lines = lines
  }
}

public struct FileDiff: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let path: String
  public let status: FileChangeStatus
  public let additions: Int
  public let deletions: Int
  public let hunks: [DiffHunk]

  public init(id: String, path: String, status: FileChangeStatus, additions: Int, deletions: Int, hunks: [DiffHunk]) {
    self.id = id
    self.path = path
    self.status = status
    self.additions = additions
    self.deletions = deletions
    self.hunks = hunks
  }
}

public struct DiffSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let taskID: UUID?
  public let baseCommit: String?
  public let headCommit: String?
  public let files: [FileDiff]
  public let generatedAt: Date

  public init(id: UUID = UUID(), taskID: UUID? = nil, baseCommit: String? = nil, headCommit: String? = nil, files: [FileDiff], generatedAt: Date = .now) {
    self.id = id
    self.taskID = taskID
    self.baseCommit = baseCommit
    self.headCommit = headCommit
    self.files = files
    self.generatedAt = generatedAt
  }
}

public enum DiffEngine {
  public static func snapshot(baseDirectory: URL, taskID: UUID? = nil, baseCommit: String? = nil) throws -> DiffSnapshot {
    let arguments = ["diff", "--no-ext-diff", "--unified=3"] + (baseCommit.map { [$0] } ?? []) + ["--"]
    let output = try runGit(arguments, in: baseDirectory)
    let files = parse(output)
    let headCommit = try? runGit(["rev-parse", "HEAD"], in: baseDirectory).trimmingCharacters(in: .whitespacesAndNewlines)
    return DiffSnapshot(taskID: taskID, baseCommit: baseCommit, headCommit: headCommit, files: files)
  }

  private static func parse(_ output: String) -> [FileDiff] {
    var builders: [String: Builder] = [:]
    var order: [String] = []
    var currentPath: String?
    var currentHunk: HunkBuilder?

    func flushHunk() {
      guard let path = currentPath, let hunk = currentHunk else { return }
      builders[path, default: Builder(path: path)].hunks.append(hunk.make())
      currentHunk = nil
    }

    func flushFile() {
      flushHunk()
      currentPath = nil
    }

    for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("diff --git ") {
        flushFile()
        let tokens = line.split(separator: " ")
        if let token = tokens.last {
          let path = String(token).hasPrefix("b/") ? String(token.dropFirst(2)) : String(token)
          currentPath = path
          if !order.contains(path) { order.append(path) }
          builders[path] = Builder(path: path)
        }
        continue
      }
      guard let path = currentPath else { continue }
      if line.hasPrefix("new file mode") {
        builders[path]?.status = .added
      } else if line.hasPrefix("deleted file mode") {
        builders[path]?.status = .deleted
      } else if line.hasPrefix("rename from") || line.hasPrefix("rename to") {
        builders[path]?.status = .renamed
      } else if line.hasPrefix("@@") {
        flushHunk()
        if let range = parseRange(line) {
          currentHunk = HunkBuilder(oldStart: range.oldStart, oldCount: range.oldCount, newStart: range.newStart, newCount: range.newCount)
        }
      } else if currentHunk != nil {
        currentHunk?.lines.append(line)
        if line.hasPrefix("+") && !line.hasPrefix("+++") { builders[path]?.additions += 1 }
        if line.hasPrefix("-") && !line.hasPrefix("---") { builders[path]?.deletions += 1 }
      }
    }
    flushFile()

    return order.compactMap { path in
      guard let builder = builders[path] else { return nil }
      return builder.make()
    }
  }

  private static func parseRange(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
    guard let at = line.firstIndex(of: "@") else { return nil }
    let body = line[at...].trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
    let parts = body.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    func parse(_ value: Substring) -> (Int, Int)? {
      let trimmed = value.dropFirst()
      let pieces = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
      guard let start = Int(pieces[0]) else { return nil }
      return (start, pieces.count == 2 ? (Int(pieces[1]) ?? 1) : 1)
    }
    guard let old = parse(parts[0]), let new = parse(parts[1]) else { return nil }
    return (old.0, old.1, new.0, new.1)
  }

  private static func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "KimiAgentCore.Diff", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
  }

  private struct HunkBuilder {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    var lines: [String] = []

    func make() -> DiffHunk {
      DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, lines: lines)
    }
  }

  private struct Builder {
    let path: String
    var status: FileChangeStatus = .modified
    var additions = 0
    var deletions = 0
    var hunks: [DiffHunk] = []

    func make() -> FileDiff {
      FileDiff(id: path, path: path, status: status, additions: additions, deletions: deletions, hunks: hunks)
    }
  }
}
