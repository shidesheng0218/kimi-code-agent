import path from 'node:path';
import { evaluatePermission, type PermissionEvaluation } from '../core/permissionPolicy';
import type { DesktopAgentEvent } from './kimiRuntimeAdapter';

type ApprovalEvent = Extract<DesktopAgentEvent, { type: 'approval_requested' }>;

interface DisplayBlockLike {
  type?: unknown;
  command?: unknown;
  path?: unknown;
}

export function evaluateApprovalRequest(
  event: ApprovalEvent,
  workspaceRoot: string
): PermissionEvaluation {
  const blocks = event.display.filter(
    (block): block is DisplayBlockLike => typeof block === 'object' && block !== null
  );
  const shell = blocks.find(block => block.type === 'shell' && typeof block.command === 'string');
  if (shell && typeof shell.command === 'string') {
    return evaluatePermission({
      kind: 'shell',
      workspaceRoot,
      command: shell.command
    });
  }

  const diff = blocks.find(block => block.type === 'diff' && typeof block.path === 'string');
  if (diff && typeof diff.path === 'string') {
    return evaluatePermission({
      kind: 'file-write',
      workspaceRoot,
      path: path.isAbsolute(diff.path) ? diff.path : path.join(workspaceRoot, diff.path)
    });
  }

  const description = `${event.action} ${event.description}`;
  if (/credential|token|secret|keychain|\.ssh/i.test(description)) {
    return evaluatePermission({ kind: 'credential', workspaceRoot });
  }
  if (/network|download|http|request|fetch/i.test(description)) {
    return evaluatePermission({ kind: 'network', workspaceRoot });
  }

  return evaluatePermission({ kind: 'shell', workspaceRoot, command: description });
}
