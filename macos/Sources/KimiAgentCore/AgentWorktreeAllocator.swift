import Foundation

/// Assigns deterministic, non-overlapping paths to write-capable DAG nodes.
/// The allocator is deliberately pure: Git creation/removal stays in the
/// platform adapter, while the scheduler persists these paths as part of the
/// run checkpoint before a worker starts.
public enum AgentWorktreeAllocator {
  public static func assign(runs: [AgentRun], rootDirectory: URL) -> [AgentRun] {
    let continuationKinds: Set<AgentKind> = [
      .test,
      .review,
      .debug,
      .browser,
      .browserVerification
    ]
    var paths: [UUID: String] = [:]
    for run in runs {
      if let path = run.worktreePath, !path.isEmpty {
        paths[run.id] = path
      }
    }

    // Resolve dependencies until every path that can be inherited has been
    // assigned. This also handles a snapshot whose runs are not topologically
    // sorted, which is common after durable event replay.
    var changed = true
    while changed {
      changed = false
      for run in runs where paths[run.id] == nil {
        if continuationKinds.contains(run.definition.kind),
           let inherited = run.dependencies.compactMap({ paths[$0] }).first {
          paths[run.id] = inherited
          changed = true
          continue
        }
        if run.definition.isolation == .worktree {
          let shortID = String(run.id.uuidString.prefix(8)).lowercased()
          paths[run.id] = rootDirectory
            .appendingPathComponent("run-" + shortID, isDirectory: true)
            .path
          changed = true
        }
      }
    }

    return runs.map { run in
      var assigned = run
      assigned.worktreePath = paths[run.id]
      return assigned
    }
  }
}
