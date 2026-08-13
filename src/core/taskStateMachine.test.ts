import { describe, expect, it } from 'vitest';
import { transitionTask, type TaskRecord } from './taskStateMachine';

const task = (status: TaskRecord['status']): TaskRecord => ({
  id: 'task-1',
  title: '修复登录问题',
  status,
  mode: 'plan',
  createdAt: '2026-08-06T00:00:00.000Z',
  updatedAt: '2026-08-06T00:00:00.000Z'
});

describe('transitionTask', () => {
  it('moves a draft task into planning', () => {
    const result = transitionTask(task('draft'), 'planning', '2026-08-06T01:00:00.000Z');

    expect(result.status).toBe('planning');
    expect(result.updatedAt).toBe('2026-08-06T01:00:00.000Z');
  });

  it('rejects transitions out of a completed task', () => {
    expect(() => transitionTask(task('completed'), 'running')).toThrow(
      'Cannot transition task task-1 from completed to running'
    );
  });

  it('allows a blocked task to return to planning', () => {
    expect(transitionTask(task('blocked'), 'planning').status).toBe('planning');
  });
});
