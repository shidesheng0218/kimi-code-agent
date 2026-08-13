import { describe, expect, it } from 'vitest';
import { mapSdkEvent } from './nativeAgentHost.js';

describe('native agent host event mapping', () => {
  it('turns streamed text into a structured desktop output event', () => {
    const event = mapSdkEvent(
      { type: 'ContentPart', payload: { type: 'text', text: '分析完成' } },
      { sessionID: '00000000-0000-0000-0000-000000000001', taskID: '00000000-0000-0000-0000-000000000002', sequence: 3 }
    );

    expect(event).toMatchObject({
      sessionID: '00000000-0000-0000-0000-000000000001',
      taskID: '00000000-0000-0000-0000-000000000002',
      sequence: 4,
      kind: 'output',
      payload: { text: '分析完成' },
      requiresApproval: false
    });
  });

  it('turns SDK approval requests into permission events', () => {
    const event = mapSdkEvent(
      { type: 'ApprovalRequest', payload: { id: 'approval-1', action: 'Bash', description: '运行测试' } },
      { sessionID: '00000000-0000-0000-0000-000000000001', taskID: '00000000-0000-0000-0000-000000000002', sequence: 0 }
    );

    expect(event).toMatchObject({
      kind: 'permissionRequested',
      requiresApproval: true,
      payload: { id: 'approval-1', action: 'Bash', description: '运行测试' }
    });
  });
});
