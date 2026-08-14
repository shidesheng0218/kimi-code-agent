"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/runtime/nativeAgentHost.ts
var nativeAgentHost_exports = {};
__export(nativeAgentHost_exports, {
  mapSdkEvent: () => mapSdkEvent
});
module.exports = __toCommonJS(nativeAgentHost_exports);
var import_node_crypto2 = require("node:crypto");
var import_node_child_process = require("node:child_process");
var import_node_readline = require("node:readline");

// src/runtime/acpProtocol.ts
var import_node_crypto = require("node:crypto");
function buildAcpInitializeRequest(id) {
  return {
    jsonrpc: "2.0",
    id,
    method: "initialize",
    params: {
      protocolVersion: 1,
      clientInfo: { name: "kimi-agent-desktop", version: "0.3.0" },
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
        auth: { terminal: true }
      }
    }
  };
}
function buildAcpPromptRequest(id, sessionId, prompt) {
  return {
    jsonrpc: "2.0",
    id,
    method: "session/prompt",
    params: { sessionId, prompt: [{ type: "text", text: prompt }] }
  };
}
function buildAcpPermissionResponse(id, response) {
  const outcome = response === "reject" ? { outcome: "cancelled" } : { outcome: "selected", optionId: response === "approve_for_session" ? "allow_always" : "allow_once" };
  return { jsonrpc: "2.0", id, result: outcome };
}
function mapAcpMessageToDesktopEvents(message, context) {
  if (message.method === "session/request_permission") {
    const params2 = asRecord(message.params);
    const toolCall = asRecord(params2.toolCall);
    return [event(context, context.sequence + 1, "permissionRequested", {
      id: String(message.id ?? ""),
      action: String(toolCall.title ?? toolCall.kind ?? "Tool"),
      description: permissionDescription(toolCall, params2)
    }, true)];
  }
  if (message.method !== "session/update") return [];
  const params = asRecord(message.params);
  const update = asRecord(params.update);
  return mapSessionUpdate(update, context);
}
function mapSessionUpdate(update, context) {
  const sessionUpdate = String(update.sessionUpdate ?? "");
  const sequence = context.sequence + 1;
  if (sessionUpdate === "agent_message_chunk" || sessionUpdate === "assistant_message_chunk") {
    const content = asRecord(update.content);
    const text = String(content.text ?? "");
    return text ? [event(context, sequence, "output", { text, contentType: String(content.type ?? "text") })] : [];
  }
  if (sessionUpdate === "agent_thought_chunk" || sessionUpdate === "thinking_chunk") {
    const content = asRecord(update.content);
    const text = String(content.text ?? "");
    return text ? [event(context, sequence, "output", { text, contentType: "thinking" })] : [];
  }
  if (sessionUpdate === "tool_call" || sessionUpdate === "tool_call_update") {
    const toolCallId = String(update.toolCallId ?? "");
    const title = String(update.title ?? update.name ?? update.kind ?? "Tool");
    const status = String(update.status ?? "pending");
    const kind = status === "completed" || status === "failed" ? "toolFinished" : status === "in_progress" ? "toolStarted" : "toolRequested";
    const payload = {
      id: toolCallId,
      name: title,
      status,
      arguments: stringify(update.rawInput)
    };
    const output = update.rawOutput ?? update.content;
    if (output !== void 0) payload.output = stringify(output);
    const research = researchPayload(title, output);
    Object.assign(payload, research);
    return [event(context, sequence, kind, payload)];
  }
  if (sessionUpdate === "plan") {
    return [event(context, sequence, "taskPlanned", { plan: stringify(update) })];
  }
  if (sessionUpdate === "current_mode_update" || sessionUpdate === "config_option_update" || sessionUpdate === "available_commands_update") {
    return [event(context, sequence, "toolProgress", { update: stringify(update) })];
  }
  return [event(context, sequence, "toolProgress", { update: stringify(update) })];
}
function researchPayload(title, output) {
  const lower = title.toLowerCase();
  const action = lower.includes("websearch") || lower.includes("search") ? "search" : lower.includes("fetchurl") || lower.includes("fetch") ? "fetch" : void 0;
  if (!action) return {};
  const sources = extractSources(output);
  const fetchedContent = action === "fetch" ? extractFetchedContent(output) : void 0;
  return {
    webResearchAction: action,
    ...sources.length > 0 ? { sources: JSON.stringify(sources) } : {},
    ...fetchedContent ? { webResearchContent: fetchedContent } : {}
  };
}
function extractFetchedContent(value) {
  const records = collectRecords(value);
  for (const record of records) {
    for (const key of ["content", "markdown", "body", "text"]) {
      const candidate = record[key];
      if (typeof candidate !== "string" || !candidate.trim()) continue;
      const trimmed = candidate.trim();
      try {
        const parsed = JSON.parse(trimmed);
        if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
          const parsedRecord = parsed;
          if (typeof parsedRecord.content === "string" && parsedRecord.content.trim()) return parsedRecord.content.trim();
          if (typeof parsedRecord.text === "string" && parsedRecord.text.trim()) return parsedRecord.text.trim();
          if (typeof parsedRecord.url === "string" && Object.keys(parsedRecord).length <= 2) continue;
        }
      } catch {
      }
      if (!/^https?:\/\/[^\s]+$/.test(trimmed)) return trimmed.slice(0, 4e3);
    }
  }
  return void 0;
}
function extractSources(value) {
  const candidates = collectRecords(value);
  const unique = /* @__PURE__ */ new Map();
  for (const item of candidates) {
    const url = typeof item.url === "string" ? item.url : typeof item.link === "string" ? item.link : "";
    if (!/^https?:\/\//i.test(url)) continue;
    unique.set(url, {
      title: typeof item.title === "string" ? item.title : url,
      url,
      snippet: typeof item.snippet === "string" ? item.snippet : typeof item.description === "string" ? item.description : ""
    });
  }
  return [...unique.values()].slice(0, 10);
}
function collectRecords(value) {
  if (Array.isArray(value)) return value.flatMap(collectRecords);
  if (typeof value === "string") {
    try {
      return collectRecords(JSON.parse(value));
    } catch {
      return [];
    }
  }
  const record = asRecord(value);
  if (Object.keys(record).length === 0) return [];
  return [record, ...Object.values(record).flatMap((child) => typeof child === "object" && child !== null ? collectRecords(child) : [])];
}
function permissionDescription(toolCall, params) {
  const title = String(toolCall.title ?? toolCall.kind ?? "\u5DE5\u5177\u64CD\u4F5C");
  const options = Array.isArray(params.options) ? params.options.map((option) => String(asRecord(option).name ?? "")).filter(Boolean).join(" / ") : "";
  return options ? `${title} \u8BF7\u6C42\u6743\u9650\uFF1A${options}` : `${title} \u8BF7\u6C42\u6743\u9650\u3002`;
}
function event(context, sequence, kind, payload, requiresApproval = false) {
  return {
    id: (0, import_node_crypto.randomUUID)(),
    sessionID: context.sessionID,
    taskID: context.taskID,
    workItemID: null,
    sequence,
    timestamp: Date.now(),
    actor: "kimi-acp-host",
    kind,
    payload,
    requiresApproval
  };
}
function asRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
}
function stringify(value) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return String(value ?? "");
  }
}

