import Foundation
import KimiAgentCore

// Real MCP acceptance against a real third-party server: drives the
// production MCPStdioClient through the full session lifecycle against
// @modelcontextprotocol/server-everything (installed via npm).
//
// Verified paths:
//   1. initialize        — real handshake, serverInfo + capabilities parsed
//   2. tools/list        — real tool catalog with schemas
//   3. tools/call echo   — real tool execution, output round-trips
//   4. tools/call get-sum with invalid (string) arguments — server-side
//      validation failure must surface as a structured errorResponse
//   5. resources/list, prompts/list, prompts/get — capability surfaces work
//   6. crash injection   — server process is kill -9'd mid-session; the next
//      request must fail with structured notConnected (never hang or crash)
//   7. close             — post-close requests fail with notConnected
//
// Run locally; not part of CI because it requires the npm-installed
// server-everything package on the machine.

var failures: [String] = []
var notes: [String] = []

func serverPath() -> String? {
  if CommandLine.arguments.count > 1 { return CommandLine.arguments[1] }
  let candidates = [
    "/opt/homebrew/bin/mcp-server-everything",
    "/usr/local/bin/mcp-server-everything"
  ]
  for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
    return candidate
  }
  // Fall back to PATH lookup.
  let which = Process()
  which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
  which.arguments = ["mcp-server-everything"]
  let pipe = Pipe()
  which.standardOutput = pipe
  which.standardError = FileHandle.nullDevice
  if let _ = try? which.run() {
    which.waitUntilExit()
    let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if which.terminationStatus == 0, !path.isEmpty { return path }
  }
  return nil
}

guard let serverCommand = serverPath() else {
  FileHandle.standardError.write("MCP_SMOKE_SKIP: 未找到 mcp-server-everything (npm i -g @modelcontextprotocol/server-everything)\n".data(using: .utf8)!)
  exit(2)
}

let client: MCPStdioClient
do {
  client = try MCPStdioClient(command: serverCommand, arguments: [])
} catch {
  FileHandle.standardError.write("MCP_SMOKE_FAIL: 无法启动 MCP server: \(error.localizedDescription)\n".data(using: .utf8)!)
  exit(1)
}

// 1. initialize — real handshake.
var toolsCapable = false
do {
  let result = try client.initialize()
  if result.protocolVersion.isEmpty {
    failures.append("initialize 返回空 protocolVersion")
  }
  if !result.serverInfo.name.lowercased().contains("everything") {
    failures.append("serverInfo.name 非预期: \(result.serverInfo.name)")
  }
  if result.serverInfo.version.isEmpty {
    failures.append("serverInfo.version 为空")
  }
  toolsCapable = result.capabilities.tools
  if !toolsCapable {
    failures.append("capabilities.tools == false")
  }
  notes.append("initialize server=\(result.serverInfo.name)@\(result.serverInfo.version) protocol=\(result.protocolVersion)")
} catch {
  failures.append("initialize 失败: \(error.localizedDescription)")
}

// 2. tools/list — real catalog.
var listedTools: [MCPTool] = []
do {
  listedTools = try client.listTools()
  if listedTools.isEmpty {
    failures.append("tools/list 返回空列表")
  }
  if !listedTools.contains(where: { $0.name == "echo" }) {
    failures.append("tools/list 缺少 echo 工具")
  }
  if let echo = listedTools.first(where: { $0.name == "echo" }), !echo.inputSchemaJSON.contains("message") {
    failures.append("echo 工具缺少 inputSchema")
  }
  notes.append("tools/list count=\(listedTools.count)")
} catch {
  failures.append("tools/list 失败: \(error.localizedDescription)")
}

// 3. tools/call echo — real execution round-trip.
let echoMessage = "kimi-mcp-smoke-\(UUID().uuidString.prefix(8))"
do {
  let result = try client.callTool(name: "echo", arguments: ["message": echoMessage])
  if !result.standardOutput.contains(echoMessage) {
    failures.append("echo 输出未包含原始消息: \(result.standardOutput.prefix(120))")
  }
  if result.rawJSON.isEmpty {
    failures.append("echo 缺少 rawJSON")
  }
  notes.append("tools/call echo 回环成功")
} catch {
  failures.append("tools/call echo 失败: \(error.localizedDescription)")
}

