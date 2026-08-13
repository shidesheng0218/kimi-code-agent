import Foundation

public struct AgentExecutionPlan: Codable, Equatable, Sendable {
  public let taskID: UUID
  public let workItems: [WorkItem]

  public init(taskID: UUID, workItems: [WorkItem]) {
    self.taskID = taskID
    self.workItems = workItems
  }
}

public enum TaskSupervisor {
  public static func makePlan(taskID: UUID, mode: TaskMode) -> AgentExecutionPlan {
    let analyzer = WorkItem(parentID: taskID, role: .analyzer)
    let implementer: WorkItem?
    if mode.isReadOnly {
      implementer = nil
    } else {
      implementer = WorkItem(parentID: taskID, role: .implementer, dependencies: [analyzer.id])
    }

    let testRunner: WorkItem?
    let reviewer: WorkItem
    if let implementer {
      testRunner = WorkItem(parentID: taskID, role: .testRunner, dependencies: [implementer.id])
      reviewer = WorkItem(parentID: taskID, role: .reviewer, dependencies: [implementer.id, testRunner!.id])
    } else {
      testRunner = nil
      reviewer = WorkItem(parentID: taskID, role: .reviewer, dependencies: [analyzer.id])
    }

    return AgentExecutionPlan(
      taskID: taskID,
      workItems: [analyzer] + [implementer, testRunner].compactMap { $0 } + [reviewer]
    )
  }
}
