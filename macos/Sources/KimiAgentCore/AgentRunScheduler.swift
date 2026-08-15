import Foundation

public struct AgentRunSchedulerSnapshot: Codable, Equatable, Sendable {
  public let runs: [AgentRun]
  public let maxConcurrent: Int
  public let capturedAt: Date

  public init(runs: [AgentRun], maxConcurrent: Int, capturedAt: Date = .now) {
    self.runs = runs
    self.maxConcurrent = min(max(maxConcurrent, 1), 8)
    self.capturedAt = capturedAt
  }
}

/// Deterministic DAG scheduler for independent agent runs. It owns scheduling
/// state and a durable checkpoint. The actual effect executor is injected by
/// the Harness boundary, while UI code only consumes the resulting snapshot.
public actor AgentRunScheduler {
  public typealias Executor = @Sendable (AgentRun) async throws -> AgentResult
  public typealias SnapshotSink = @Sendable ([AgentRun]) -> Void

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

  public init(snapshot: AgentRunSchedulerSnapshot) {
    self.runsByID = Dictionary(uniqueKeysWithValues: snapshot.runs.map { run in
      var restored = run
      if restored.state == .running || restored.state == .awaitingApproval {
        restored.state = .interrupted
        restored.errorMessage = "应用重启前 Worker 尚未结算，等待用户继续。"
        restored.updatedAt = .now
      }
      return (restored.id, restored)
    })
    self.maxConcurrent = min(max(snapshot.maxConcurrent, 1), 8)
  }

  public func scheduleReady() -> [AgentRun] {
    let runs = orderedRuns
    let completed = Set(runs.filter { $0.state == .completed }.map(\.id))
    let runningCount = runs.filter { $0.state == .running || $0.state == .awaitingApproval }.count
    let capacity = max(0, maxConcurrent - runningCount)
    guard capacity > 0 else { return [] }
    var scheduled: [AgentRun] = []
    var occupiedWorktrees = Set(
      runs
        .filter { ($0.state == .running || $0.state == .awaitingApproval) && isWriteLike($0) }
        .compactMap(\.worktreePath)
    )
    for var run in runs where scheduled.count < capacity {
      guard run.state == .queued,
            Set(run.dependencies).isSubset(of: completed) else { continue }
      if isWriteLike(run), let worktree = run.worktreePath {
        // A Worktree is a write resource, not merely metadata. Reserve it as
        // soon as the first node is accepted so a second implement/debug run
        // cannot race it in the same scheduling tick.
        guard !occupiedWorktrees.contains(worktree) else { continue }
        occupiedWorktrees.insert(worktree)
      }
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
  public func drive(
    execute: @escaping Executor,
    onUpdate: @escaping SnapshotSink = { _ in }
  ) async throws -> [AgentRun] {
    onUpdate(orderedRuns)
    while true {
      let ready = scheduleReady()
      if ready.isEmpty {
        let active = runsByID.values.contains { $0.state == .running || $0.state == .awaitingApproval }
        if !active { break }
        await Task.yield()
        continue
      }

      onUpdate(orderedRuns)

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
          onUpdate(orderedRuns)
        }
      }
    }
    onUpdate(orderedRuns)
    return orderedRuns
  }

  /// Associates the durable Child Session with its scheduler node before the
  /// Child Agent starts its first provider/tool effect. This makes the
  /// relationship recoverable without letting UI state become authoritative.
  public func attachChildSession(_ childSessionID: UUID, to runID: UUID) {
    mutate(runID) { run in
      guard !run.state.isTerminal else { return }
      run.childSessionID = childSessionID
    }
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

  /// A failed node may be retried independently. Its downstream dependencies
  /// remain blocked until this exact node settles successfully.
  public func retry(_ id: UUID) {
    mutate(id) { run in
      guard run.state == .failed else { return }
      run.state = .queued
      run.progress = 0
      run.result = nil
      run.errorMessage = nil
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

  public func snapshotRecord() -> AgentRunSchedulerSnapshot {
    AgentRunSchedulerSnapshot(runs: orderedRuns, maxConcurrent: maxConcurrent)
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

  private func isWriteLike(_ run: AgentRun) -> Bool {
    switch run.definition.kind {
    case .implement, .debug:
      return true
    default:
      return run.definition.isolation == .worktree
    }
  }
}
