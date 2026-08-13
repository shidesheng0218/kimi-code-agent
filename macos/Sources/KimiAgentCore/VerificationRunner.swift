import Foundation

public enum VerificationKind: String, Codable, CaseIterable, Sendable {
  case dependencyCheck
  case lint
  case typeCheck
  case test
  case build
  case server
  case browser
  case screenshot
  case command
}

public struct VerificationStep: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let kind: VerificationKind
  public let command: String?
  public let arguments: [String]
  public let url: URL?
  public let timeoutSeconds: Int
  public let requiresApproval: Bool

  public init(
    id: UUID = UUID(),
    kind: VerificationKind,
    command: String? = nil,
    arguments: [String] = [],
    url: URL? = nil,
    timeoutSeconds: Int = 120,
    requiresApproval: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.command = command
    self.arguments = arguments
    self.url = url
    self.timeoutSeconds = timeoutSeconds
    self.requiresApproval = requiresApproval
  }
}

public struct VerificationPlan: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let steps: [VerificationStep]
  public let stopOnFailure: Bool
  public let maxRepairRounds: Int

  public init(
    id: UUID = UUID(),
    steps: [VerificationStep],
    stopOnFailure: Bool = true,
    maxRepairRounds: Int = 3
  ) {
    self.id = id
    self.steps = steps
    self.stopOnFailure = stopOnFailure
    self.maxRepairRounds = maxRepairRounds
  }
}

public struct VerificationStepResult: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public let stepID: UUID
  public let kind: VerificationKind
  public let passed: Bool
  public let exitCode: Int32
  public let standardOutput: String
  public let standardError: String
  public let duration: TimeInterval

  public init(
    id: UUID = UUID(),
    stepID: UUID,
    kind: VerificationKind,
    passed: Bool,
    exitCode: Int32,
    standardOutput: String,
    standardError: String,
    duration: TimeInterval
  ) {
    self.id = id
    self.stepID = stepID
    self.kind = kind
    self.passed = passed
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.duration = duration
  }
}

public struct VerificationResult: Codable, Equatable, Sendable {
  public let passed: Bool
  public let steps: [VerificationStepResult]

  public init(passed: Bool, steps: [VerificationStepResult]) {
    self.passed = passed
    self.steps = steps
  }
}

public enum VerificationRepairPlanner {
  public static func shouldAutoRepair(task: AgentTask, result: VerificationResult, maxRepairRounds: Int) -> Bool {
    guard maxRepairRounds > 0, !task.mode.isReadOnly, !result.passed else { return false }
    return repairRoundCount(for: task) < maxRepairRounds
  }

  public static func repairPrompt(for task: AgentTask, result: VerificationResult, maxRepairRounds: Int) -> String {
    let round = repairRoundCount(for: task) + 1
    let failureSummary = result.steps
      .filter { !$0.passed }
      .map { step in
        let detail = firstMeaningfulLine(step.standardError, step.standardOutput) ?? "没有可读的失败输出"
        return "- \(step.kind.rawValue)：\(detail)"
      }
      .joined(separator: "\n")

    return """
    请基于以下验证失败继续修复任务：\(task.title)

    当前是第 \(round) 轮自动修复，最多 \(maxRepairRounds) 轮。
    失败摘要：
    \(failureSummary.isEmpty ? "- 未捕获到失败步骤" : failureSummary)

    只修复导致失败的问题，尽量保持已经通过的变更不变，然后重新验证。
    """
  }

  private static func repairRoundCount(for task: AgentTask) -> Int {
    task.structuredEvents.filter { $0.kind == .verificationFailed }.count
  }

  private static func firstMeaningfulLine(_ lines: String...) -> String? {
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }
}

public enum VerificationRunner {
  public static func run(_ plan: VerificationPlan, workingDirectory: URL) throws -> VerificationResult {
    var results: [VerificationStepResult] = []

    for step in plan.steps {
      let startedAt = Date()
      guard let command = step.command else {
        let result = VerificationStepResult(
          id: UUID(), stepID: step.id, kind: step.kind, passed: false, exitCode: 1,
          standardOutput: "", standardError: "验证步骤缺少 command", duration: Date().timeIntervalSince(startedAt)
        )
        results.append(result)
        if plan.stopOnFailure { break }
        continue
      }

      let processResult = try KimiProcessRunner.run(
        KimiCommand(executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [command] + step.arguments),
        workingDirectory: workingDirectory
      )
      let result = VerificationStepResult(
        id: UUID(), stepID: step.id, kind: step.kind,
        passed: processResult.exitCode == 0,
        exitCode: processResult.exitCode,
        standardOutput: processResult.standardOutput,
        standardError: processResult.standardError,
        duration: Date().timeIntervalSince(startedAt)
      )
      results.append(result)
      if !result.passed && plan.stopOnFailure { break }
    }

    return VerificationResult(passed: !results.isEmpty && results.allSatisfy(\.passed), steps: results)
  }
}
