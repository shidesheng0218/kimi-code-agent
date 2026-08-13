import Foundation

public enum WorkbenchHomeMetricKind: String, CaseIterable, Sendable {
  case total
  case active
  case reviewReady
  case completed
}

public struct WorkbenchHomeSummary: Equatable, Sendable {
  public let totalTasks: Int
  public let activeTasks: Int
  public let reviewReadyTasks: Int
  public let completedTasks: Int

  public init(state: AppState) {
    totalTasks = state.tasks.count
    activeTasks = state.tasks.filter { task in
      switch task.status {
      case .planning, .running, .waitingForApproval, .waitingForUser, .verifying, .blocked:
        true
      case .draft, .reviewReady, .mergeReady, .merged, .completed, .failed, .cancelled:
        false
      }
    }.count
    reviewReadyTasks = state.tasks.filter { $0.status == .reviewReady }.count
    completedTasks = state.tasks.filter { $0.status == .completed || $0.status == .merged }.count
  }

  public func preferredTaskID(for metric: WorkbenchHomeMetricKind, in tasks: [AgentTask]) -> AgentTask.ID? {
    switch metric {
    case .total:
      tasks.first?.id
    case .active:
      tasks.first(where: Self.isActiveTask)?.id
    case .reviewReady:
      tasks.first(where: { $0.status == .reviewReady || $0.status == .mergeReady })?.id
    case .completed:
      tasks.first(where: { $0.status == .completed || $0.status == .merged })?.id
    }
  }

  private static func isActiveTask(_ task: AgentTask) -> Bool {
    switch task.status {
    case .planning, .running, .waitingForApproval, .waitingForUser, .verifying, .blocked:
      true
    case .draft, .reviewReady, .mergeReady, .merged, .completed, .failed, .cancelled:
      false
    }
  }
}
