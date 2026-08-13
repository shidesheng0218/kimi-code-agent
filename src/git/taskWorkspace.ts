import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import type { TaskRecord } from '../core/taskStateMachine';
import type { TaskWorktree } from './worktreeManager';

const execFileAsync = promisify(execFile);

export interface WorktreeCreator {
  createOrReuse(repositoryPath: string, taskId: string, title: string): Promise<TaskWorktree>;
}

export interface TaskWorkspace {
  path: string;
  isolated: boolean;
  branch?: string;
  reused?: boolean;
}

export type GitRepositoryProbe = (workspacePath: string) => Promise<boolean>;

export async function isGitRepository(workspacePath: string): Promise<boolean> {
  try {
    const { stdout } = await execFileAsync('git', ['rev-parse', '--is-inside-work-tree'], {
      cwd: workspacePath
    });
    return stdout.trim() === 'true';
  } catch {
    return false;
  }
}

export async function selectTaskWorkspace(
  task: TaskRecord,
  workspacePath: string,
  worktrees: WorktreeCreator,
  gitProbe: GitRepositoryProbe = isGitRepository
): Promise<TaskWorkspace> {
  if (task.mode === 'plan' || !(await gitProbe(workspacePath))) {
    return { path: workspacePath, isolated: false };
  }

  const worktree = await worktrees.createOrReuse(workspacePath, task.id, task.title);
  return {
    path: worktree.path,
    branch: worktree.branch,
    isolated: true,
    reused: worktree.reused
  };
}
