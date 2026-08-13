import Foundation

/// Deterministic DAG scheduler for independent agent runs. It owns scheduling
/// state only; DesktopAppModel remains responsible for launching the selected
/// runtime and persisting its compatibility task snapshot.
public actor AgentRunScheduler {
  public typealias Executor = @Sendable (AgentRun) async throws -> AgentResult

  private struct ExecutionOutcome: Sendable {
    let id: UUID
    let result: AgentResult?
    let errorMessage: String?
  }

  private var runsByID: [UUID: AgentRun]
  private let maxConcurrent: Int

  public init(runs: [AgentRun], maxConcurrent: Int = 8) {
    self.runsByID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
    self.maxConcurrent = max(1, min(maxConcurrent, 8))
  }

  public func scheduleReady() -> [AgentRun] {
    let runs = orderedRuns
    let completed = Set(runs.filter { $0.state == .completed }.map(\.id))
    let runningCount = runs.filter { $0.state == .running || $0.state == .awaitingApproval }.count
    let capacity = max(0, maxConcurrent - runningCount)
    guard capacity > 0 else { return [] }
    let selected = runs
      .filter { $0.state == .queued && Set($0.dependencies).isSubset(of: completed) }
      .prefix(capacity)
    var scheduled: [AgentRun] = []
    for var run in selected {
      run.state = .running
      run.progress = max(run.progress, 0.01)
      run.updatedAt = .now
      runsByID[run.id] = run
      scheduled.append(run)
    }
    return scheduled
  }

  /// Drives the ready queue until no more safe work can be scheduled. The
  /// executor is supplied by the desktop layer and normally creates/runs a
  /// real ChildSessionCoordinator session. Scheduler state is updated only
  /// after the executor settles, which makes the method resumable and keeps
  /// dependency release deterministic.
  public func drive(execute: @escaping Executor) async throws -> [AgentRun] {
    while true {
      let ready = scheduleReady()
      if ready.isEmpty {
        let active = runsByID.values.contains { $0.state == .running || $0.state == .awaitingApproval }
        if !active { break }
        await Task.yield()
        continue
      }

      await withTaskGroup(of: ExecutionOutcome.self) { group in
        for run in ready {
          group.addTask {
            do {
              return ExecutionOutcome(id: run.id, result: try await execute(run), errorMessage: nil)
            } catch {
              return ExecutionOutcome(id: run.id, result: nil, errorMessage: error.localizedDescription)
            }
          }
        }
        for await outcome in group {
          if let result = outcome.result {
            complete(outcome.id, result: result)
          } else {
            fail(outcome.id, message: outcome.errorMessage ?? "Child Agent 执行失败。")
          }
        }
      }
    }
    return orderedRuns
  }

  public func complete(_ id: UUID, result: AgentResult) {
    mutate(id) { run in
      // A user cancel/pause must not be overwritten by the in-flight task
      // group settling after the fact.
      guard run.state == .running || run.state == .awaitingApproval else { return }
      run.state = .completed
      run.progress = 1
      run.result = result
      run.errorMessage = nil
    }
  }

  public func fail(_ id: UUID, message: String) {
    mutate(id) { run in
      guard run.state == .running || run.state == .awaitingApproval else { return }
      run.state = .failed
      run.errorMessage = message
    }
  }

  public func pause(_ id: UUID) {
    mutate(id) { run in
      guard run.state == .running else { return }
      run.state = .paused
    }
  }

  public func resume(_ id: UUID) {
    mutate(id) { run in
      guard run.state == .paused || run.state == .interrupted else { return }
      run.state = .queued
    }
  }

  public func cancel(_ id: UUID) {
    mutate(id) { run in
      guard !run.state.isTerminal else { return }
      run.state = .cancelled
    }
  }

  public func snapshot() -> [AgentRun] {
    orderedRuns
  }

  private var orderedRuns: [AgentRun] {
    runsByID.values.sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func mutate(_ id: UUID, _ update: (inout AgentRun) -> Void) {
    guard var run = runsByID[id] else { return }
    update(&run)
    run.updatedAt = .now
    runsByID[id] = run
  }
}
