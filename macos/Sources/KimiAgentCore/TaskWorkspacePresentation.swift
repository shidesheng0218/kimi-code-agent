import Foundation

/// UI-agnostic presentation decisions for the native task workbench.
///
/// Keeping these choices in Core means the SwiftUI shell can stay focused on
/// layout, while every task state consistently surfaces its next safe action.
public struct TaskWorkspacePresentation: Equatable, Sendable {
  public struct ConversationDestination: Equatable, Sendable {
    public let taskID: UUID
    public let workspacePath: String

    public init(taskID: UUID, workspacePath: String) {
      self.taskID = taskID
      self.workspacePath = workspacePath
    }
  }

  public enum ComposerSubmissionTarget: String, Equatable, Sendable {
    case newTask
    case continueTask
  }

  public enum PrimaryAction: String, Equatable, Sendable {
    case none
    case run
    case resume
    case stop
    case verify
    case merge
  }

  public enum Inspector: String, Equatable, Sendable {
    case plan
    case activity
    case approval
    case review
    case verification
    case summary
  }

  public let primaryAction: PrimaryAction
  public let inspector: Inspector
  public let stageTitle: String
  public let stageSymbol: String
  public let statusDescription: String

  public init(status: TaskStatus) {
    switch status {
    case .draft, .planning:
      primaryAction = .run
      inspector = .plan
      stageTitle = "执行计划"
      stageSymbol = "list.bullet.rectangle"
    case .running:
      primaryAction = .stop
      inspector = .activity
      stageTitle = "活动上下文"
      stageSymbol = "waveform.path.ecg"
    case .waitingForApproval:
      primaryAction = .none
      inspector = .approval
      stageTitle = "需要确认"
      stageSymbol = "hand.raised"
    case .waitingForUser:
      primaryAction = .resume
      inspector = .approval
      stageTitle = "等待继续"
      stageSymbol = "pause.circle"
    case .reviewReady:
      primaryAction = .verify
      inspector = .review
      stageTitle = "代码审阅"
      stageSymbol = "arrow.triangle.branch"
    case .verifying:
      primaryAction = .none
      inspector = .verification
      stageTitle = "验证"
      stageSymbol = "checkmark.shield"
    case .mergeReady:
      primaryAction = .merge
      inspector = .verification
      stageTitle = "验证"
      stageSymbol = "checkmark.shield"
    case .merged, .completed:
      primaryAction = .none
      inspector = .summary
      stageTitle = "任务摘要"
      stageSymbol = "checkmark.seal"
    case .failed, .blocked:
      primaryAction = .resume
      inspector = .activity
      stageTitle = "活动上下文"
      stageSymbol = "waveform.path.ecg"
    case .cancelled:
      primaryAction = .none
      inspector = .activity
      stageTitle = "活动上下文"
      stageSymbol = "waveform.path.ecg"
    }

    statusDescription = Self.description(for: status)
  }

  public static func composerSubmissionTarget(for task: AgentTask?) -> ComposerSubmissionTarget {
    guard let task else { return .newTask }
    switch task.status {
    case .merged, .cancelled:
      return .newTask
    default:
      return .continueTask
    }
  }

  public static func conversationDestination(for task: AgentTask) -> ConversationDestination {
    ConversationDestination(taskID: task.id, workspacePath: task.workspacePath)
  }

  private static func description(for status: TaskStatus) -> String {
    switch status {
    case .draft: "任务草稿已准备好"
    case .planning: "等待开始执行"
    case .running: "正在执行任务"
    case .waitingForApproval: "等待你的权限确认"
    case .waitingForUser: "任务已暂停，可继续执行"
    case .reviewReady: "代码变更等待审阅"
    case .verifying: "正在运行验证"
    case .mergeReady: "验证通过，可合并"
    case .merged: "变更已合并"
    case .completed: "任务已完成"
    case .failed: "任务执行失败，可重试"
    case .cancelled: "任务已停止"
    case .blocked: "任务受阻，等待处理"
    }
  }
}

public enum WorkbenchLayoutMode: String, Equatable, Sendable {
  case full
  case focused
  case singleColumn
}

public enum WorkbenchLayoutPolicy {
  public static func mode(for width: Double) -> WorkbenchLayoutMode {
    if width < 900 { return .singleColumn }
    if width < 1_180 { return .focused }
    return .full
  }
}
