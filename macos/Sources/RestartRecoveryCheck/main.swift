import Foundation
import KimiAgentCore

// Real process-restart recovery acceptance. Two separate process runs share
// one state directory, exercising the production persistence and restore
// paths exactly as an app quit + relaunch would:
//
//   phase1  Creates a file-backed HarnessEventStore + AgentHarness. Runs op1
//           to completion (full intent → permission → receipt flow) and
//           starts op2 whose driver emits a write Intent + tool call and
//           then blocks forever — the process exits with op2 mid-flight,
//           simulating an app kill. Also persists KimiAppStateStore with
//           sessions/messages.
//   phase2  Re-opens the same files in a brand-new process: restores the
//           Harness from the durable event log and the UI state via a fresh
//           KimiAppKernel, then asserts the recovery contract:
//             - op1 stays completed; its settled Receipt is preserved
//               (settled effects must never be replayed)
//             - op2 is restored as suspended (never auto-resumed)
//             - op2's write Intent has NO fabricated Receipt (unknown
//               effects are not invented as successful)
//             - op2's unresolved tool call gets a synthetic interrupted
//               result so a model never waits forever
//             - sessions/messages/activeSessionID survive the restart
//             - restore completes well under the 2s budget
//
// Run locally; deterministic and CI-safe in principle, but kept out of CI
// with the other acceptance tools.

struct PhaseFlags: Sendable {
  let dir: URL
}

func parseDir() -> (String, URL) {
  // Usage: RestartRecoveryCheck <phase1|phase2> <state-dir>
  guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: RestartRecoveryCheck <phase1|phase2> <state-dir>\n".data(using: .utf8)!)
    exit(2)
  }
  return (CommandLine.arguments[1], URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
}

let opIDsFile = "op-ids.json"

struct OpIDs: Codable {
  let settled: UUID
  let interrupted: UUID
  let interruptedEffect: UUID
  let interruptedCall: String
  let harnessSession: UUID
}

// Marks the moment op2's driver has durably emitted its events, so phase1
// can exit only after the on-disk log truly contains them.
final class DriverGate: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  func open() { semaphore.signal() }
  func wait(timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
  }
}

