import { randomUUID } from 'node:crypto';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import {
  buildAcpInitializeRequest,
  buildAcpPermissionResponse,
  buildAcpPromptRequest,
  mapAcpMessageToDesktopEvents,
  type EventContext,
  type JsonRpcMessage,
  type NativeAgentEvent
} from './acpProtocol.js';

type JsonRecord = Record<string, unknown>;

export type { EventContext, NativeAgentEvent } from './acpProtocol.js';

/**
 * Kept as a pure compatibility mapper for persisted/in-flight legacy host
 * tests. New runtime traffic is mapped by mapAcpMessageToDesktopEvents.
 */
export function mapSdkEvent(rawEvent: JsonRecord, context: EventContext): NativeAgentEvent {
  const type = String(rawEvent.type ?? 'Unknown');
  const payload = asRecord(rawEvent.payload);
  const event = (kind: string, value: Record<string, string>, requiresApproval = false): NativeAgentEvent => ({
    id: randomUUID(), sessionID: context.sessionID, taskID: context.taskID, workItemID: null,
    sequence: context.sequence + 1, timestamp: Date.now(), actor: 'kimi-agent-host', kind, payload: value, requiresApproval
  });
  if (type === 'ContentPart') return event('output', { text: String(payload.text ?? payload.think ?? ''), contentType: String(payload.type ?? 'text') });
  if (type === 'ApprovalRequest') return event('permissionRequested', {
    id: String(payload.id ?? ''), action: String(payload.action ?? ''), description: String(payload.description ?? '')
  }, true);
  return event('toolProgress', { type, data: stringify(payload) });
}

interface StartRequest {
  type: 'start';
  sessionID: string;
  runtimeSessionID?: string;
  taskID: string;
  workspacePath: string;
  prompt: string;
  modelID?: string;
  runtimePath?: string;
  nodePath?: string;
  skillsDirectories?: string[];
}

interface ApprovalRequest { type: 'approve'; id: string; response: 'approve' | 'approve_for_session' | 'reject' }
interface InterruptRequest { type: 'interrupt' }
interface CloseRequest { type: 'close' }

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
}

let acp: AcpProcess | undefined;
let activeStart: StartRequest | undefined;
let activeSequence = 0;
const input = /agent-host\.(?:cjs|mjs)$/.test(process.argv[1] ?? '') ? createInterface({ input: process.stdin }) : undefined;

