// src/core/dynamicPlanner.ts

import { z } from 'zod';

/**
 * Claude Code 风格的动态计划结构
 */
export const SubtaskSchema = z.object({
  id: z.string(),
  title: z.string().max(100),
  description: z.string(),
  agentKind: z.enum(['explore', 'implement', 'test', 'review', 'webResearch', 'browser', 'debug']),
  dependencies: z.array(z.string()).default([]),
  estimatedComplexity: z.enum(['low', 'medium', 'high']),
  toolsRequired: z.array(z.string()).default([]),
  isolation: z.enum(['readOnlySnapshot', 'sharedWorkspace', 'worktree']).default('readOnlySnapshot'),
  acceptanceCriteria: z.array(z.string()).default([]),
  verificationSteps: z.array(z.string()).default([])
});

export const DynamicPlanSchema = z.object({
  summary: z.string(),
  rationale: z.string(),
  subtasks: z.array(SubtaskSchema).min(1).max(20),
  estimatedTotalTime: z.string().optional(),
  risks: z.array(z.string()).default([]),
  assumptions: z.array(z.string()).default([])
});

export type Subtask = z.infer<typeof SubtaskSchema>;
export type DynamicPlan = z.infer<typeof DynamicPlanSchema>;

export interface AgentRun {
  id: string;
  parentSessionID: string;
  taskID: string;
  definition: AgentDefinition;
  dependencies: string[];
  state: 'queued' | 'running' | 'completed' | 'failed';
  progress: number;
  createdAt: Date;
  updatedAt: Date;
  result?: any;
  errorMessage?: string;
}

export interface AgentDefinition {
  name: string;
  description: string;
  kind: string;
  model?: string;
  allowedTools: string[];
  deniedTools: string[];
  permissionMode: 'readOnly' | 'interactive' | 'automatic';
  skills: string[];
  mcpServers: string[];
  hooks: any[];
  isolation: 'readOnlySnapshot' | 'sharedWorkspace' | 'worktree';
  maxTurns: number;
}

/**
 * 将动态计划转换为 AgentRun 列表
 */
export function planToAgentRuns(
  plan: DynamicPlan,
  taskID: string,
  sessionID: string,
  model?: string
): AgentRun[] {
  const subtaskIDToRunID = new Map<string, string>();

  return plan.subtasks.map(subtask => {
    const runID = crypto.randomUUID();
    subtaskIDToRunID.set(subtask.id, runID);

    const dependencies = subtask.dependencies
      .map(depID => subtaskIDToRunID.get(depID))
      .filter(Boolean) as string[];

    return {
      id: runID,
      parentSessionID: sessionID,
      taskID,
      definition: {
        name: subtask.id,
        description: subtask.description,
        kind: subtask.agentKind,
        model,
        allowedTools: subtask.toolsRequired,
        deniedTools: [],
        permissionMode: subtask.isolation === 'readOnlySnapshot' ? 'readOnly' : 'interactive',
        skills: [],
        mcpServers: [],
        hooks: [],
        isolation: subtask.isolation,
        maxTurns: subtask.estimatedComplexity === 'high' ? 15 : 10
      },
      dependencies,
      state: 'queued',
      progress: 0,
      createdAt: new Date(),
      updatedAt: new Date()
    };
  });
}

/**
 * Plan Agent 的系统提示词
 */
export const DYNAMIC_PLANNER_PROMPT = `
你是一个专业的任务规划 Agent。你的职责是将用户的高层次目标分解为可执行的子任务序列。

## 输出格式

你必须返回一个 JSON 对象，符合以下 schema：

{
  summary: string,           // 一句话总结整个计划
  rationale: string,         // 为什么这样规划（2-3 句话）
  subtasks: [                // 子任务列表
    {
      id: string,            // 唯一标识符（kebab-case）
      title: string,         // 简短标题
      description: string,   // 详细描述
      agentKind: "explore" | "implement" | "test" | "review" | ...,
      dependencies: string[], // 依赖的子任务 ID
      estimatedComplexity: "low" | "medium" | "high",
      toolsRequired: string[], // 需要的工具
      isolation: "readOnlySnapshot" | "sharedWorkspace" | "worktree",
      acceptanceCriteria: string[], // 验收标准
      verificationSteps: string[]   // 验证步骤
    }
  ],
  risks: string[],           // 潜在风险
  assumptions: string[]      // 假设前提
}

## 规划原则

1. **最小化子任务数量**：3-8 个为宜，避免过度分解
2. **明确依赖关系**：确保 DAG 无环
3. **合理的隔离级别**：
   - 只读操作 → readOnlySnapshot
   - 写入操作 → worktree（独立 Git 工作树）
4. **可验证性**：每个子任务都有明确的验收标准

## 常见模式

### Bug 修复
1. explore-root-cause: 定位 bug 根因
2. implement-fix: 实现修复
3. test-regression: 运行回归测试
4. review-changes: 审查变更

### 新功能开发
1. explore-context: 理解现有代码结构
2. plan-architecture: 设计架构方案
3. implement-core: 实现核心逻辑
4. implement-ui: 实现界面（如需要）
5. test-integration: 集成测试
6. review-security: 安全审查

### 重构
1. explore-scope: 确定重构范围
2. plan-strategy: 制定重构策略
3. implement-refactor: 执行重构
4. test-equivalence: 验证行为等价
5. review-quality: 代码质量审查

现在，请根据用户的请求生成执行计划。
`;
