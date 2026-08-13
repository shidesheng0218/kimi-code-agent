// src/runtime/dynamicPlanningAdapter.ts

import { prompt } from '@moonshot-ai/kimi-agent-sdk';
import { DynamicPlanSchema, planToAgentRuns, DYNAMIC_PLANNER_PROMPT, type DynamicPlan } from '../core/dynamicPlanner.js';
import type { TaskMode } from '../core/taskStateMachine.js';

export interface PlanningContext {
  userGoal: string;
  projectPath: string;
  existingContext?: string;  // 项目README、最近变更等
  constraints?: string[];
  mode: TaskMode;
}

/**
 * 使用 Kimi Agent 动态生成执行计划
 * 使用一次性 prompt() 函数，不需要启动 CLI 子进程
 */
export async function generateDynamicPlan(
  context: PlanningContext,
  apiKey: string,
  baseURL: string,
  model?: string
): Promise<DynamicPlan> {
  // Kimi SDK 通过环境变量读取 API 配置
  const originalApiKey = process.env.MOONSHOT_API_KEY;
  const originalBaseURL = process.env.MOONSHOT_BASE_URL;

  try {
    process.env.MOONSHOT_API_KEY = apiKey;
    process.env.MOONSHOT_BASE_URL = baseURL;

    // 构建完整的规划提示词
    const fullPrompt = buildPlanningPrompt(context);

    // 使用一次性 prompt() 函数，不需要 session
    const response = await prompt(fullPrompt, {
      workDir: context.projectPath,
      model: model ?? 'moonshot-v1-128k'
    });

    // 从事件流中提取文本
    let planText = '';
    for (const event of response.events) {
      if (event.type === 'ContentPart') {
        const payload = event.payload as { type: string; text?: string };
        if (payload.type === 'text' && payload.text) {
          planText += payload.text;
        }
      }
    }

    // 解析并验证计划
    return parsePlan(planText);
  } finally {
    // 恢复原始环境变量
    if (originalApiKey !== undefined) {
      process.env.MOONSHOT_API_KEY = originalApiKey;
    } else {
      delete process.env.MOONSHOT_API_KEY;
    }
    if (originalBaseURL !== undefined) {
      process.env.MOONSHOT_BASE_URL = originalBaseURL;
    } else {
      delete process.env.MOONSHOT_BASE_URL;
    }
  }
}

function buildPlanningPrompt(context: PlanningContext): string {
  const parts = [
    DYNAMIC_PLANNER_PROMPT,
    '\n## 用户目标\n',
    context.userGoal
  ];

  if (context.existingContext) {
    parts.push('\n## 项目上下文\n', context.existingContext);
  }

  if (context.constraints && context.constraints.length > 0) {
    parts.push('\n## 约束条件\n', context.constraints.map(c => `- ${c}`).join('\n'));
  }

  if (context.mode === 'plan') {
    parts.push('\n## 特殊要求\n', '这是 Plan 模式，只生成只读分析任务，不包含任何写入操作。');
  }

  return parts.join('');
}

function parsePlan(rawText: string): DynamicPlan {
  // 尝试提取 JSON 块
  const jsonMatch = rawText.match(/```(?:json)?\s*\n([\s\S]*?)\n```/);
  const jsonText = jsonMatch ? jsonMatch[1] : rawText;

  try {
    const parsed = JSON.parse(jsonText);
    return DynamicPlanSchema.parse(parsed);
  } catch (error) {
    throw new Error(`Failed to parse plan: ${error instanceof Error ? error.message : String(error)}\n\nRaw output:\n${rawText}`);
  }
}

/**
 * 将动态计划转换为可执行的 AgentOrchestrationPlan
 */
export function createOrchestrationFromDynamicPlan(
  plan: DynamicPlan,
  taskID: string,
  sessionID: string,
  model?: string
) {
  const runs = planToAgentRuns(plan, taskID, sessionID, model);

  return {
    taskID,
    sessionID,
    runs,
    metadata: {
      summary: plan.summary,
      rationale: plan.rationale,
      risks: plan.risks,
      assumptions: plan.assumptions
    }
  };
}