// src/runtime/nativeAgentHost.ts
function mapSdkEvent(rawEvent, context) {
  const type = String(rawEvent.type ?? "Unknown");
  const payload = asRecord2(rawEvent.payload);
  const event2 = (kind, value, requiresApproval = false) => ({
    id: (0, import_node_crypto2.randomUUID)(),
    sessionID: context.sessionID,
    taskID: context.taskID,
    workItemID: null,
    sequence: context.sequence + 1,
    timestamp: Date.now(),
    actor: "kimi-agent-host",
    kind,
    payload: value,
    requiresApproval
  });
  if (type === "ContentPart") return event2("output", { text: String(payload.text ?? payload.think ?? ""), contentType: String(payload.type ?? "text") });
  if (type === "ApprovalRequest") return event2("permissionRequested", {
    id: String(payload.id ?? ""),
    action: String(payload.action ?? ""),
    description: String(payload.description ?? "")
  }, true);
  return event2("toolProgress", { type, data: stringify2(payload) });
}
var acp;
var activeStart;
var activeSequence = 0;
var input = /agent-host\.(?:cjs|mjs)$/.test(process.argv[1] ?? "") ? (0, import_node_readline.createInterface)({ input: process.stdin }) : void 0;
function send(value) {
  process.stdout.write(`${JSON.stringify(value)}
`);
}
async function start(request) {
  if (acp) {
    send({ type: "error", message: "An ACP Agent Host session is already active." });
    return;
  }
  const runtimePath = request.runtimePath ?? process.env.KIMI_RUNTIME_PATH;
  const nodePath = request.nodePath ?? process.env.KIMI_NODE_PATH ?? process.execPath;
  if (!runtimePath) {
    send({ type: "error", message: "KIMI_RUNTIME_PATH is required." });
    return;
  }
  activeStart = request;
  activeSequence = 0;
  try {
    acp = new AcpProcess(nodePath, runtimePath, request.workspacePath, handleAcpMessage);
    await acp.initialize();
    const runtimeSessionID = await acp.openSession(request.workspacePath, request.runtimeSessionID);
    if (request.modelID?.trim()) await acp.setModel(runtimeSessionID, request.modelID).catch(() => void 0);
    send({ type: "ready", sessionID: request.sessionID, runtimeSessionID });
    const result = await acp.prompt(runtimeSessionID, request.prompt);
    send({ type: "completed", result: asRecord2(result), sessionID: request.sessionID, runtimeSessionID });
  } catch (error) {
    send({ type: "error", message: error instanceof Error ? error.message : String(error) });
  } finally {
    await closeActiveSession();
    input?.close();
  }
}
function handleAcpMessage(message) {
  const request = activeStart;
  if (!request) return;
  const context = { sessionID: request.sessionID, taskID: request.taskID, sequence: activeSequence };
  const events = mapAcpMessageToDesktopEvents(message, context);
  for (const event2 of events) {
    activeSequence = event2.sequence;
    send({ type: "event", event: event2 });
  }
}
async function closeActiveSession() {
  const current = acp;
  acp = void 0;
  activeStart = void 0;
  await current?.close();
}
var AcpProcess = class {
  constructor(nodePath, runtimePath, cwd, onMessage) {
    this.onMessage = onMessage;
    this.process = (0, import_node_child_process.spawn)(nodePath, [runtimePath, "acp"], { cwd, env: process.env, stdio: "pipe" });
    (0, import_node_readline.createInterface)({ input: this.process.stdout }).on("line", (line) => this.receive(line));
    this.process.stderr.on("data", (value) => process.stderr.write(value));
    this.process.once("error", (error) => this.failAll(error));
    this.process.once("exit", (code, signal) => {
      if (!this.closed) this.failAll(new Error(`Kimi ACP exited unexpectedly (code ${String(code)}, signal ${signal ?? "none"}).`));
    });
  }
  process;
  pending = /* @__PURE__ */ new Map();
  nextRequestID = 1;
  closed = false;
  async initialize() {
    await this.request(buildAcpInitializeRequest(this.allocateID()));
  }
  async openSession(cwd, runtimeSessionID) {
    if (runtimeSessionID?.trim()) {
      try {
        await this.request(this.message("session/load", { sessionId: runtimeSessionID, cwd, mcpServers: [] }));
        this.runtimeSessionID = runtimeSessionID;
        return runtimeSessionID;
      } catch {
      }
    }
    const result = asRecord2(await this.request(this.message("session/new", { cwd, mcpServers: [] })));
    const sessionId = String(result.sessionId ?? "");
    if (!sessionId) throw new Error("Kimi ACP did not return a sessionId.");
    this.runtimeSessionID = sessionId;
    return sessionId;
  }
  async setModel(sessionId, modelId) {
    await this.request(this.message("session/set_model", { sessionId, modelId }));
  }
  async prompt(sessionId, prompt) {
    return this.request(buildAcpPromptRequest(this.allocateID(), sessionId, prompt));
  }
  cancel() {
    const request = activeStart;
    if (!request) return;
    const runtimeSessionID = this.runtimeSessionID;
    if (runtimeSessionID) this.notify("session/cancel", { sessionId: runtimeSessionID });
  }
  async approve(id, response) {
    this.write(buildAcpPermissionResponse(Number.isFinite(Number(id)) ? Number(id) : id, response));
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    this.failAll(new Error("Kimi ACP session closed."));
    this.process.kill("SIGTERM");
  }
  runtimeSessionID;
  message(method, params) {
    return { jsonrpc: "2.0", id: this.allocateID(), method, params };
  }
  allocateID() {
    return this.nextRequestID++;
  }
  request(message) {
    const id = message.id;
    if (id === void 0) throw new Error(`ACP request ${message.method ?? "unknown"} is missing an id.`);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write(message);
    });
  }
  notify(method, params) {
    this.write({ jsonrpc: "2.0", method, params });
  }
  write(message) {
    if (this.closed || !this.process.stdin.writable) throw new Error("Kimi ACP process is not writable.");
    this.process.stdin.write(`${JSON.stringify(message)}
`);
  }
  receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.id !== void 0 && ("result" in message || "error" in message)) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(`ACP ${message.error.code}: ${message.error.message}`));
      else {
        pending.resolve(message.result);
      }
      return;
    }
    this.onMessage(this.decorateToolUpdate(message));
  }
  toolNames = /* @__PURE__ */ new Map();
  decorateToolUpdate(message) {
    if (message.method !== "session/update") return message;
    const params = asRecord2(message.params);
    const update = asRecord2(params.update);
    const toolCallID = typeof update.toolCallId === "string" ? update.toolCallId : void 0;
    if (!toolCallID) return message;
    if (update.sessionUpdate === "tool_call" && typeof update.title === "string") {
      this.toolNames.set(toolCallID, update.title);
      return message;
    }
    if (update.sessionUpdate === "tool_call_update" && typeof update.title !== "string") {
      const title = this.toolNames.get(toolCallID);
      if (!title) return message;
      return { ...message, params: { ...params, update: { ...update, title } } };
    }
    return message;
  }
  failAll(error) {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
};
function asRecord2(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
}
function stringify2(value) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return String(value ?? "");
  }
}
function parseRequest(line) {
  try {
    const value = JSON.parse(line);
    if (value.type === "start" || value.type === "approve" || value.type === "interrupt" || value.type === "close") {
      return value;
    }
  } catch {
    send({ type: "error", message: "Invalid Agent Host request JSON." });
  }
  return void 0;
}
if (input) {
  input.on("line", (line) => {
    const request = parseRequest(line);
    if (!request) return;
    if (request.type === "start") void start(request);
    if (request.type === "approve") void acp?.approve(request.id, request.response).catch(() => void 0);
    if (request.type === "interrupt") acp?.cancel();
    if (request.type === "close") void closeActiveSession();
  });
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  mapSdkEvent
});
