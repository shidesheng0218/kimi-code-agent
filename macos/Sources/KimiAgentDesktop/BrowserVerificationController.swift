import AppKit
import Foundation
import KimiAgentCore
import WebKit

@MainActor
final class BrowserVerificationController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  private let webView: WKWebView
  private var navigationContinuation: CheckedContinuation<Void, Error>?
  private var consoleMessages: [String] = []

  override init() {
    let userContentController = WKUserContentController()
    let consoleScript = """
    (() => {
      const send = (level, args) => {
        try { window.webkit.messageHandlers.kimiConsole.postMessage({ level, message: Array.from(args).map(String).join(' ') }); } catch (_) {}
      };
      const originalError = console.error;
      console.error = function() { send('error', arguments); return originalError.apply(console, arguments); };
      window.addEventListener('error', event => send('error', [event.message || 'Script error']));
      window.addEventListener('unhandledrejection', event => send('error', [event.reason || 'Unhandled rejection']));
    })();
    """
    userContentController.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = userContentController
    self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
    super.init()
    userContentController.add(WeakScriptMessageHandler(delegate: self), name: "kimiConsole")
    webView.navigationDelegate = self
  }

  func run(plan: BrowserVerificationPlan, artifactsDirectory: URL) async -> BrowserVerificationResult {
    var timeline: [BrowserVerificationTrace] = []
    var artifacts: [BrowserArtifact] = []
    do {
      try FileManager.default.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
      for step in plan.steps {
        if let url = step.url, plan.requiresApproval(for: url) || step.requiresApproval {
          throw BrowserVerificationError.approvalRequired(url.absoluteString)
        }
        try await perform(step, artifactsDirectory: artifactsDirectory, timeline: &timeline, artifacts: &artifacts)
      }
      artifacts.append(contentsOf: consoleArtifacts())
      return BrowserVerificationResult(passed: consoleArtifacts().isEmpty, currentURL: webView.url, artifacts: artifacts, timeline: timeline)
    } catch {
      timeline.append(BrowserVerificationTrace(stepKind: .screenshot, message: "浏览器验证失败：\(error.localizedDescription)"))
      if let screenshot = try? await captureScreenshot(name: "failure", directory: artifactsDirectory) {
        artifacts.append(screenshot)
      }
      artifacts.append(contentsOf: consoleArtifacts())
      if artifacts.isEmpty {
        artifacts.append(BrowserArtifact(kind: .consoleError, name: "browser", text: error.localizedDescription))
      }
      return BrowserVerificationResult(passed: false, currentURL: webView.url, artifacts: artifacts, timeline: timeline)
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if let body = message.body as? [String: Any],
       let level = body["level"] as? String,
       level == "error" {
      consoleMessages.append(body["message"] as? String ?? "Unknown console error")
    }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    navigationContinuation?.resume()
    navigationContinuation = nil
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    navigationContinuation?.resume(throwing: error)
    navigationContinuation = nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    navigationContinuation?.resume(throwing: error)
    navigationContinuation = nil
  }

  private func perform(
    _ step: BrowserVerificationStep,
    artifactsDirectory: URL,
    timeline: inout [BrowserVerificationTrace],
    artifacts: inout [BrowserArtifact]
  ) async throws {
    switch step.kind {
    case .open, .navigate:
      guard let url = step.url else { throw BrowserVerificationError.missingURL }
      try await load(url)
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已打开 \(url.absoluteString)"))
    case .inspect:
      let selector = try requiredSelector(step)
      let exists = try await evaluateBooleanJavaScript("Boolean(document.querySelector(\(jsString(selector))))")
      guard exists else { throw BrowserVerificationError.selectorNotFound(selector) }
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已找到 \(selector)"))
    case .click:
      let selector = try requiredSelector(step)
      let clicked = try await evaluateBooleanJavaScript("""
      (() => {
        const element = document.querySelector(\(jsString(selector)));
        if (!element) return false;
        element.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
        return true;
      })()
      """)
      guard clicked else { throw BrowserVerificationError.selectorNotFound(selector) }
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已点击 \(selector)"))
    case .typeText:
      let selector = try requiredSelector(step)
      let text = step.text ?? ""
      let typed = try await evaluateBooleanJavaScript("""
      (() => {
        const element = document.querySelector(\(jsString(selector)));
        if (!element) return false;
        element.focus();
        element.value = (element.value || '') + \(jsString(text));
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
      """)
      guard typed else { throw BrowserVerificationError.selectorNotFound(selector) }
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已输入 \(text.count) 个字符"))
    case .pressKey:
      let key = step.key ?? "Enter"
      _ = try await evaluateBooleanJavaScript("""
      document.activeElement?.dispatchEvent(new KeyboardEvent('keydown', { key: \(jsString(key)), bubbles: true }));
      """)
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已按键 \(key)"))
    case .scroll:
      let amount = Int(step.text ?? "600") ?? 600
      _ = try await evaluateBooleanJavaScript("window.scrollBy(0, \(amount)); true;")
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已滚动 \(amount)"))
    case .screenshot:
      let artifact = try await captureScreenshot(name: step.artifactName ?? "screenshot", directory: artifactsDirectory)
      artifacts.append(artifact)
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已保存截图 \(artifact.path ?? "")"))
    case .collectConsole:
      artifacts.append(contentsOf: consoleArtifacts())
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已采集控制台错误 \(consoleMessages.count) 条"))
    case .collectNetwork:
      let summary = try await evaluateStringJavaScript("""
      JSON.stringify(performance.getEntriesByType('resource').map(entry => ({ name: entry.name, duration: entry.duration })))
      """)
      artifacts.append(BrowserArtifact(kind: .domSnapshot, name: "network", text: summary))
      timeline.append(BrowserVerificationTrace(stepKind: step.kind, message: "已采集网络请求摘要"))
    }
  }

  private func load(_ url: URL) async throws {
    try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
      navigationContinuation = continuation
      webView.load(URLRequest(url: url))
    }
  }

  private func evaluateBooleanJavaScript(_ script: String) async throws -> Bool {
    try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
      webView.evaluateJavaScript(script) { result, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: (result as? Bool) ?? false)
        }
      }
    }
  }

  private func evaluateStringJavaScript(_ script: String) async throws -> String {
    try await withCheckedThrowingContinuation(isolation: MainActor.shared) { continuation in
      webView.evaluateJavaScript(script) { result, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: (result as? String) ?? "")
        }
      }
    }
  }

  private func captureScreenshot(name: String, directory: URL) async throws -> BrowserArtifact {
    let image: NSImage = try await withCheckedThrowingContinuation(isolation: MainActor.shared) { (continuation: CheckedContinuation<NSImage, Error>) in
      webView.takeSnapshot(with: nil) { image, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let image {
          continuation.resume(returning: image)
        } else {
          continuation.resume(throwing: BrowserVerificationError.screenshotFailed)
        }
      }
    }
    let path = directory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).png")
    guard let data = image.pngData else {
      throw BrowserVerificationError.screenshotFailed
    }
    try data.write(to: path, options: Data.WritingOptions.atomic)
    return BrowserArtifact(kind: .screenshot, name: name, path: path.path)
  }

  private func consoleArtifacts() -> [BrowserArtifact] {
    consoleMessages.map { BrowserArtifact(kind: .consoleError, name: "console", text: $0) }
  }

  private func requiredSelector(_ step: BrowserVerificationStep) throws -> String {
    guard let selector = step.selector, !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BrowserVerificationError.missingSelector
    }
    return selector
  }

  private func jsString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(encoded.dropFirst().dropLast())
  }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  weak var delegate: (any WKScriptMessageHandler)?

  init(delegate: any WKScriptMessageHandler) {
    self.delegate = delegate
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    delegate?.userContentController(userContentController, didReceive: message)
  }
}

private enum BrowserVerificationError: LocalizedError {
  case missingURL
  case missingSelector
  case selectorNotFound(String)
  case approvalRequired(String)
  case screenshotFailed

  var errorDescription: String? {
    switch self {
    case .missingURL: "浏览器步骤缺少 URL。"
    case .missingSelector: "浏览器步骤缺少 selector。"
    case let .selectorNotFound(selector): "未找到元素：\(selector)。"
    case let .approvalRequired(url): "访问 \(url) 需要先加入允许域名或手动审批。"
    case .screenshotFailed: "浏览器截图失败。"
    }
  }
}

private extension NSImage {
  var pngData: Data? {
    guard let tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }
}
