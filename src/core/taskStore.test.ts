import { describe, expect, it } from 'vitest';
import { TaskStore, type StateStorage } from './taskStore';

class MemoryStorage implements StateStorage {
  private readonly values = new Map<string, unknown>();

  get<T>(key: string, fallback: T): T {
    return (this.values.get(key) as T | undefined) ?? fallback;
  }

  async update(key: string, value: unknown): Promise<void> {
    this.values.set(key, value);
  }
}

describe('TaskStore', () => {
  it('creates and persists a draft task', async () => {
    const storage = new MemoryStorage();
    const store = new TaskStore(storage, () => '2026-08-06T02:00:00.000Z', () => 'task-1');

    const created = await store.create('分析项目', 'plan');
    const reloaded = new TaskStore(storage);

    expect(created).toMatchObject({ id: 'task-1', title: '分析项目', mode: 'plan', status: 'draft' });
    expect(reloaded.list()).toEqual([created]);
  });

  it('rejects an empty task title', async () => {
    const store = new TaskStore(new MemoryStorage());

    await expect(store.create('   ', 'agent')).rejects.toThrow('Task title cannot be empty');
  });

  it('persists valid task transitions', async () => {
    const store = new TaskStore(
      new MemoryStorage(),
      () => '2026-08-06T02:00:00.000Z',
      () => 'task-1'
    );
    await store.create('修复测试', 'agent');

    const planning = await store.transition('task-1', 'planning', '2026-08-06T03:00:00.000Z');

    expect(planning.status).toBe('planning');
    expect(store.get('task-1')).toEqual(planning);
  });

  it('persists runtime session and worktree metadata', async () => {
    const store = new TaskStore(
      new MemoryStorage(),
      () => '2026-08-06T02:00:00.000Z',
      () => 'task-1'
    );
    await store.create('实现功能', 'agent');

    const updated = await store.updateRuntime('task-1', {
      sessionId: 'session-1',
      worktreePath: '/worktrees/task-1',
      branch: 'kimi/task-task-1'
    });

    expect(updated).toMatchObject({
      sessionId: 'session-1',
      worktreePath: '/worktrees/task-1',
      branch: 'kimi/task-task-1'
    });
  });
});
