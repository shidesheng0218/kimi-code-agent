import AppKit
import Foundation
import Network
import KimiAgentCore

// Real end-to-end Browser acceptance: serve a page over loopback HTTP, drive
// the production BrowserVerificationController (off-screen WKWebView) through
// open → inspect → screenshot → collectConsole, and assert a passing result
// with a real on-disk screenshot artifact. Run locally (needs a window server);
// not part of CI because it requires GUI + a live WKWebView.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class SmokeHTTPServer {
  private var listener: NWListener?
  private(set) var port: Int = 0

  func start() throws {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    listener.newConnectionHandler = { connection in
      connection.start(queue: .main)
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
        let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let (status, body): (String, String)
        if request.contains("GET / ") {
          status = "200 OK"
          body = "<html><head><title>smoke</title></head><body><h1>KimiBrowserOK</h1><p>real page</p></body></html>"
        } else {
          status = "404 Not Found"
          body = "not found"
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.stateUpdateHandler = { state in
      if case .ready = state { /* port read below after start */ }
    }
    listener.start(queue: .main)
    // Wait for the listener to become ready so the assigned port is valid.
    let deadline = Date().addingTimeInterval(5)
    while listener.state != .ready && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    guard case .ready = listener.state, let assigned = listener.port?.rawValue else {
      throw NSError(domain: "SmokeHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "local HTTP server did not become ready"])
    }
    self.port = Int(assigned)
  }
}

let server = SmokeHTTPServer()
do {
  try server.start()
} catch {
  FileHandle.standardError.write("FAIL: 无法启动本地 HTTP server: \(error.localizedDescription)\n".data(using: .utf8)!)
  exit(1)
}

Task { @MainActor in
  let artifactsDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("kimi-browser-smoke-\(UUID().uuidString)", isDirectory: true)
  let baseURL = URL(string: "http://127.0.0.1:\(server.port)/")!
  let plan = BrowserVerificationPlan(
    allowedDomains: ["127.0.0.1", "localhost"],
    steps: [
      BrowserVerificationStep(kind: .open, url: baseURL),
      BrowserVerificationStep(kind: .inspect, selector: "h1"),
      BrowserVerificationStep(kind: .screenshot, artifactName: "smoke"),
      BrowserVerificationStep(kind: .collectConsole)
    ]
  )

  let controller = BrowserVerificationController()
  let result = await controller.run(plan: plan, artifactsDirectory: artifactsDir)

  var failures: [String] = []
  if !result.passed { failures.append("result.passed == false") }
  if result.currentURL?.absoluteString != baseURL.absoluteString {
    failures.append("currentURL 不匹配: \(result.currentURL?.absoluteString ?? "nil")")
  }
  let screenshots = result.artifacts.filter { $0.kind == .screenshot }
  var shotPath = ""
  var shotBytes = 0
  if let shot = screenshots.first, let path = shot.path {
    shotPath = path
    let shotURL = URL(fileURLWithPath: path)
    if let data = try? Data(contentsOf: shotURL) {
      shotBytes = data.count
      if data.count <= 1_000 { failures.append("screenshot 文件为空或过小") }
    } else {
      failures.append("screenshot 文件不可读")
    }
    if let image = NSImage(contentsOf: shotURL), image.size.width < 100 {
      failures.append("screenshot 尺寸异常: \(image.size)")
    }
  } else {
    failures.append("缺少 screenshot artifact")
  }

  if failures.isEmpty {
    print("BROWSER_SMOKE_OK url=\(baseURL.absoluteString) screenshot=\(shotPath) bytes=\(shotBytes)")
    exit(0)
  } else {
    FileHandle.standardError.write(("BROWSER_SMOKE_FAIL: " + failures.joined(separator: "; ") + "\n").data(using: .utf8)!)
    exit(1)
  }
}

app.run()
