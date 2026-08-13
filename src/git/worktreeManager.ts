import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { access, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface TaskWorktree {
  path: string;
  branch: string;
  reused: boolean;
}

function slugify(value: string): string {
  const slug = value
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 32);
  return slug || 'task';
}

function safeTaskId(taskId: string): string {
  return taskId.toLowerCase().replace(/[^a-z0-9-]/g, '-').slice(0, 8);
}

function assertSafePathSegment(value: string): void {
  if (!value || /[^a-zA-Z0-9._-]/.test(value) || value === '.' || value === '..') {
    throw new Error(`Unsafe task id: ${JSON.stringify(value)}`);
  }
}

async function exists(candidate: string): Promise<boolean> {
  try {
    await access(candidate);
    return true;
  } catch {
    return false;
  }
}

export class WorktreeManager {
  constructor(private readonly storageRoot: string) {}

  async createOrReuse(repositoryPath: string, taskId: string, title: string): Promise<TaskWorktree> {
    const { stdout: rootOutput } = await execFileAsync('git', ['rev-parse', '--show-toplevel'], {
      cwd: repositoryPath
    });
    const repositoryRoot = rootOutput.trim();
    await execFileAsync('git', ['rev-parse', '--verify', 'HEAD'], { cwd: repositoryRoot });

    const repositoryId = createHash('sha256').update(repositoryRoot).digest('hex').slice(0, 12);
    const taskSegment = safeTaskId(taskId);
    assertSafePathSegment(taskId);
    const worktreePath = path.join(this.storageRoot, repositoryId, taskId);
    const branch = `kimi/task-${taskSegment}-${slugify(title)}`;

    if (await exists(worktreePath)) {
      const { stdout: currentBranch } = await execFileAsync('git', ['branch', '--show-current'], {
        cwd: worktreePath
      });
      return { path: worktreePath, branch: currentBranch.trim() || branch, reused: true };
    }

    await mkdir(path.dirname(worktreePath), { recursive: true });
    await execFileAsync('git', ['worktree', 'add', '-b', branch, worktreePath, 'HEAD'], {
      cwd: repositoryRoot
    });

    return { path: worktreePath, branch, reused: false };
  }
}
