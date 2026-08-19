import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ComputerUseController {
  public static func diagnostics(promptForAccessibility: Bool = false) -> (isReady: Bool, message: String) {
    let accessibilityGranted = AXIsProcessTrusted()
    let screenCaptureGranted = CGPreflightScreenCaptureAccess()
    let ready = accessibilityGranted && screenCaptureGranted
    let accessibility = accessibilityGranted ? "辅助功能：已授权" : "辅助功能：未授权"
    let screenCapture = screenCaptureGranted ? "屏幕录制：已授权" : "屏幕录制：未授权"
    return (ready, "\(accessibility)\n\(screenCapture)\n高风险 Computer Use 操作仍会逐步请求确认。")
  }

  public static func click(at point: CGPoint) throws {
    guard ComputerUsePolicy.decision(for: .click) == .allow else { return }
    guard AXIsProcessTrusted() else { throw ComputerUseError.accessibilityPermissionRequired }
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
          let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
      throw ComputerUseError.eventCreationFailed
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  public static func type(_ text: String) throws {
    guard ComputerUsePolicy.decision(for: .typeText) == .allow else { return }
    guard AXIsProcessTrusted() else { throw ComputerUseError.accessibilityPermissionRequired }
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
      throw ComputerUseError.eventCreationFailed
    }
    let utf16 = Array(text.utf16)
    event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
    event.post(tap: .cghidEventTap)
  }

  public static func executeHarnessRequest(_ request: ToolExecutionRequest) async throws -> ToolExecutionResult {
    switch request.toolID {
    case "computer_use.inspect":
      let diagnostics = diagnostics(promptForAccessibility: false)
      return ToolExecutionResult(output: diagnostics.message, metadata: ["ready": diagnostics.isReady ? "true" : "false", "adapter": "computer-use"])
    case "computer_use.screenshot":
      guard CGPreflightScreenCaptureAccess() else { throw ComputerUseError.screenCapturePermissionRequired }
      let image = try await captureScreenImage()
      guard let image else { throw ComputerUseError.screenshotFailed }
      let bitmap = NSBitmapImageRep(cgImage: image)
      guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ComputerUseError.screenshotFailed }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-computer-use", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let path = directory.appendingPathComponent("screenshot-\(UUID().uuidString).png")
      try data.write(to: path, options: .atomic)
      return ToolExecutionResult(output: "已保存屏幕截图：\(path.path)", metadata: ["path": path.path, "adapter": "computer-use"])
    case "computer_use.click", "computer_use.click_element":
      guard let x = Double(request.input["x"] ?? ""), let y = Double(request.input["y"] ?? "") else {
        throw ComputerUseError.missingCoordinate
      }
      try click(at: CGPoint(x: x, y: y))
      return ToolExecutionResult(output: "已点击 (\(Int(x)), \(Int(y)))", metadata: ["adapter": "computer-use"])
    case "computer_use.type_text":
      guard let text = request.input["text"], !text.isEmpty else { throw ComputerUseError.missingText }
      try type(text)
      return ToolExecutionResult(output: "已输入 \(text.count) 个字符", metadata: ["adapter": "computer-use"])
    case "computer_use.press_key":
      let key = request.input["key"] ?? "Return"
      try press(key: key)
      return ToolExecutionResult(output: "已按键 \(key)", metadata: ["adapter": "computer-use"])
    default:
      throw ComputerUseError.unsupportedTool(request.toolID)
    }
  }

  private static func captureScreenImage() async throws -> CGImage? {
    let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = shareableContent.displays.first else { throw ComputerUseError.screenshotFailed }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.showsCursor = true
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
  }

  private static func press(key: String) throws {
    guard AXIsProcessTrusted() else { throw ComputerUseError.accessibilityPermissionRequired }
    let keyCode: CGKeyCode
    switch key.lowercased() {
    case "return", "enter": keyCode = 36
    case "tab": keyCode = 48
    case "escape", "esc": keyCode = 53
    case "space": keyCode = 49
    case "backspace", "delete": keyCode = 51
    case "left": keyCode = 123
    case "right": keyCode = 124
    case "down": keyCode = 125
    case "up": keyCode = 126
    default: throw ComputerUseError.unsupportedKey(key)
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
      throw ComputerUseError.eventCreationFailed
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
}

public enum ComputerUseError: LocalizedError, Equatable, Sendable {
  case accessibilityPermissionRequired
  case screenCapturePermissionRequired
  case eventCreationFailed
  case screenshotFailed
  case missingCoordinate
  case missingText
  case unsupportedKey(String)
  case unsupportedTool(String)

  public var errorDescription: String? {
    switch self {
    case .accessibilityPermissionRequired: "需要在系统设置中授予辅助功能权限。"
    case .screenCapturePermissionRequired: "需要在系统设置中授予屏幕录制权限。"
    case .eventCreationFailed: "无法创建系统输入事件。"
    case .screenshotFailed: "无法保存当前屏幕截图。"
    case .missingCoordinate: "点击操作需要 x 和 y 坐标。"
    case .missingText: "输入操作缺少 text。"
    case let .unsupportedKey(key): "暂不支持按键：\(key)"
    case let .unsupportedTool(tool): "暂不支持 Computer Use 工具：\(tool)"
    }
  }
}
