import { describe, expect, it } from 'vitest';
import { selectRunnableSubtasks, type Subtask } from './orchestrator';

const queued = (id: string, mode: Subtask['mode'], worktreeId?: string): Subtask => ({
  id,
  title: id,
  status: 'queued',
  mode,
  worktreeId
});

describe('selectRunnableSubtasks', () => {
  it('respects the concurrency limit', () => {
    const selected = selectRunnableSubtasks(
      [queued('research', 'read'), queued('frontend', 'write', 'wt-a'), queued('tests', 'read')],
      [],
      2
    );

    expect(selected.map(item => item.id)).toEqual(['research', 'frontend']);
  });

  it('allows only one writer for a worktree', () => {
    const selected = selectRunnableSubtasks(
      [queued('frontend', 'write', 'wt-a'), queued('backend', 'write', 'wt-b')],
      [{ ...queued('active-writer', 'write', 'wt-a'), status: 'running' }],
      3
    );

    expect(selected.map(item => item.id)).toEqual(['backend']);
  });

  it('allows read-only subtasks to share a repository snapshot', () => {
    const selected = selectRunnableSubtasks(
      [queued('explore-a', 'read'), queued('explore-b', 'read')],
      [{ ...queued('writer', 'write', 'wt-a'), status: 'running' }],
      3
    );

    expect(selected.map(item => item.id)).toEqual(['explore-a', 'explore-b']);
  });
});
