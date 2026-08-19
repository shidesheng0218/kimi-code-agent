import { randomUUID } from 'node:crypto';

type JsonRecord = Record<string, unknown>;

export interface NativeAgentEvent {
  id: string;
  sessionID: string;
  taskID: string;
  workItemID: string | null;
  sequence: number;
  timestamp: number;
  actor: string;
  kind: string;
  payload: Record<string, string>;
  requiresApproval: boolean;
}

export interface EventContext {
  sessionID: string;
  taskID: string;
  sequence: number;
}

export interface JsonRpcMessage {
  jsonrpc: '2.0';
  id?: number | string;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export function buildAcpInitializeRequest(id: number): JsonRpcMessage {
  return {
    jsonrpc: '2.0',
    id,
    method: 'initialize',
    params: {
      protocolVersion: 1,
      clientInfo: { name: 'kimi-code-agent', version: '0.3.0' },
      clientCapabilities: {
        fs: { readTextFile: false, writeTextFile: false },
        terminal: false,
        auth: { terminal: true }
      }
    }
  };
}

export function buildAcpPromptRequest(id: number, sessionId: string, prompt: string): JsonRpcMessage {
  return {
    jsonrpc: '2.0',
    id,
    method: 'session/prompt',
    params: { sessionId, prompt: [{ type: 'text', text: prompt }] }
  };
}

export function buildAcpPermissionResponse(id: number | string, response: 'approve' | 'approve_for_session' | 'reject'): JsonRpcMessage {
  const outcome = response === 'reject'
    ? { outcome: 'cancelled' }
    : { outcome: 'selected', optionId: response === 'approve_for_session' ? 'allow_always' : 'allow_once' };
  return { jsonrpc: '2.0', id, result: outcome };
}

export function mapAcpMessageToDesktopEvents(message: JsonRpcMessage, context: EventContext): NativeAgentEvent[] {
  if (message.method === 'session/request_permission') {
    const params = asRecord(message.params);
    const toolCall = asRecord(params.toolCall);
    return [event(context, context.sequence + 1, 'permissionRequested', {
      id: String(message.id ?? ''),
      action: String(toolCall.title ?? toolCall.kind ?? 'Tool'),
      description: permissionDescription(toolCall, params)
    }, true)];
  }
  if (message.method !== 'session/update') return [];
  const params = asRecord(message.params);
  const update = asRecord(params.update);
  return mapSessionUpdate(update, context);
}

function mapSessionUpdate(update: JsonRecord, context: EventContext): NativeAgentEvent[] {
  const sessionUpdate = String(update.sessionUpdate ?? '');
  const sequence = context.sequence + 1;
  if (sessionUpdate === 'agent_message_chunk' || sessionUpdate === 'assistant_message_chunk') {
    const content = asRecord(update.content);
    const text = String(content.text ?? '');
    return text ? [event(context, sequence, 'output', { text, contentType: String(content.type ?? 'text') })] : [];
  }
  if (sessionUpdate === 'agent_thought_chunk' || sessionUpdate === 'thinking_chunk') {
    const content = asRecord(update.content);
    const text = String(content.text ?? '');
    return text ? [event(context, sequence, 'output', { text, contentType: 'thinking' })] : [];
  }
  if (sessionUpdate === 'tool_call' || sessionUpdate === 'tool_call_update') {
    const toolCallId = String(update.toolCallId ?? '');
    const title = String(update.title ?? update.name ?? update.kind ?? 'Tool');
    const status = String(update.status ?? 'pending');
    const kind = status === 'completed' || status === 'failed' ? 'toolFinished' : status === 'in_progress' ? 'toolStarted' : 'toolRequested';
    const payload: Record<string, string> = {
      id: toolCallId,
      name: title,
      status,
      arguments: stringify(update.rawInput)
    };
    const output = update.rawOutput ?? update.content;
    if (output !== undefined) payload.output = stringify(output);
    const research = researchPayload(title, output);
    Object.assign(payload, research);
    return [event(context, sequence, kind, payload)];
  }
  if (sessionUpdate === 'plan') {
    return [event(context, sequence, 'taskPlanned', { plan: stringify(update) })];
  }
  if (sessionUpdate === 'current_mode_update' || sessionUpdate === 'config_option_update' || sessionUpdate === 'available_commands_update') {
    return [event(context, sequence, 'toolProgress', { update: stringify(update) })];
  }
  return [event(context, sequence, 'toolProgress', { update: stringify(update) })];
}

function researchPayload(title: string, output: unknown): Record<string, string> {
  const lower = title.toLowerCase();
  const action = lower.includes('websearch') || lower.includes('search') ? 'search' : lower.includes('fetchurl') || lower.includes('fetch') ? 'fetch' : undefined;
  if (!action) return {};
  const sources = extractSources(output);
  const fetchedContent = action === 'fetch' ? extractFetchedContent(output) : undefined;
  return {
    webResearchAction: action,
    ...(sources.length > 0 ? { sources: JSON.stringify(sources) } : {}),
    ...(fetchedContent ? { webResearchContent: fetchedContent } : {})
  };
}

function extractFetchedContent(value: unknown): string | undefined {
  const records = collectRecords(value);
  for (const record of records) {
    for (const key of ['content', 'markdown', 'body', 'text']) {
      const candidate = record[key];
      if (typeof candidate !== 'string' || !candidate.trim()) continue;
      const trimmed = candidate.trim();
      try {
        const parsed = JSON.parse(trimmed) as unknown;
        if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
          const parsedRecord = parsed as JsonRecord;
          if (typeof parsedRecord.content === 'string' && parsedRecord.content.trim()) return parsedRecord.content.trim();
          if (typeof parsedRecord.text === 'string' && parsedRecord.text.trim()) return parsedRecord.text.trim();
          if (typeof parsedRecord.url === 'string' && Object.keys(parsedRecord).length <= 2) continue;
        }
      } catch {
        // Plain text is the normal successful FetchURL result.
      }
      if (!/^https?:\/\/[^\s]+$/.test(trimmed)) return trimmed.slice(0, 4_000);
    }
  }
  return undefined;
}

