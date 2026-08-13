import { describe, expect, it, vi } from 'vitest';
import type { TaskRecord } from '../core/taskStateMachine';
import { selectTaskWorkspace, type WorktreeCreator } from './taskWorkspace';

const task = (mode: TaskRecord['mode']): TaskRecord => ({
  id: 'task-12345678',
  title: 'Fix login',
  mode,
  status: 'draft',
  createdAt: '2026-08-06T00:00:00.000Z',
  updatedAt: '2026-08-06T00:00:00.000Z'
});

describe('selectTaskWorkspace', () => {
  it('keeps plan tasks in the original read-only workspace', async () => {
    const creator: WorktreeCreator = { createOrReuse: vi.fn() };

    const result = await selectTaskWorkspace(task('plan'), '/repo', creator, async () => true);

    expect(result).toEqual({ path: '/repo', isolated: false });
    expect(creator.createOrReuse).not.toHaveBeenCalled();
  });

  it('creates a worktree for write-capable tasks in Git repositories', async () => {
    const creator: WorktreeCreator = {
      createOrReuse: vi.fn(async () => ({ path: '/worktrees/task-1', branch: 'kimi/task-1', reused: false }))
    };

    const result = await selectTaskWorkspace(task('agent'), '/repo', creator, async () => true);

    expect(result).toEqual({
      path: '/worktrees/task-1',
      branch: 'kimi/task-1',
      isolated: true,
      reused: false
    });
  });

  it('falls back to checkpoints for non-Git folders', async () => {
    const creator: WorktreeCreator = { createOrReuse: vi.fn() };

    const result = await selectTaskWorkspace(task('edit'), '/folder', creator, async () => false);

    expect(result).toEqual({ path: '/folder', isolated: false });
    expect(creator.createOrReuse).not.toHaveBeenCalled();
  });
});
