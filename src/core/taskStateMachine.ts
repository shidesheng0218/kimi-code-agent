export type TaskStatus =
  | 'draft'
  | 'planning'
  | 'waiting_for_approval'
  | 'running'
  | 'waiting_for_user'
  | 'review_ready'
  | 'testing'
  | 'completed'
  | 'failed'
  | 'cancelled'
  | 'blocked'
  | 'recovering';

export type TaskMode = 'plan' | 'edit' | 'agent';

export interface TaskRecord {
  id: string;
  title: string;
  status: TaskStatus;
  mode: TaskMode;
  createdAt: string;
  updatedAt: string;
  sessionId?: string;
  workspacePath?: string;
  worktreePath?: string;
  branch?: string;
}

const transitions: Readonly<Record<TaskStatus, readonly TaskStatus[]>> = {
  draft: ['planning', 'cancelled'],
  planning: ['waiting_for_approval', 'running', 'failed', 'cancelled'],
  waiting_for_approval: ['running', 'failed', 'cancelled'],
  running: [
    'waiting_for_user',
    'review_ready',
    'testing',
    'completed',
    'failed',
    'cancelled',
    'blocked',
    'recovering'
  ],
  waiting_for_user: ['running', 'failed', 'cancelled', 'blocked'],
  review_ready: ['running', 'testing', 'completed', 'cancelled'],
  testing: ['running', 'review_ready', 'completed', 'failed', 'cancelled'],
  completed: [],
  failed: ['recovering'],
  cancelled: [],
  blocked: ['planning', 'running', 'cancelled'],
  recovering: ['running', 'failed', 'blocked', 'cancelled']
};

export function transitionTask(
  task: TaskRecord,
  nextStatus: TaskStatus,
  updatedAt = new Date().toISOString()
): TaskRecord {
  if (!transitions[task.status].includes(nextStatus)) {
    throw new Error(`Cannot transition task ${task.id} from ${task.status} to ${nextStatus}`);
  }

  return {
    ...task,
    status: nextStatus,
    updatedAt
  };
}
