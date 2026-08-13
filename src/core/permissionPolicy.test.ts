import { describe, expect, it } from 'vitest';
import { evaluatePermission, isPathInsideWorkspace } from './permissionPolicy';

const workspaceRoot = '/Users/test/project';

describe('isPathInsideWorkspace', () => {
  it('accepts a file inside the workspace', () => {
    expect(isPathInsideWorkspace(workspaceRoot, '/Users/test/project/src/app.ts')).toBe(true);
  });

  it('rejects a sibling path that only shares the workspace prefix', () => {
    expect(isPathInsideWorkspace(workspaceRoot, '/Users/test/project-secret/token')).toBe(false);
  });
});

describe('evaluatePermission', () => {
  it('allows reads inside a trusted workspace', () => {
    expect(
      evaluatePermission({
        kind: 'file-read',
        workspaceRoot,
        path: '/Users/test/project/README.md'
      })
    ).toMatchObject({ decision: 'allow', risk: 'low' });
  });

  it('requires task approval for writes inside a workspace', () => {
    expect(
      evaluatePermission({
        kind: 'file-write',
        workspaceRoot,
        path: '/Users/test/project/src/app.ts'
      })
    ).toMatchObject({ decision: 'prompt', risk: 'medium', remember: 'task' });
  });

  it('never offers remembered approval for git push', () => {
    expect(
      evaluatePermission({
        kind: 'shell',
        workspaceRoot,
        command: 'git push origin main'
      })
    ).toMatchObject({ decision: 'prompt', risk: 'critical', remember: 'never' });
  });

  it('denies commands that recursively delete the filesystem root', () => {
    expect(
      evaluatePermission({
        kind: 'shell',
        workspaceRoot,
        command: 'sudo rm -rf /'
      })
    ).toMatchObject({ decision: 'deny', risk: 'critical', remember: 'never' });
  });

  it('requires one-time approval for reads outside the workspace', () => {
    expect(
      evaluatePermission({
        kind: 'file-read',
        workspaceRoot,
        path: '/Users/test/.ssh/id_ed25519'
      })
    ).toMatchObject({ decision: 'prompt', risk: 'critical', remember: 'never' });
  });
});
