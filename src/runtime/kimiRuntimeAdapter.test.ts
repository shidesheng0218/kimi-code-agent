import { describe, expect, it, vi } from 'vitest';
import type { ApprovalResponse, RunResult, StreamEvent } from '@moonshot-ai/kimi-agent-sdk';
import {
  KimiRuntimeSession,
  normalizeKimiEvent,
  type KimiSessionLike,
  type KimiTurnLike
} from './kimiRuntimeAdapter';

async function* events(...items: StreamEvent[]): AsyncGenerator<StreamEvent, RunResult> {
  for (const item of items) {
    yield item;
  }
  return { status: 'finished', steps: 1 };
}

describe('normalizeKimiEvent', () => {
  it('normalizes text and thinking content without exposing SDK payloads', () => {
    expect(
      normalizeKimiEvent({ type: 'ContentPart', payload: { type: 'text', text: 'hello' } })
    ).toEqual([{ type: 'text', text: 'hello' }]);
    expect(
      normalizeKimiEvent({ type: 'ContentPart', payload: { type: 'think', think: 'checking' } })
    ).toEqual([{ type: 'thinking', text: 'checking' }]);
  });

  it('normalizes approval requests', () => {
    expect(
      normalizeKimiEvent({
        type: 'ApprovalRequest',
        payload: {
          id: 'approval-1',
          tool_call_id: 'tool-1',
          sender: 'agent',
          action: 'run shell',
          description: 'Run tests',
          display: [{ type: 'shell', language: 'shell', command: 'npm test' }]
        }
      })
    ).toEqual([
      {
        type: 'approval_requested',
        requestId: 'approval-1',
        toolCallId: 'tool-1',
        sender: 'agent',
        action: 'run shell',
        description: 'Run tests',
        display: [{ type: 'shell', language: 'shell', command: 'npm test' }]
      }
    ]);
  });

  it('converts token status into a stable desktop usage event', () => {
    expect(
      normalizeKimiEvent({
        type: 'StatusUpdate',
        payload: {
          context_usage: 0.42,
          plan_mode: true,
          token_usage: {
            input_other: 100,
            input_cache_read: 50,
            input_cache_creation: 10,
            output: 25
          }
        }
      })
    ).toEqual([
      {
        type: 'usage',
        contextRatio: 0.42,
        planMode: true,
        tokens: {
          input: 160,
          output: 25,
          cacheRead: 50,
          cacheCreation: 10
        }
      }
    ]);
  });
});

describe('KimiRuntimeSession', () => {
  it('sets plan mode before streaming normalized events', async () => {
    const setPlanMode = vi.fn(async () => true);
    const approve = vi.fn(async (_requestId: string, _response: ApprovalResponse) => undefined);
    const interrupt = vi.fn(async () => undefined);
    const turn: KimiTurnLike = {
      [Symbol.asyncIterator]: () =>
        events({ type: 'ContentPart', payload: { type: 'text', text: '计划完成' } })[Symbol.asyncIterator](),
      approve,
      interrupt,
      result: Promise.resolve({ status: 'finished', steps: 1 })
    };
    const session: KimiSessionLike = {
      sessionId: 'session-1',
      workDir: '/repo',
      state: 'idle',
      planMode: false,
      setPlanMode,
      prompt: vi.fn(() => turn),
      close: vi.fn(async () => undefined)
    };
    const runtime = new KimiRuntimeSession(session);

    const received = [];
    for await (const event of runtime.run('分析项目', 'plan')) {
      received.push(event);
    }

    expect(setPlanMode).toHaveBeenCalledWith(true);
    expect(received).toEqual([{ type: 'text', text: '计划完成' }]);
  });

  it('forwards approval and cancellation to the active turn', async () => {
    const approve = vi.fn(async (_requestId: string, _response: ApprovalResponse) => undefined);
    const interrupt = vi.fn(async () => undefined);
    const turn: KimiTurnLike = {
      [Symbol.asyncIterator]: () =>
        events({
          type: 'ApprovalRequest',
          payload: {
            id: 'approval-1',
            tool_call_id: 'tool-1',
            sender: 'agent',
            action: 'run shell',
            description: 'Run tests'
          }
        })[Symbol.asyncIterator](),
      approve,
      interrupt,
      result: Promise.resolve({ status: 'finished' })
    };
    const session: KimiSessionLike = {
      sessionId: 'session-1',
      workDir: '/repo',
      state: 'idle',
      planMode: false,
      setPlanMode: vi.fn(async () => true),
      prompt: vi.fn(() => turn),
      close: vi.fn(async () => undefined)
    };
    const runtime = new KimiRuntimeSession(session);
    const iterator = runtime.run('执行任务', 'agent')[Symbol.asyncIterator]();
    await iterator.next();

    await runtime.approve('approval-1', 'approve_for_session');
    await runtime.interrupt();

    expect(approve).toHaveBeenCalledWith('approval-1', 'approve_for_session');
    expect(interrupt).toHaveBeenCalledOnce();
  });
});
