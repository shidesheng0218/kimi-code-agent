import Foundation

/// A durable, dependency-aware projection of the agent work required for one
/// task. It contains no runtime handles, so it is safe to persist and resume.
public struct TaskGraph: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let taskID: UUID
  public let sessionID: UUID
  public let nodes: [TaskGraphNode]

  public init(id: UUID = UUID(), taskID: UUID, sessionID: UUID, nodes: [TaskGraphNode]) {
    self.id = id
    self.taskID = taskID
    self.sessionID = sessionID
    self.nodes = nodes
  }
}

public struct TaskGraphNode: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let stage: AgentKind
  public let dependencies: [UUID]
  public let definition: AgentDefinition

  public init(id: UUID = UUID(), stage: AgentKind, dependencies: [UUID], definition: AgentDefinition) {
    self.id = id
    self.stage = stage
    self.dependencies = dependencies
    self.definition = definition
  }
}

/// Compiles a user contract to the smallest safe execution graph. The compiler
/// deliberately produces no graph for ordinary conversation and explanation.
public enum TaskGraphCompiler {
  public static func compile(taskID: UUID, sessionID: UUID, contract: TaskContract, model: String? = nil) -> TaskGraph {
    let stages: [AgentKind]
    switch contract.intent {
    case .conversation, .explanation:
      stages = []
    case .explore:
      stages = [.explore]
    case .webResearch:
      stages = [.webResearch]
    case .plan:
      stages = [.explore, .plan, .review]
    case .implement:
      stages = [.explore, .plan, .implement, .test, .review]
    case .debug:
      stages = [.explore, .debug, .test, .review]
    case .review:
      stages = [.explore, .review]
    case .test:
      stages = [.explore, .test, .review]
    case .browserVerification:
      // Browser verification is already a scoped, read-only specialized
      // operation. Running a generic Explore first adds no value and can
      // incorrectly block the real Browser adapter on an unrelated search.
      stages = [.browserVerification]
    case .computerUse:
      // Computer Use must inspect the target directly. Do not make it depend
      // on repository search before the system adapter can run.
      stages = [.computerUse]
    case .externalCollaboration:
      stages = [.explore, .plan, .review]
    }

    var nodes: [TaskGraphNode] = []
    for stage in stages {
      let dependencies: [UUID]
      switch stage {
      case .explore:
        dependencies = []
      case .webResearch:
        dependencies = []
      case .review where contract.intent == .implement:
        dependencies = nodes.filter { $0.stage == .implement || $0.stage == .test }.map(\.id)
      case .review:
        dependencies = nodes.last.map { [$0.id] } ?? []
      default:
        dependencies = nodes.last.map { [$0.id] } ?? []
      }
      nodes.append(TaskGraphNode(
        stage: stage,
        dependencies: dependencies,
        definition: AgentOrchestrator.builtInDefinition(for: stage, model: model)
      ))
    }
    return TaskGraph(taskID: taskID, sessionID: sessionID, nodes: nodes)
  }

  public static func plan(from graph: TaskGraph) -> AgentOrchestrationPlan {
    AgentOrchestrationPlan(
      taskID: graph.taskID,
      sessionID: graph.sessionID,
      runs: graph.nodes.map { node in
        AgentRun(
          id: node.id,
          parentSessionID: graph.sessionID,
          taskID: graph.taskID,
          definition: node.definition,
          dependencies: node.dependencies
        )
      }
    )
  }
}