function extractSources(value: unknown): Array<{ title: string; url: string; snippet: string }> {
  const candidates = collectRecords(value);
  const unique = new Map<string, { title: string; url: string; snippet: string }>();
  for (const item of candidates) {
    const url = typeof item.url === 'string' ? item.url : typeof item.link === 'string' ? item.link : '';
    if (!/^https?:\/\//i.test(url)) continue;
    unique.set(url, {
      title: typeof item.title === 'string' ? item.title : url,
      url,
      snippet: typeof item.snippet === 'string' ? item.snippet : typeof item.description === 'string' ? item.description : ''
    });
  }
  return [...unique.values()].slice(0, 10);
}

function collectRecords(value: unknown): JsonRecord[] {
  if (Array.isArray(value)) return value.flatMap(collectRecords);
  if (typeof value === 'string') {
    try { return collectRecords(JSON.parse(value) as unknown); } catch { return []; }
  }
  const record = asRecord(value);
  if (Object.keys(record).length === 0) return [];
  return [record, ...Object.values(record).flatMap(child => typeof child === 'object' && child !== null ? collectRecords(child) : [])];
}

function permissionDescription(toolCall: JsonRecord, params: JsonRecord): string {
  const title = String(toolCall.title ?? toolCall.kind ?? '工具操作');
  const options = Array.isArray(params.options) ? params.options.map(option => String(asRecord(option).name ?? '')).filter(Boolean).join(' / ') : '';
  return options ? `${title} 请求权限：${options}` : `${title} 请求权限。`;
}

function event(context: EventContext, sequence: number, kind: string, payload: Record<string, string>, requiresApproval = false): NativeAgentEvent {
  return {
    id: randomUUID(),
    sessionID: context.sessionID,
    taskID: context.taskID,
    workItemID: null,
    sequence,
    timestamp: Date.now(),
    actor: 'kimi-acp-host',
    kind,
    payload,
    requiresApproval
  };
}

function asRecord(value: unknown): JsonRecord {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonRecord : {};
}

function stringify(value: unknown): string {
  if (typeof value === 'string') return value;
  try { return JSON.stringify(value) ?? ''; } catch { return String(value ?? ''); }
}
