import { describe, expect, it } from 'vitest';
import { evaluateApprovalRequest } from './approvalPolicyAdapter';

describe('evaluateApprovalRequest', () => {
  it('classifies git push as an external critical side effect', () => {
    expect(
      evaluateApprovalRequest(
        {
          type: 'approval_requested',
          requestId: 'approval-1',
          toolCallId: 'tool-1',
          sender: 'agent',
          action: 'run shell',
          description: 'Push changes',
          display: [{ type: 'shell', language: 'shell', command: 'git push origin main' }]
        },
        '/repo'
      )
    ).toMatchObject({ risk: 'critical', remember: 'never' });
  });

  it('classifies a diff inside the workspace as a task-scoped write', () => {
    expect(
      evaluateApprovalRequest(
        {
          type: 'approval_requested',
          requestId: 'approval-2',
          toolCallId: 'tool-2',
          sender: 'agent',
          action: 'edit file',
          description: 'Update app',
          display: [{ type: 'diff', path: '/repo/src/app.ts', old_text: '', new_text: 'export {}' }]
        },
        '/repo'
      )
    ).toMatchObject({ risk: 'medium', remember: 'task' });
  });
});
