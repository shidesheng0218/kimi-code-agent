import Foundation

public struct GitWorktree: Codable, Equatable, Sendable {
  public let repositoryPath: String
  public let path: URL
  public let branch: String
  public let baseCommit: String

  public init(repositoryPath: String, path: URL, branch: String, baseCommit: String) {
    self.repositoryPath = repositoryPath
    self.path = path
    self.branch = branch
    self.baseCommit = baseCommit
  }
}

public enum GitWorktreeManager {
  public static func isRepository(_ directory: URL) -> Bool {
    (try? runGit(["rev-parse", "--show-toplevel"], in: directory)) != nil
  }

  /// Returns whether the repository has a commit that can be used as a Worktree base.
  /// Empty repositories are valid Git repositories, but `git worktree add ... HEAD` cannot run in them.
  public static func hasUsableHEAD(_ directory: URL) -> Bool {
    guard isRepository(directory) else { return false }
    return (try? runGit(["rev-parse", "--verify", "HEAD"], in: directory)) != nil
  }

  public static func create(
    for repository: URL,
    taskID: UUID,
    rootDirectory: URL? = nil
  ) throws -> GitWorktree {
    let repositoryRoot = URL(fileURLWithPath: try runGit(["rev-parse", "--show-toplevel"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
    let baseCommit = try runGit(["rev-parse", "HEAD"], in: repositoryRoot).trimmingCharacters(in: .whitespacesAndNewlines)
    let root = rootDirectory ?? repositoryRoot.appendingPathComponent(".kimi-worktrees", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let shortID = String(taskID.uuidString.prefix(8)).lowercased()
    let branch = "kimi/task-\(shortID)/main"
    let worktreePath = root.appendingPathComponent("task-\(shortID)", isDirectory: true)
    try runGit(["worktree", "add", "-b", branch, worktreePath.path, baseCommit], in: repositoryRoot)
    return GitWorktree(repositoryPath: repositoryRoot.path, path: worktreePath, branch: branch, baseCommit: baseCommit)
  }

  public static func remove(_ worktree: GitWorktree) throws {
    let repository = URL(fileURLWithPath: worktree.repositoryPath, isDirectory: true)
    try runGit(["worktree", "remove", "--force", worktree.path.path], in: repository)
  }

  public static func merge(_ worktree: GitWorktree, into repository: URL, message: String) throws {
    try runGit(["add", "-A"], in: worktree.path)
    try runGit([
      "-c", "user.email=kimi-agent@localhost",
      "-c", "user.name=Kimi Agent Desktop",
      "commit", "-m", message
    ], in: worktree.path)
    try runGit(["merge", "--no-ff", worktree.branch, "-m", message], in: repository)
  }

  public static func restoreFile(_ relativePath: String, in worktree: GitWorktree, baseCommit: String? = nil) throws {
    let base = baseCommit ?? worktree.baseCommit
    try runGit(["checkout", base, "--", relativePath], in: worktree.path)
  }

  @discardableResult
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
      throw NSError(domain: "KimiAgentCore.Git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
  }
}
