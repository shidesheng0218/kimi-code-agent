import Foundation

public struct FailureContextPack: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let operationID: UUID
  public let taskID: UUID
  public let stage: AgentKind
  public let command: String?
  public let exitCode: Int32?
  public let stderr: String
  public let relatedFiles: [String]
  public let diffArtifactID: String?
  public let attempt: Int
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    operationID: UUID,
    taskID: UUID,
    stage: AgentKind,
    command: String? = nil,
    exitCode: Int32? = nil,
    stderr: String = "",
    relatedFiles: [String] = [],
    diffArtifactID: String? = nil,
    attempt: Int = 1,
    createdAt: Date = .now
  ) {
    self.id = id
    self.operationID = operationID
    self.taskID = taskID
    self.stage = stage
    self.command = Self.redact(command)
    self.exitCode = exitCode
    self.stderr = Self.redact(stderr) ?? ""
    self.relatedFiles = Array(relatedFiles.prefix(100))
    self.diffArtifactID = diffArtifactID
    self.attempt = max(1, attempt)
    self.createdAt = createdAt
  }

  public var redactedStderr: String { stderr }

  public var promptText: String {
    [
      "失败阶段：\(stage.title)",
      command.map { "命令：\($0)" },
      exitCode.map { "退出码：\($0)" },
      stderr.isEmpty ? nil : "错误：\(stderr)",
      relatedFiles.isEmpty ? nil : "相关文件：\(relatedFiles.joined(separator: ", "))",
      diffArtifactID.map { "Diff 产物：\($0)" },
      "修复轮次：\(attempt)"
    ].compactMap { $0 }.joined(separator: "\n")
  }

  private static func redact(_ text: String?) -> String? {
    guard let text else { return nil }
    var output = text
    let patterns = [
      #"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*[^\s,;]+"#,
      #"sk-[A-Za-z0-9_-]{12,}"#,
      #"(?i)bearer\s+[A-Za-z0-9._-]+"#
    ]
    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: "$1[REDACTED]")
      }
    }
    return output
  }
}

public enum DebugLoopAction: String, Codable, Sendable {
  case startDebug
  case askUser
  case stop
}

public enum DebugLoopCoordinator {
  public static func nextAction(for pack: FailureContextPack, maxRounds: Int) -> DebugLoopAction {
    guard pack.exitCode != 0 || !pack.redactedStderr.isEmpty else { return .stop }
    return pack.attempt < max(1, maxRounds) ? .startDebug : .askUser
  }
}
