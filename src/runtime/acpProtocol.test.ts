import { describe, expect, it } from 'vitest';
import {
  buildAcpInitializeRequest,
  buildAcpPromptRequest,
  mapAcpMessageToDesktopEvents
} from './acpProtocol.js';

const context = {
  sessionID: '00000000-0000-0000-0000-000000000001',
  taskID: '00000000-0000-0000-0000-000000000002',
  sequence: 4
};

describe('ACP desktop protocol adapter', () => {
  it('advertises the desktop client capabilities during initialization', () => {
    expect(buildAcpInitializeRequest(7)).toEqual({
      jsonrpc: '2.0',
      id: 7,
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
    });
  });

  it('turns an ACP assistant update into a structured output event', () => {
    const events = mapAcpMessageToDesktopEvents({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: 'acp-session',
        update: {
          sessionUpdate: 'agent_message_chunk',
          content: { type: 'text', text: '我会先检查测试。' }
        }
      }
    }, context);

    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      sequence: 5,
      kind: 'output',
      payload: { text: '我会先检查测试。', contentType: 'text' }
    });
  });

  it('turns WebSearch tool output into a source-ready tool event', () => {
    const events = mapAcpMessageToDesktopEvents({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: 'acp-session',
        update: {
          sessionUpdate: 'tool_call_update',
          toolCallId: 'tool-7',
          title: 'WebSearch',
          kind: 'search',
          status: 'completed',
          rawOutput: {
            search_results: [{ title: 'Kimi docs', url: 'https://docs.example.com/kimi', snippet: 'Kimi reference.' }]
          }
        }
      }
    }, context);

    expect(events[0]).toMatchObject({
      kind: 'toolFinished',
      payload: expect.objectContaining({
        id: 'tool-7',
        name: 'WebSearch',
        webResearchAction: 'search',
        sources: expect.stringContaining('https://docs.example.com/kimi')
      })
    });
  });

  it('keeps fetched body text separate from the raw FetchURL tool envelope', () => {
    const events = mapAcpMessageToDesktopEvents({
      jsonrpc: '2.0',
      method: 'session/update',
      params: {
        sessionId: 'acp-session',
        update: {
          sessionUpdate: 'tool_call_update',
          toolCallId: 'tool-fetch-1',
          title: 'FetchURL',
          status: 'completed',
          rawInput: { url: 'https://docs.example.com/kimi' },
          rawOutput: {
            source: { url: 'https://docs.example.com/kimi', title: 'Kimi docs' },
            content: 'Kimi fetched reference body.'
          }
        }
      }
    }, context);

    expect(events[0]?.payload).toMatchObject({
      webResearchAction: 'fetch',
      webResearchContent: 'Kimi fetched reference body.'
    });
  });

  it('converts ACP permission requests into a desktop approval event and response method', () => {
    const events = mapAcpMessageToDesktopEvents({
      jsonrpc: '2.0',
      id: 33,
      method: 'session/request_permission',
      params: {
        sessionId: 'acp-session',
        toolCall: { toolCallId: 'tool-8', title: 'FetchURL', kind: 'fetch' },
        options: [{ optionId: 'allow_once', name: 'Allow once' }]
      }
    }, context);

    expect(events[0]).toMatchObject({
      kind: 'permissionRequested',
      requiresApproval: true,
      payload: expect.objectContaining({ id: '33', action: 'FetchURL' })
    });
  });

  it('builds ACP prompt requests with native content blocks', () => {
    expect(buildAcpPromptRequest(9, 'acp-session', '修复测试')).toMatchObject({
      id: 9,
      method: 'session/prompt',
      params: { sessionId: 'acp-session', prompt: [{ type: 'text', text: '修复测试' }] }
    });
  });
});
