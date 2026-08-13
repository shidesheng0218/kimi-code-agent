export interface Subtask {
  id: string;
  title: string;
  status: 'queued' | 'running' | 'completed' | 'failed' | 'cancelled';
  mode: 'read' | 'write';
  worktreeId?: string;
}

export function selectRunnableSubtasks(
  queued: readonly Subtask[],
  active: readonly Subtask[],
  maxConcurrentAgents: number
): Subtask[] {
  const availableSlots = Math.max(0, maxConcurrentAgents - active.length);
  if (availableSlots === 0) {
    return [];
  }

  const occupiedWriteWorktrees = new Set(
    active
      .filter(item => item.status === 'running' && item.mode === 'write' && item.worktreeId)
      .map(item => item.worktreeId as string)
  );
  const selected: Subtask[] = [];

  for (const subtask of queued) {
    if (selected.length >= availableSlots || subtask.status !== 'queued') {
      continue;
    }

    if (subtask.mode === 'write') {
      if (!subtask.worktreeId || occupiedWriteWorktrees.has(subtask.worktreeId)) {
        continue;
      }
      occupiedWriteWorktrees.add(subtask.worktreeId);
    }

    selected.push(subtask);
  }

  return selected;
}