function send(value: JsonRecord): void {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

async function start(request: StartRequest): Promise<void> {
  if (acp) {
    send({ type: 'error', message: 'An ACP Agent Host session is already active.' });
    return;
  }
  const runtimePath = request.runtimePath ?? process.env.KIMI_RUNTIME_PATH;
  const nodePath = request.nodePath ?? process.env.KIMI_NODE_PATH ?? process.execPath;
  if (!runtimePath) {
    send({ type: 'error', message: 'KIMI_RUNTIME_PATH is required.' });
    return;
  }

  activeStart = request;
  activeSequence = 0;
  try {
    acp = new AcpProcess(nodePath, runtimePath, request.workspacePath, handleAcpMessage);
    await acp.initialize();
    const runtimeSessionID = await acp.openSession(request.workspacePath, request.runtimeSessionID);
    if (request.modelID?.trim()) await acp.setModel(runtimeSessionID, request.modelID).catch(() => undefined);
    send({ type: 'ready', sessionID: request.sessionID, runtimeSessionID });
    const result = await acp.prompt(runtimeSessionID, request.prompt);
    send({ type: 'completed', result: asRecord(result), sessionID: request.sessionID, runtimeSessionID });
  } catch (error) {
    send({ type: 'error', message: error instanceof Error ? error.message : String(error) });
  } finally {
    await closeActiveSession();
    input?.close();
  }
}

function handleAcpMessage(message: JsonRpcMessage): void {
  const request = activeStart;
  if (!request) return;
  const context: EventContext = { sessionID: request.sessionID, taskID: request.taskID, sequence: activeSequence };
  const events = mapAcpMessageToDesktopEvents(message, context);
  for (const event of events) {
    activeSequence = event.sequence;
    send({ type: 'event', event });
  }
}

async function closeActiveSession(): Promise<void> {
  const current = acp;
  acp = undefined;
  activeStart = undefined;
  await current?.close();
}

class AcpProcess {
  private readonly process: ChildProcessWithoutNullStreams;
  private readonly pending = new Map<number | string, PendingRequest>();
  private nextRequestID = 1;
  private closed = false;

  constructor(nodePath: string, runtimePath: string, cwd: string, private readonly onMessage: (message: JsonRpcMessage) => void) {
    this.process = spawn(nodePath, [runtimePath, 'acp'], { cwd, env: process.env, stdio: 'pipe' });
    createInterface({ input: this.process.stdout }).on('line', line => this.receive(line));
    this.process.stderr.on('data', value => process.stderr.write(value));
    this.process.once('error', error => this.failAll(error));
    this.process.once('exit', (code, signal) => {
      if (!this.closed) this.failAll(new Error(`Kimi ACP exited unexpectedly (code ${String(code)}, signal ${signal ?? 'none'}).`));
    });
  }

  async initialize(): Promise<void> {
    await this.request(buildAcpInitializeRequest(this.allocateID()));
  }

  async openSession(cwd: string, runtimeSessionID?: string): Promise<string> {
    if (runtimeSessionID?.trim()) {
      try {
        await this.request(this.message('session/load', { sessionId: runtimeSessionID, cwd, mcpServers: [] }));
        this.runtimeSessionID = runtimeSessionID;
        return runtimeSessionID;
      } catch {
        // A removed/corrupt persisted session must not prevent a fresh task.
      }
    }
    const result = asRecord(await this.request(this.message('session/new', { cwd, mcpServers: [] })));
    const sessionId = String(result.sessionId ?? '');
    if (!sessionId) throw new Error('Kimi ACP did not return a sessionId.');
    this.runtimeSessionID = sessionId;
    return sessionId;
  }

  async setModel(sessionId: string, modelId: string): Promise<void> {
    await this.request(this.message('session/set_model', { sessionId, modelId }));
  }

  async prompt(sessionId: string, prompt: string): Promise<unknown> {
    return this.request(buildAcpPromptRequest(this.allocateID(), sessionId, prompt));
  }

  cancel(): void {
    const request = activeStart;
    if (!request) return;
    // runtime session id is assigned after `ready`; ACP still safely ignores an empty cancel.
    const runtimeSessionID = this.runtimeSessionID;
    if (runtimeSessionID) this.notify('session/cancel', { sessionId: runtimeSessionID });
  }

  async approve(id: string, response: ApprovalRequest['response']): Promise<void> {
    this.write(buildAcpPermissionResponse(Number.isFinite(Number(id)) ? Number(id) : id, response));
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.failAll(new Error('Kimi ACP session closed.'));
    this.process.kill('SIGTERM');
  }

  private runtimeSessionID: string | undefined;

  private message(method: string, params: JsonRecord): JsonRpcMessage {
    return { jsonrpc: '2.0', id: this.allocateID(), method, params };
  }

  private allocateID(): number { return this.nextRequestID++; }

  private request(message: JsonRpcMessage): Promise<unknown> {
    const id = message.id;
    if (id === undefined) throw new Error(`ACP request ${message.method ?? 'unknown'} is missing an id.`);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write(message);
    });
  }

  private notify(method: string, params: JsonRecord): void {
    this.write({ jsonrpc: '2.0', method, params });
  }

  private write(message: JsonRpcMessage): void {
    if (this.closed || !this.process.stdin.writable) throw new Error('Kimi ACP process is not writable.');
    this.process.stdin.write(`${JSON.stringify(message)}\n`);
  }

  private receive(line: string): void {
    let message: JsonRpcMessage;
    try { message = JSON.parse(line) as JsonRpcMessage; } catch { return; }
    if (message.id !== undefined && ('result' in message || 'error' in message)) {
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

  private readonly toolNames = new Map<string, string>();

  private decorateToolUpdate(message: JsonRpcMessage): JsonRpcMessage {
    if (message.method !== 'session/update') return message;
    const params = asRecord(message.params);
    const update = asRecord(params.update);
    const toolCallID = typeof update.toolCallId === 'string' ? update.toolCallId : undefined;
    if (!toolCallID) return message;
    if (update.sessionUpdate === 'tool_call' && typeof update.title === 'string') {
      this.toolNames.set(toolCallID, update.title);
      return message;
    }
    if (update.sessionUpdate === 'tool_call_update' && typeof update.title !== 'string') {
      const title = this.toolNames.get(toolCallID);
      if (!title) return message;
      return { ...message, params: { ...params, update: { ...update, title } } };
    }
    return message;
  }

  private failAll(error: Error): void {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

function asRecord(value: unknown): JsonRecord {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonRecord : {};
}

function stringify(value: unknown): string {
  if (typeof value === 'string') return value;
  try { return JSON.stringify(value) ?? ''; } catch { return String(value ?? ''); }
}

function parseRequest(line: string): StartRequest | ApprovalRequest | InterruptRequest | CloseRequest | undefined {
  try {
    const value = JSON.parse(line) as { type?: string };
    if (value.type === 'start' || value.type === 'approve' || value.type === 'interrupt' || value.type === 'close') {
      return value as StartRequest | ApprovalRequest | InterruptRequest | CloseRequest;
    }
  } catch {
    send({ type: 'error', message: 'Invalid Agent Host request JSON.' });
  }
  return undefined;
}

if (input) {
  input.on('line', line => {
    const request = parseRequest(line);
    if (!request) return;
    if (request.type === 'start') void start(request);
    if (request.type === 'approve') void acp?.approve(request.id, request.response).catch(() => undefined);
    if (request.type === 'interrupt') acp?.cancel();
    if (request.type === 'close') void closeActiveSession();
  });
}
