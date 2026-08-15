import Foundation

/// Decides whether a persisted task really represents a Supervisor graph.
/// Migration may synthesize AgentRun records for old conversations, so the
/// intent is part of the recovery contract rather than inferred from runs
/// alone.
public enum AgentGraphRecoveryPolicy {
  public static func shouldRestoreGraph(decision: IntentDecision, runs: [AgentRun]) -> Bool {
    decision.requiresPlanning && runs.contains { !$0.state.isTerminal }
  }
}
