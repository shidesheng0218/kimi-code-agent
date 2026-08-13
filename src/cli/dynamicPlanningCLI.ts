// CLI 入口：动态规划器命令行工具
// src/cli/dynamicPlanningCLI.ts

import { generateDynamicPlan } from '../runtime/dynamicPlanningAdapter.js';
import type { PlanningContext } from '../runtime/dynamicPlanningAdapter.js';
import type { TaskMode } from '../core/taskStateMachine.js';

interface CLIRequest {
  userGoal: string;
  projectPath: string;
  existingContext?: string;
  constraints?: string[];
  mode: string;
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.error('Usage: node dynamicPlanningCLI.js <json-request>');
    process.exit(1);
  }

  try {
    const request: CLIRequest = JSON.parse(args[0]);

    // 从环境变量获取 API 配置
    const apiKey = process.env.KIMI_API_KEY;
    const baseURL = process.env.KIMI_BASE_URL || 'https://api.moonshot.cn/v1';
    const model = process.env.KIMI_MODEL;

    if (!apiKey) {
      throw new Error('KIMI_API_KEY environment variable is required');
    }

    const context: PlanningContext = {
      userGoal: request.userGoal,
      projectPath: request.projectPath,
      existingContext: request.existingContext,
      constraints: request.constraints,
      mode: request.mode as TaskMode
    };

    const plan = await generateDynamicPlan(context, apiKey, baseURL, model);

    // 输出 JSON 到 stdout
    console.log(JSON.stringify(plan, null, 2));
    process.exit(0);
  } catch (error) {
    console.error('Dynamic planning failed:', error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

main();
