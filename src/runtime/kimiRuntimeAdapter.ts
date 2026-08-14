import {
  createSession,
  type ApprovalResponse,
  type RunResult,
  type SessionOptions,
  type StreamEvent
} from '@moonshot-ai/kimi-agent-sdk';
import { buildMacComputerUseTools } from './computerUseTools.js';
import { buildNetworkTools } from './networkGateway.js';
import type { TaskMode } from '../core/taskStateMachine';

export type DesktopAgentEvent =
  | { type: 'text'; text: string }
  | { type: 'thinking'; text: string }
  | { type: 'step'; step: number }
  | { type: 'tool_started'; toolCallId: string; name: string; arguments?: string | null }
  | { type: 'tool_finished'; toolCallId: string; isError: boolean; message: string; display: readonly unknown[] }
  | {
      type: 'approval_requested';
      requestId: string;
      toolCallId: string;
      sender: string;
      action: string;
      description: string;
      display: readonly unknown[];
    }
  | {
      type: 'usage';
      contextRatio?: number;
      planMode?: boolean;
      tokens?: {
        input: number;
        output: number;
        cacheRead: number;
        cacheCreation: number;
      };
    }
  | { type: 'subagent_event'; parentToolCallId: string; event: DesktopAgentEvent }
  | { type: 'compaction'; phase: 'begin' | 'end' }
  | { type: 'error'; code: string; message: string }
  | { type: 'lifecycle'; name: string };

export interface KimiTurnLike {
  [Symbol.asyncIterator](): AsyncIterator<StreamEvent, RunResult, undefined>;
  interrupt(): Promise<void>;
  approve(requestId: string, response: ApprovalResponse): Promise<void>;
  readonly result: Promise<RunResult>;
}

export interface KimiSessionLike {
  readonly sessionId: string;
  readonly workDir: string;
  readonly state: 'idle' | 'active' | 'closed';
  readonly planMode: boolean;
  setPlanMode(enabled: boolean): Promise<boolean>;
  prompt(content: string): KimiTurnLike;
  close(): Promise<void>;
}

export function normalizeKimiEvent(event: StreamEvent): DesktopAgentEvent[] {
  if (event.type === 'error') {
    return [{ type: 'error', code: event.code, message: event.message }];
  }

  switch (event.type) {
    case 'ContentPart': {
      const payload = event.payload as { type: string; text?: string; think?: string };
      if (payload.type === 'text') {
        return [{ type: 'text', text: payload.text ?? '' }];
      }
      if (payload.type === 'think') {
        return [{ type: 'thinking', text: payload.think ?? '' }];
      }
      return [];
    }
    case 'StepBegin':
      return [{ type: 'step', step: event.payload.n }];
    case 'ToolCall':
      return [
        {
          type: 'tool_started',
          toolCallId: event.payload.id,
          name: event.payload.function.name,
          arguments: event.payload.function.arguments
        }
      ];
    case 'ToolResult':
      return [
        {
          type: 'tool_finished',
          toolCallId: event.payload.tool_call_id,
          isError: event.payload.return_value.is_error,
          message: event.payload.return_value.message,
          display: event.payload.return_value.display
        }
      ];
    case 'ApprovalRequest':
      return [
        {
          type: 'approval_requested',
          requestId: event.payload.id,
          toolCallId: event.payload.tool_call_id,
          sender: event.payload.sender,
          action: event.payload.action,
          description: event.payload.description,
          display: event.payload.display ?? []
        }
      ];
    case 'StatusUpdate': {
      const tokenUsage = event.payload.token_usage;
      return [
        {
          type: 'usage',
          contextRatio: event.payload.context_usage ?? undefined,
          planMode: event.payload.plan_mode ?? undefined,
          tokens: tokenUsage
            ? {
                input: tokenUsage.input_other + tokenUsage.input_cache_read + tokenUsage.input_cache_creation,
                output: tokenUsage.output,
                cacheRead: tokenUsage.input_cache_read,
                cacheCreation: tokenUsage.input_cache_creation
              }
            : undefined
        }
      ];
    }
    case 'SubagentEvent':
      return normalizeKimiEvent(event.payload.event).map(nested => ({
        type: 'subagent_event',
        parentToolCallId: event.payload.parent_tool_call_id,
        event: nested
      }));
    case 'CompactionBegin':
      return [{ type: 'compaction', phase: 'begin' }];
    case 'CompactionEnd':
      return [{ type: 'compaction', phase: 'end' }];
    case 'ParseError':
      return [{ type: 'error', code: event.payload.code, message: event.payload.message }];
    case 'TurnBegin':
    case 'TurnEnd':
    case 'StepInterrupted':
    case 'HookTriggered':
    case 'HookResolved':
    case 'ApprovalResponse':
    case 'SteerInput':
      return [{ type: 'lifecycle', name: event.type }];
    case 'ToolCallPart':
    case 'ToolCallRequest':
    case 'QuestionRequest':
    case 'HookRequest':
      return [];
  }
}

export class KimiRuntimeSession {
  private activeTurn: KimiTurnLike | undefined;

  constructor(private readonly session: KimiSessionLike) {}

  get sessionId(): string {
    return this.session.sessionId;
  }

  get workDir(): string {
    return this.session.workDir;
  }

  async *run(prompt: string, mode: TaskMode): AsyncGenerator<DesktopAgentEvent, RunResult> {
    if (this.activeTurn) {
      throw new Error(`Kimi session ${this.session.sessionId} already has an active turn`);
    }

    // Prefer setting Plan mode before the first prompt. Some older SDK sessions
    // reject this call until the client handshake is complete, so keep the
    // runtime compatible by treating that failure as a best-effort hint.
    if (mode === 'plan' && !this.session.planMode) {
      try {
        await this.session.setPlanMode(true);
      } catch {
        // The prompt can still proceed in the provider's default mode.
      }
    }
    const turn = this.session.prompt(prompt);
    this.activeTurn = turn;

    try {
      const iterator = turn[Symbol.asyncIterator]();
      while (true) {
        const next = await iterator.next();
        if (next.done) {
          return next.value;
        }
        for (const normalized of normalizeKimiEvent(next.value)) {
          yield normalized;
        }
      }
    } finally {
      this.activeTurn = undefined;
    }
  }

  async approve(requestId: string, response: ApprovalResponse): Promise<void> {
    if (!this.activeTurn) {
      throw new Error('No active Kimi turn is waiting for approval');
    }
    await this.activeTurn.approve(requestId, response);
  }

  async interrupt(): Promise<void> {
    await this.activeTurn?.interrupt();
  }

  async close(): Promise<void> {
    await this.interrupt();
    await this.session.close();
  }
}

export function createKimiRuntimeSession(options: SessionOptions): KimiRuntimeSession {
  const externalTools = options.externalTools ?? [
    ...(process.platform === 'darwin' ? buildMacComputerUseTools() : []),
    ...buildNetworkTools()
  ];

  return new KimiRuntimeSession(createSession({ ...options, externalTools }));
}
