import { execFile } from 'node:child_process';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { afterEach, describe, expect, it } from 'vitest';
import { WorktreeManager } from './worktreeManager';

const execFileAsync = promisify(execFile);
const temporaryRoots: string[] = [];

async function createRepository(): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), 'kimi-worktree-test-'));
  temporaryRoots.push(root);
  await execFileAsync('git', ['init', '-b', 'main'], { cwd: root });
  await execFileAsync('git', ['config', 'user.email', 'test@example.com'], { cwd: root });
  await execFileAsync('git', ['config', 'user.name', 'Test User'], { cwd: root });
  await writeFile(path.join(root, 'README.md'), '# Demo\n');
  await execFileAsync('git', ['add', 'README.md'], { cwd: root });
  await execFileAsync('git', ['commit', '-m', 'initial'], { cwd: root });
  return root;
}

afterEach(async () => {
  const { rm } = await import('node:fs/promises');
  await Promise.all(temporaryRoots.splice(0).map(root => rm(root, { recursive: true, force: true })));
});

describe('WorktreeManager', () => {
  it('creates an isolated task worktree and branch', async () => {
    const repository = await createRepository();
    const storage = await mkdtemp(path.join(os.tmpdir(), 'kimi-worktree-storage-'));
    temporaryRoots.push(storage);
    const manager = new WorktreeManager(storage);

    const worktree = await manager.createOrReuse(repository, 'task-12345678', 'Fix login flow');
    const { stdout: branch } = await execFileAsync('git', ['branch', '--show-current'], { cwd: worktree.path });

    expect(worktree.reused).toBe(false);
    expect(worktree.branch).toBe('kimi/task-task-123-fix-login-flow');
    expect(branch.trim()).toBe(worktree.branch);
    expect(await readFile(path.join(worktree.path, 'README.md'), 'utf8')).toBe('# Demo\n');
  });

  it('reuses the deterministic worktree for the same task', async () => {
    const repository = await createRepository();
    const storage = await mkdtemp(path.join(os.tmpdir(), 'kimi-worktree-storage-'));
    temporaryRoots.push(storage);
    const manager = new WorktreeManager(storage);

    const first = await manager.createOrReuse(repository, 'task-12345678', 'Fix login flow');
    const second = await manager.createOrReuse(repository, 'task-12345678', 'Fix login flow');

    expect(second).toEqual({ ...first, reused: true });
  });
});
