import { randomUUID } from 'node:crypto';
import {
  transitionTask,
  type TaskMode,
  type TaskRecord,
  type TaskStatus
} from './taskStateMachine';

export interface StateStorage {
  get<T>(key: string, fallback: T): T;
  update(key: string, value: unknown): PromiseLike<void> | void;
}

const storageKey = 'kimiDesktop.tasks.v1';

export interface TaskRuntimeMetadata {
  sessionId?: string;
  workspacePath?: string;
  worktreePath?: string;
  branch?: string;
}

export class TaskStore {
  constructor(
    private readonly storage: StateStorage,
    private readonly now: () => string = () => new Date().toISOString(),
    private readonly createId: () => string = randomUUID
  ) {}

  list(): TaskRecord[] {
    return [...this.storage.get<TaskRecord[]>(storageKey, [])];
  }

  get(taskId: string): TaskRecord | undefined {
    return this.list().find(task => task.id === taskId);
  }

  async create(title: string, mode: TaskMode): Promise<TaskRecord> {
    const normalizedTitle = title.trim();
    if (!normalizedTitle) {
      throw new Error('Task title cannot be empty');
    }

    const timestamp = this.now();
    const task: TaskRecord = {
      id: this.createId(),
      title: normalizedTitle,
      status: 'draft',
      mode,
      createdAt: timestamp,
      updatedAt: timestamp
    };

    await this.storage.update(storageKey, [task, ...this.list()]);
    return task;
  }

  async transition(taskId: string, status: TaskStatus, updatedAt = this.now()): Promise<TaskRecord> {
    const tasks = this.list();
    const index = tasks.findIndex(task => task.id === taskId);
    if (index === -1) {
      throw new Error(`Task ${taskId} does not exist`);
    }

    const updated = transitionTask(tasks[index], status, updatedAt);
    tasks[index] = updated;
    await this.storage.update(storageKey, tasks);
    return updated;
  }

  async updateRuntime(taskId: string, metadata: TaskRuntimeMetadata): Promise<TaskRecord> {
    const tasks = this.list();
    const index = tasks.findIndex(task => task.id === taskId);
    if (index === -1) {
      throw new Error(`Task ${taskId} does not exist`);
    }

    const updated: TaskRecord = {
      ...tasks[index],
      ...metadata,
      updatedAt: this.now()
    };
    tasks[index] = updated;
    await this.storage.update(storageKey, tasks);
    return updated;
  }
}