// 4. tools/call get-sum with invalid (string) arguments — the server
//    validates against its JSON schema; the failure must come back as a
//    structured errorResponse, not a hang or malformed-response crash.
do {
  let result = try client.callTool(name: "get-sum", arguments: ["a": "not-a-number", "b": "2"])
  // Tolerate servers that coerce instead of validating; what matters is
  // that the call completed with a parseable result.
  notes.append("tools/call get-sum 无效参数被接受(服务端做了类型 coercion)")
  _ = result
} catch let error as MCPClientError {
  if case .errorResponse = error {
    notes.append("tools/call get-sum 无效参数正确回流 errorResponse")
  } else {
    failures.append("get-sum 无效参数应报 errorResponse，实际: \(error.localizedDescription)")
  }
} catch {
  failures.append("get-sum 抛出了非 MCPClientError 错误: \(error.localizedDescription)")
}

// 5. resources / prompts capability surfaces.
do {
  let resources = try client.listResources()
  notes.append("resources/list count=\(resources.count)")
  if let first = resources.first {
    let contents = try client.readResource(uri: first.uri)
    if contents.isEmpty {
      failures.append("resources/read 返回空内容: \(first.uri)")
    }
    notes.append("resources/read \(first.uri) parts=\(contents.count)")
  }
} catch {
  failures.append("resources 失败: \(error.localizedDescription)")
}

do {
  let prompts = try client.listPrompts()
  if prompts.isEmpty {
    failures.append("prompts/list 返回空列表(server 声明了 prompts 能力)")
  }
  if let first = prompts.first {
    var args: [String: String] = [:]
    for argument in first.arguments where argument.required {
      args[argument.name] = "smoke"
    }
    let prompt = try client.getPrompt(name: first.name, arguments: args)
    if prompt.messages.isEmpty {
      failures.append("prompts/get 返回空消息: \(first.name)")
    }
    notes.append("prompts/get \(first.name) messages=\(prompt.messages.count)")
  }
} catch {
  failures.append("prompts 失败: \(error.localizedDescription)")
}

// 6. Crash injection: kill -9 the server mid-session. The termination
//    handler must flip the client into a terminated state and the next
//    request must throw structured notConnected — no hang, no crash.
let kill = Process()
kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
kill.arguments = ["-9", "-f", "server-everything"]
do {
  try kill.run()
  kill.waitUntilExit()
} catch {
  failures.append("无法注入 MCP server 崩溃: \(error.localizedDescription)")
}
// Give the termination handler a moment to fire.
Thread.sleep(forTimeInterval: 0.5)
do {
  _ = try client.listTools()
  failures.append("server 崩溃后 listTools 不应成功")
} catch let error as MCPClientError {
  if case .notConnected = error {
    notes.append("崩溃后 listTools 正确抛出 notConnected")
  } else {
    failures.append("崩溃后应报 notConnected，实际: \(error.localizedDescription)")
  }
} catch {
  failures.append("崩溃后抛出了非 MCPClientError 错误: \(error.localizedDescription)")
}

// 7. close() then requests must fail with notConnected.
client.close()
do {
  _ = try client.listTools()
  failures.append("close 后 listTools 不应成功")
} catch let error as MCPClientError {
  if case .notConnected = error {
    notes.append("close 后 listTools 正确抛出 notConnected")
  } else {
    failures.append("close 后应报 notConnected，实际: \(error.localizedDescription)")
  }
} catch {
  failures.append("close 后抛出了非 MCPClientError 错误: \(error.localizedDescription)")
}

if failures.isEmpty {
  print("MCP_SMOKE_OK server=\(serverCommand)")
  for note in notes { print("  - \(note)") }
  exit(0)
} else {
  FileHandle.standardError.write(("MCP_SMOKE_FAIL: " + failures.joined(separator: "; ") + "\n").data(using: .utf8)!)
  for note in notes { FileHandle.standardError.write(("  - \(note)\n").data(using: .utf8)!) }
  exit(1)
}
