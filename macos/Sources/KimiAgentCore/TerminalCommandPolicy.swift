import Foundation

public enum TerminalCommandRisk: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
  case blocked
}

public enum TerminalCommandDecision: String, Codable, CaseIterable, Sendable {
  case allow
  case ask
  case deny
}

public struct TerminalCommandEvaluation: Equatable, Sendable {
  public let risk: TerminalCommandRisk
  public let decision: TerminalCommandDecision
  public let allowSession: Bool
  public let reason: String
  public let fingerprint: String

  public init(risk: TerminalCommandRisk, decision: TerminalCommandDecision, allowSession: Bool, reason: String, fingerprint: String) {
    self.risk = risk
    self.decision = decision
    self.allowSession = allowSession
    self.reason = reason
    self.fingerprint = fingerprint
  }
}

public struct TerminalCommandPolicy: Sendable {
  public init() {}

  public func evaluate(command: String, actor: TerminalActor) -> TerminalCommandEvaluation {
    let normalized = normalize(command)
    let fingerprint = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard !normalized.isEmpty else {
      return TerminalCommandEvaluation(risk: .blocked, decision: .deny, allowSession: false, reason: "命令不能为空。", fingerprint: fingerprint)
    }

    if containsAny(normalized, [
      "sudo ", "rm -rf /", "rm -rf ~", "rm -rf $home", "mkfs", "diskutil erase", "dd if=", ":(){", "git clean -fdx", "chmod -r 777 /", "chown -r"
    ]) {
      return TerminalCommandEvaluation(risk: .blocked, decision: .deny, allowSession: false, reason: "已阻止危险或越权命令。", fingerprint: fingerprint)
    }

    if containsAny(normalized, ["rm ", "rmdir ", "git push", "git reset", "git clean", "chmod ", "chown ", "kill ", "curl ", "wget ", "npm install", "pnpm add", "yarn add", "pip install", "brew install", "git checkout", "git switch"]) {
      let highRisk = containsAny(normalized, ["rm ", "rmdir ", "git push", "git reset", "git clean", "chmod ", "chown ", "kill ", "curl ", "wget "])
      return TerminalCommandEvaluation(
        risk: highRisk ? .high : .medium,
        decision: .ask,
        allowSession: !highRisk,
        reason: highRisk ? "该命令可能删除、覆盖、外发或改变系统状态。" : "该命令会安装依赖或修改工作区状态。",
        fingerprint: fingerprint
      )
    }

    if containsAny(normalized, ["pwd", "ls", "cat ", "find ", "grep ", "rg ", "git status", "git diff", "npm test", "npm run", "swift test", "swift build", "node --version"]) {
      return TerminalCommandEvaluation(
        risk: .low,
        decision: actor == .user ? .allow : .ask,
        allowSession: true,
        reason: actor == .user ? "用户主动执行只读或验证命令。" : "Agent 请求执行低风险命令。",
        fingerprint: fingerprint
      )
    }

    return TerminalCommandEvaluation(risk: .medium, decision: .ask, allowSession: true, reason: "未识别命令，执行前需要确认。", fingerprint: fingerprint)
  }

  private func normalize(_ command: String) -> String {
    command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func containsAny(_ text: String, _ fragments: [String]) -> Bool {
    fragments.contains { text.contains($0) }
  }
}