func runPhase1(dir: URL) async throws {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let harnessSession = UUID()
  let eventStoreURL = dir.appendingPathComponent("harness-events.jsonl")
  let store = HarnessEventStore(fileURL: eventStoreURL)
  let gate = DriverGate()

  let driver: AgentHarness.OperationDriver = { context, sink in
    if context.prompt.text.contains("op1-settled") {
      let turnID = UUID()
      await sink(.turnStarted(HarnessTurnRecord(turnID: turnID, modelID: "kimi-smoke")))
      await sink(.assistantMessage(HarnessAssistantMessageRecord(
        turnID: turnID,
        step: 1,
        message: HarnessChatMessage(role: .assistant, content: "op1 完成")
      )))
      let intent = HarnessEffectIntent(
        operationID: context.operationID,
        kind: .tool,
        subject: "write:report.txt",
        risk: .medium
      )
      await sink(.effectIntentWritten(intent))
      await sink(.permissionSettled(HarnessPermissionReceipt(
        operationID: context.operationID,
        requestID: UUID(),
        toolID: "write",
        decision: .allow
      )))
      await sink(.effectStarted(intent))
      await sink(.effectSettled(HarnessEffectReceipt(
        operationID: context.operationID,
        effectID: intent.effectID,
        outcome: .success,
        output: "report.txt written"
      )))
      await sink(.toolResultRecorded(HarnessToolResultRecord(
        turnID: turnID,
        step: 1,
        result: HarnessToolResult(callID: "call-op1", toolName: "write", output: "ok", isError: false)
      )))
      await sink(.turnEnded(HarnessTurnRecord(turnID: turnID, modelID: "kimi-smoke", status: .completed)))
    } else {
      // op2: emit a write Intent + tool call, then block forever — the
      // process will exit with this operation mid-flight.
      let turnID = UUID()
      await sink(.turnStarted(HarnessTurnRecord(turnID: turnID, modelID: "kimi-smoke")))
      await sink(.toolCallDeclared(HarnessToolCallRecord(
        turnID: turnID,
        step: 1,
        call: HarnessToolCall(id: "call-op2", name: "write", argumentsJSON: "{\"path\":\"draft.txt\"}")
      )))
      let intent = HarnessEffectIntent(
        operationID: context.operationID,
        effectID: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF") ?? UUID(),
        kind: .tool,
        subject: "write:draft.txt",
        risk: .medium
      )
      await sink(.effectIntentWritten(intent))
      gate.open()
      try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
  }

  let harness = AgentHarness(sessionID: harnessSession, store: store, driver: driver)

  // op1 runs on .main to completion.
  let op1 = try await harness.prompt(PromptInput(text: "op1-settled"), lane: .main)
  try await harness.wait(for: op1, timeout: 10)
  let op1State = await harness.snapshot().operations[op1]?.state
  guard op1State == .completed else {
    throw NSError(domain: "RestartRecoveryCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "op1 未完成，实际: \(String(describing: op1State))"])
  }

  // op2 starts on a separate lane and blocks mid-flight.
  let op2 = try await harness.prompt(PromptInput(text: "op2-interrupted"), lane: "research")
  guard gate.wait(timeout: 10) else {
    throw NSError(domain: "RestartRecoveryCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "op2 驱动器未能及时发出事件"])
  }

  // Persist UI state the way the app does: sessions, messages, active session.
  let sessionA = KimiSessionSummary(runtimeID: "ses_a", title: "代码审查", status: .completed)
  let sessionB = KimiSessionSummary(runtimeID: "ses_b", title: "联网调研", status: .running)
  var uiState = KimiUIState()
  uiState.sessions = [sessionA, sessionB]
  uiState.activeSessionID = sessionB.id
  uiState.messages = [
    KimiMessage(role: .user, text: "帮我查一下最新资料"),
    KimiMessage(role: .assistant, text: "正在检索公开来源…")
  ]
  let appStore = KimiAppStateStore(fileURL: dir.appendingPathComponent("app-state.json"))
  try appStore.save(KimiPersistedAppState(harnessSessionID: harnessSession, uiState: uiState))

  let opIDs = OpIDs(
    settled: op1,
    interrupted: op2,
    interruptedEffect: UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF") ?? UUID(),
    interruptedCall: "call-op2",
    harnessSession: harnessSession
  )
  try JSONEncoder().encode(opIDs).write(to: dir.appendingPathComponent(opIDsFile), options: .atomic)

  print("PHASE1_OK op1=completed op2=in-flight events=\(await store.events(sessionID: harnessSession).count)")
  // Hard exit: op2's driver is still blocked. This is the app-kill.
  exit(0)
}

func runPhase2(dir: URL) async throws {
  var failures: [String] = []
  var notes: [String] = []

  let opIDs = try JSONDecoder().decode(OpIDs.self, from: Data(contentsOf: dir.appendingPathComponent(opIDsFile)))

  // --- Harness restore from the durable event log ---
  let eventStoreURL = dir.appendingPathComponent("harness-events.jsonl")
  let store = HarnessEventStore(fileURL: eventStoreURL)
  let eventsBefore = await store.events(sessionID: opIDs.harnessSession).count

  let harness = AgentHarness(sessionID: opIDs.harnessSession, store: store)
  let restoreStart = Date()
  try await harness.restore()
  let restoreElapsed = Date().timeIntervalSince(restoreStart)

  let snapshot = await harness.snapshot()

  // op1 must stay completed (never suspended, never replayed).
  if snapshot.operations[opIDs.settled]?.state != .completed {
    failures.append("op1 应保持 completed，实际: \(String(describing: snapshot.operations[opIDs.settled]?.state))")
  }
  let settledReceipts = snapshot.receipts.values.filter { $0.operationID == opIDs.settled && $0.outcome == .success }
  if settledReceipts.isEmpty {
    failures.append("op1 的成功 Receipt 在重启后丢失")
  } else {
    notes.append("op1 成功 Receipt 保留 count=\(settledReceipts.count)")
  }

  // op2 must be suspended, never auto-resumed.
  if snapshot.operations[opIDs.interrupted]?.state != .suspended {
    failures.append("op2 应恢复为 suspended，实际: \(String(describing: snapshot.operations[opIDs.interrupted]?.state))")
  } else {
    notes.append("op2 恢复为 suspended")
  }

  // op2's write Intent must NOT have a fabricated Receipt.
  if snapshot.receipts[opIDs.interruptedEffect] != nil {
    failures.append("op2 的未结算写入 Intent 被伪造了 Receipt")
  } else if snapshot.intents[opIDs.interruptedEffect] == nil {
    failures.append("op2 的写入 Intent 在重启后丢失")
  } else {
    notes.append("op2 未结算 Intent 保留且未伪造 Receipt")
  }

  // op2's unresolved tool call must get a synthetic interrupted result.
  let eventsAfter = await store.events(sessionID: opIDs.harnessSession)
  let syntheticResults = eventsAfter.filter { event in
    guard event.kind == .toolResultRecorded,
          event.operationID == opIDs.interrupted,
          let payload = event.payload,
          let record = try? JSONDecoder().decode(HarnessToolResultRecord.self, from: payload)
    else { return false }
    return record.result.callID == opIDs.interruptedCall && record.result.isError
  }
  if syntheticResults.isEmpty {
    failures.append("op2 未结算 tool call 缺少合成中断结果")
  } else {
    notes.append("op2 未结算 tool call 已写入合成中断结果")
  }

  // Restore must be well under the 2s budget.
  if restoreElapsed > 2.0 {
    failures.append("restore 耗时超过 2s 预算: \(String(format: "%.3f", restoreElapsed))s")
  }
  notes.append("restore 耗时 \(String(format: "%.3f", restoreElapsed))s events=\(eventsBefore)→\(eventsAfter.count)")

  // --- UI state restore through a fresh KimiAppKernel ---
  let appStore = KimiAppStateStore(fileURL: dir.appendingPathComponent("app-state.json"))
  let kernel = KimiAppKernel(persistence: appStore, harnessStore: HarnessEventStore(fileURL: eventStoreURL))
  let ui = await kernel.snapshot()
  if ui.sessions.count != 2 {
    failures.append("会话列表在重启后丢失: count=\(ui.sessions.count)")
  }
  guard let active = ui.sessions.first(where: { $0.id == ui.activeSessionID }) else {
    failures.append("activeSessionID 未恢复")
    throw NSError(domain: "RestartRecoveryCheck", code: 3)
  }
  if active.title != "联网调研" {
    failures.append("活跃会话不是退出前的会话: \(active.title)")
  }
  if ui.messages.count != 2 || ui.messages.first?.text != "帮我查一下最新资料" {
    failures.append("消息历史在重启后丢失或错乱")
  }
  notes.append("UI 状态恢复 sessions=\(ui.sessions.count) active=\(active.title) messages=\(ui.messages.count)")

  if failures.isEmpty {
    print("RESTART_RECOVERY_OK")
    for note in notes { print("  - \(note)") }
    exit(0)
  } else {
    FileHandle.standardError.write(("RESTART_RECOVERY_FAIL: " + failures.joined(separator: "; ") + "\n").data(using: .utf8)!)
    for note in notes { FileHandle.standardError.write(("  - \(note)\n").data(using: .utf8)!) }
    exit(1)
  }
}

let (phase, dir) = parseDir()
Task {
  do {
    switch phase {
    case "phase1": try await runPhase1(dir: dir)
    case "phase2": try await runPhase2(dir: dir)
    default:
      FileHandle.standardError.write("unknown phase: \(phase)\n".data(using: .utf8)!)
      exit(2)
    }
  } catch {
    FileHandle.standardError.write("\(phase.uppercased())_FAIL: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
  }
}
RunLoop.main.run()
