import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import KimiAgentCore

// Real Computer Use acceptance: drives the production
// ComputerUseController.executeHarnessRequest path end to end.
//
// Verified paths:
//   1. computer_use.inspect      — always succeeds, reports diagnostics
//   2. computer_use.screenshot   — with Screen Recording granted: saves a real
//      PNG and validates its size; without permission: must fail with the
//      structured screenCapturePermissionRequired error (never a crash)
//   3. computer_use.click        — missing coordinates must be rejected by
//      schema validation; without Accessibility permission the structured
//      accessibilityPermissionRequired error must surface
//   4. computer_use.type_text    — empty text rejected
//   5. computer_use.press_key    — unsupported key rejected
//   6. unknown tool              — unsupportedTool rejected
//
// Real click/type events are never posted by this check: they would move the
// user's actual mouse/keyboard focus. When Accessibility IS granted those
// paths are reported as SKIPPED_GRANTED instead of executed.
//
// Run locally (needs a window server for ScreenCaptureKit); not part of CI
// because TCC permission state is machine-specific.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let sessionID = UUID()
let taskID = UUID()

func makeRequest(_ toolID: String, input: [String: String] = [:]) -> ToolExecutionRequest {
  ToolExecutionRequest(taskID: taskID, sessionID: sessionID, agentID: "computer-use-smoke", toolID: toolID, input: input)
}

Task { @MainActor in
  var failures: [String] = []
  var notes: [String] = []

  // 1. inspect — must always succeed and report both permission dimensions.
  do {
    let result = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.inspect"))
    if !result.output.contains("辅助功能") || !result.output.contains("屏幕录制") {
      failures.append("inspect 输出缺少权限诊断: \(result.output)")
    }
    if result.metadata["adapter"] != "computer-use" {
      failures.append("inspect 缺少 adapter 元数据")
    }
    notes.append("inspect ready=\(result.metadata["ready"] ?? "?")")
  } catch {
    failures.append("inspect 不应失败: \(error.localizedDescription)")
  }

  // 2. screenshot — real capture when permitted, structured error otherwise.
  let screenGranted = CGPreflightScreenCaptureAccess()
  do {
    let result = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.screenshot"))
    if !screenGranted {
      failures.append("无屏幕录制权限时 screenshot 不应成功")
    }
    guard let path = result.metadata["path"] else {
      failures.append("screenshot 缺少 path 元数据")
      exit(1)
    }
    let url = URL(fileURLWithPath: path)
    if let data = try? Data(contentsOf: url) {
      if data.count <= 1_000 {
        failures.append("screenshot 文件为空或过小: \(data.count) bytes")
      }
      if let image = NSImage(contentsOf: url) {
        if image.size.width < 100 {
          failures.append("screenshot 尺寸异常: \(image.size)")
        }
      } else {
        failures.append("screenshot 不是有效 PNG")
      }
      notes.append("screenshot=\(path) bytes=\(data.count)")
    } else {
      failures.append("screenshot 文件不可读: \(path)")
    }
  } catch let error as ComputerUseError {
    if error == .screenCapturePermissionRequired && !screenGranted {
      notes.append("screenshot 权限拒绝路径正确(screenCapturePermissionRequired)")
    } else {
      failures.append("screenshot 抛出了非预期错误: \(error.localizedDescription)")
    }
  } catch {
    failures.append("screenshot 抛出了非结构化错误: \(error.localizedDescription)")
  }

  // 3. click — schema validation first; permission gate second.
  do {
    _ = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.click"))
    failures.append("缺少坐标的 click 不应成功")
  } catch let error as ComputerUseError {
    if error != .missingCoordinate {
      failures.append("缺少坐标的 click 应报 missingCoordinate，实际: \(error.localizedDescription)")
    }
  } catch {
    failures.append("click 参数校验抛出了非结构化错误: \(error.localizedDescription)")
  }

  let accessibilityGranted = AXIsProcessTrusted()
  if accessibilityGranted {
    // Never post a real click: it would land on the user's actual screen.
    notes.append("click 真实投递 SKIPPED_GRANTED(辅助功能已授权, 检查不投递真实事件)")
  } else {
    do {
      _ = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.click", input: ["x": "1", "y": "1"]))
      failures.append("无辅助功能权限时 click 不应成功")
    } catch let error as ComputerUseError {
      if error == .accessibilityPermissionRequired {
        notes.append("click 权限拒绝路径正确(accessibilityPermissionRequired)")
      } else {
        failures.append("click 抛出了非预期错误: \(error.localizedDescription)")
      }
    } catch {
      failures.append("click 抛出了非结构化错误: \(error.localizedDescription)")
    }
  }

  // 4. type_text — empty text rejected before any event is posted.
  do {
    _ = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.type_text", input: ["text": ""]))
    failures.append("空 text 的 type_text 不应成功")
  } catch let error as ComputerUseError {
    if error != .missingText {
      failures.append("空 text 的 type_text 应报 missingText，实际: \(error.localizedDescription)")
    }
  } catch {
    failures.append("type_text 抛出了非结构化错误: \(error.localizedDescription)")
  }

  // 5. press_key — unsupported key rejected.
  do {
    _ = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.press_key", input: ["key": "f13"]))
    failures.append("不支持按键的 press_key 不应成功")
  } catch let error as ComputerUseError {
    if case .unsupportedKey = error {} else {
      failures.append("press_key 应报 unsupportedKey，实际: \(error.localizedDescription)")
    }
  } catch {
    failures.append("press_key 抛出了非结构化错误: \(error.localizedDescription)")
  }

  // 6. unknown tool rejected.
  do {
    _ = try await ComputerUseController.executeHarnessRequest(makeRequest("computer_use.definitely_not_a_tool"))
    failures.append("未知工具不应成功")
  } catch let error as ComputerUseError {
    if case .unsupportedTool = error {} else {
      failures.append("未知工具应报 unsupportedTool，实际: \(error.localizedDescription)")
    }
  } catch {
    failures.append("未知工具抛出了非结构化错误: \(error.localizedDescription)")
  }

  if failures.isEmpty {
    print("COMPUTER_USE_SMOKE_OK screenGranted=\(screenGranted) accessibilityGranted=\(accessibilityGranted)")
    for note in notes { print("  - \(note)") }
    exit(0)
  } else {
    FileHandle.standardError.write(("COMPUTER_USE_SMOKE_FAIL: " + failures.joined(separator: "; ") + "\n").data(using: .utf8)!)
    for note in notes { FileHandle.standardError.write(("  - \(note)\n").data(using: .utf8)!) }
    exit(1)
  }
}

app.run()
