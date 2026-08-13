// tests/dynamicPlanner.test.ts

import { describe, it, expect } from 'vitest';
import { DynamicPlanSchema, planToAgentRuns } from '../src/core/dynamicPlanner.js';

describe('DynamicPlanner', () => {
  it('should validate a correct plan', () => {
    const plan = {
      summary: '实现用户认证功能',
      rationale: '分为后端 API 和前端 UI 两部分',
      subtasks: [
        {
          id: 'implement-auth-api',
          title: '实现认证 API',
          description: '创建登录和注册端点',
          agentKind: 'implement' as const,
          dependencies: [],
          estimatedComplexity: 'medium' as const,
          toolsRequired: ['read', 'write'],
          isolation: 'worktree' as const,
          acceptanceCriteria: ['API 可调用', '返回 JWT token'],
          verificationSteps: ['curl 测试']
        }
      ],
      risks: ['需要配置数据库'],
      assumptions: ['已有用户表']
    };

    const result = DynamicPlanSchema.safeParse(plan);
    expect(result.success).toBe(true);
  });

  it('should convert plan to agent runs', () => {
    const plan = {
      summary: '测试任务',
      rationale: '测试',
      subtasks: [
        {
          id: 'task-1',
          title: 'Task 1',
          description: 'Description 1',
          agentKind: 'explore' as const,
          dependencies: [],
          estimatedComplexity: 'low' as const,
          toolsRequired: ['read'],
          isolation: 'readOnlySnapshot' as const,
          acceptanceCriteria: [],
          verificationSteps: []
        },
        {
          id: 'task-2',
          title: 'Task 2',
          description: 'Description 2',
          agentKind: 'implement' as const,
          dependencies: ['task-1'],
          estimatedComplexity: 'medium' as const,
          toolsRequired: ['write'],
          isolation: 'worktree' as const,
          acceptanceCriteria: [],
          verificationSteps: []
        }
      ],
      risks: [],
      assumptions: []
    };

    const runs = planToAgentRuns(plan, 'test-task-id', 'test-session-id');

    expect(runs).toHaveLength(2);
    expect(runs[0].definition.kind).toBe('explore');
    expect(runs[1].definition.kind).toBe('implement');
    expect(runs[1].dependencies).toHaveLength(1);
  });
});
