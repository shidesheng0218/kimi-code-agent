# Phase 3: 智能错误恢复机制

## Claude Code 的错误恢复特点

1. **自动重试**：编译错误、测试失败自动重试
2. **策略调整**：失败后调整方法（如简化实现、分步执行）
3. **上下文增强**：收集错误日志、堆栈跟踪，提供给下一次尝试
4. **降级处理**：复杂任务失败后，尝试部分完成

## 实现方案

### 3.1 错误分类和恢复策略

```typescript
// src/core/errorRecovery.ts

export enum ErrorCategory {
  COMPILATION_ERROR = 'compilation_error',
  TEST_FAILURE = 'test_failure',
  RUNTIME_ERROR = 'runtime_error',
  PERMISSION_DENIED = 'permission_denied',
  TOOL_EXECUTION_ERROR = 'tool_execution_error',
  TIMEOUT = 'timeout',
  UNKNOWN = 'unknown'
}

export interface ErrorContext {
  category: ErrorCategory;
  message: string;
  stackTrace?: string;
  affectedFiles?: string[];
  failedCommand?: string;
  attemptNumber: number;
  previousAttempts?: ErrorContext[];
}

export interface RecoveryStrategy {
  name: string;
  description: string;
  maxAttempts: number;
  shouldRetry: (error: ErrorContext) => boolean;
  adjustPrompt: (originalPrompt: string, error: ErrorContext) => string;
}

/**
 * 错误分类器
 */
export function categorizeError(
  errorMessage: string,
  context?: { command?: string; exitCode?: number }
): ErrorCategory {
  const lower = errorMessage.toLowerCase();
  
  if (context?.command?.includes('tsc') || lower.includes('typescript error')) {
    return ErrorCategory.COMPILATION_ERROR;
  }
  
  if (context?.command?.includes('test') || lower.includes('test failed')) {
    return ErrorCategory.TEST_FAILURE;
  }
  
  if (lower.includes('permission denied') || context?.exitCode === 126) {
    return ErrorCategory.PERMISSION_DENIED;
  }
  
  if (lower.includes('timeout') || lower.includes('timed out')) {
    return ErrorCategory.TIMEOUT;
  }
  
  if (lower.includes('enoent') || lower.includes('cannot find module')) {
    return ErrorCategory.TOOL_EXECUTION_ERROR;
  }
  
  if (lower.includes('error:') || lower.includes('exception')) {
    return ErrorCategory.RUNTIME_ERROR;
  }
  
  return ErrorCategory.UNKNOWN;
}

/**
 * 内置恢复策略
 */
export const RECOVERY_STRATEGIES: Record<ErrorCategory, RecoveryStrategy> = {
  [ErrorCategory.COMPILATION_ERROR]: {
    name: 'compilation-fix',
    description: '修复编译错误',
    maxAttempts: 3,
    shouldRetry: (error) => error.attemptNumber < 3,
    adjustPrompt: (original, error) => `
${original}

## 上次尝试失败

**编译错误**：
\`\`\`
${error.message}
\`\`\`

${error.stackTrace ? `**详细信息**：\n\`\`\`\n${error.stackTrace}\n\`\`\`\n` : ''}

## 恢复指引

1. 仔细阅读错误信息，定位具体的类型错误或语法错误
2. 使用 Read 工具查看报错文件的当前内容
3. 修复错误，确保类型正确、导入完整
4. 如果是复杂的类型问题，考虑使用 \`any\` 或 \`unknown\` 临时绕过
5. 修复后使用 Bash 工具运行 \`npm run check\` 验证

**尝试次数**：${error.attemptNumber + 1}/3
`
  },

  [ErrorCategory.TEST_FAILURE]: {
    name: 'test-fix',
    description: '修复测试失败',
    maxAttempts: 3,
    shouldRetry: (error) => error.attemptNumber < 3,
    adjustPrompt: (original, error) => `
${original}

## 上次尝试失败

**测试失败**：
\`\`\`
${error.message}
\`\`\`

${error.stackTrace ? `**堆栈跟踪**：\n\`\`\`\n${error.stackTrace}\n\`\`\`\n` : ''}

## 恢复指引

1. 分析测试失败原因：断言不匹配？运行时错误？
2. 检查实现代码是否有逻辑错误
3. 检查测试用例的期望是否合理
4. 添加日志或调试信息帮助定位
5. 如果是边界情况，考虑修改实现或调整测试

**尝试次数**：${error.attemptNumber + 1}/3

${error.attemptNumber >= 2 ? '**注意**：这是最后一次尝试，请仔细检查所有可能的原因。' : ''}
`
  },

  [ErrorCategory.RUNTIME_ERROR]: {
    name: 'runtime-fix',
    description: '修复运行时错误',
    maxAttempts: 2,
    shouldRetry: (error) => error.attemptNumber < 2,
    adjustPrompt: (original, error) => `
${original}

## 上次尝试失败

**运行时错误**：
\`\`\`
${error.message}
\`\`\`

${error.stackTrace ? `**堆栈跟踪**：\n\`\`\`\n${error.stackTrace}\n\`\`\`\n` : ''}

## 恢复指引

1. 检查是否有 null/undefined 引用
2. 检查异步操作是否正确处理
3. 添加错误处理（try-catch）
4. 验证输入数据的有效性

**尝试次数**：${error.attemptNumber + 1}/2
`
  },

  [ErrorCategory.PERMISSION_DENIED]: {
    name: 'permission-fix',
    description: '修复权限问题',
    maxAttempts: 1,
    shouldRetry: () => false, // 权限问题通常需要人工介入
    adjustPrompt: (original, error) => `
${original}

## 权限错误

\`\`\`
${error.message}
\`\`\`

权限错误通常需要用户手动处理。请：
1. 检查文件/目录权限
2. 确认是否需要 sudo
3. 检查是否有进程占用文件

请人工解决权限问题后重新运行任务。
`
  },

  [ErrorCategory.TOOL_EXECUTION_ERROR]: {
    name: 'tool-fix',
    description: '修复工具执行错误',
    maxAttempts: 2,
    shouldRetry: (error) => error.attemptNumber < 2,
    adjustPrompt: (original, error) => `
${original}

## 工具执行失败

\`\`\`
${error.message}
\`\`\`

${error.failedCommand ? `**失败的命令**：\`${error.failedCommand}\`\n` : ''}

## 恢复指引

1. 检查依赖是否已安装（运行 \`npm install\`）
2. 检查命令路径是否正确
3. 检查 package.json 中的 scripts 配置
4. 尝试使用绝对路径或 npx

**尝试次数**：${error.attemptNumber + 1}/2
`
  },

  [ErrorCategory.TIMEOUT]: {
    name: 'timeout-recovery',
    description: '超时恢复',
    maxAttempts: 2,
    shouldRetry: (error) => error.attemptNumber < 2,
    adjustPrompt: (original, error) => `
${original}

## 执行超时

${error.failedCommand ? `命令 \`${error.failedCommand}\` 执行超时。\n` : ''}

## 恢复指引

1. 简化任务范围，分步执行
2. 检查是否有死循环或阻塞操作
3. 优化性能密集型操作
4. 考虑使用缓存或预处理

**尝试次数**：${error.attemptNumber + 1}/2
`
  },

  [ErrorCategory.UNKNOWN]: {
    name: 'generic-retry',
    description: '通用重试',
    maxAttempts: 1,
    shouldRetry: (error) => error.attemptNumber === 0,
    adjustPrompt: (original, error) => `
${original}

## 上次尝试遇到错误

\`\`\`
${error.message}
\`\`\`

请重新分析问题，调整实现方式。
`
  }
};

/**
 * 错误恢复协调器
 */
export class ErrorRecoveryCoordinator {
  private errorHistory = new Map<string, ErrorContext[]>();

  /**
   * 记录错误
   */
  recordError(agentRunId: string, error: ErrorContext): void {
    const history = this.errorHistory.get(agentRunId) ?? [];
    history.push(error);
    this.errorHistory.set(agentRunId, history);
  }

  /**
   * 决定是否应该恢复
   */
  shouldRecover(agentRunId: string, error: ErrorContext): boolean {
    const strategy = RECOVERY_STRATEGIES[error.category];
    if (!strategy) return false;

    const history = this.errorHistory.get(agentRunId) ?? [];
    const sameCategory = history.filter(e => e.category === error.category);
    
    return sameCategory.length < strategy.maxAttempts && strategy.shouldRetry(error);
  }

  /**
   * 生成恢复提示词
   */
  generateRecoveryPrompt(
    originalPrompt: string,
    agentRunId: string,
    error: ErrorContext
  ): string {
    const strategy = RECOVERY_STRATEGIES[error.category];
    if (!strategy) return originalPrompt;

    const history = this.errorHistory.get(agentRunId) ?? [];
    const enrichedError: ErrorContext = {
      ...error,
      attemptNumber: history.filter(e => e.category === error.category).length,
      previousAttempts: history
    };

    return strategy.adjustPrompt(originalPrompt, enrichedError);
  }

  /**
   * 清除历史
   */
  clear(agentRunId: string): void {
    this.errorHistory.delete(agentRunId);
  }
}
```

### 3.2 集成到 AgentRunScheduler

```typescript
// src/core/enhancedScheduler.ts

import { AgentRunScheduler } from '../../macos/Sources/KimiAgentCore/AgentRunScheduler.swift';
import { ErrorRecoveryCoordinator, categorizeError, type ErrorContext, ErrorCategory } from './errorRecovery.js';

export class EnhancedAgentRunScheduler extends AgentRunScheduler {
  private recoveryCoordinator = new ErrorRecoveryCoordinator();

  async executeWithRecovery(agentRun: AgentRun, executor: Executor): Promise<AgentResult> {
    try {
      return await executor(agentRun);
    } catch (rawError) {
      // 1. 分类错误
      const errorMessage = rawError instanceof Error ? rawError.message : String(rawError);
      const category = categorizeError(errorMessage);

      const errorContext: ErrorContext = {
        category,
        message: errorMessage,
        stackTrace: rawError instanceof Error ? rawError.stack : undefined,
        attemptNumber: 0
      };

      // 2. 记录错误
      this.recoveryCoordinator.recordError(agentRun.id, errorContext);

      // 3. 决定是否恢复
      if (!this.recoveryCoordinator.shouldRecover(agentRun.id, errorContext)) {
        throw rawError; // 不可恢复，抛出原始错误
      }

      // 4. 生成恢复提示词
      const recoveryPrompt = this.recoveryCoordinator.generateRecoveryPrompt(
        agentRun.definition.description,
        agentRun.id,
        errorContext
      );

      // 5. 创建恢复 AgentRun
      const recoveryRun: AgentRun = {
        ...agentRun,
        definition: {
          ...agentRun.definition,
          description: recoveryPrompt
        },
        state: 'queued'
      };

      // 6. 重试执行
      try {
        const result = await executor(recoveryRun);
        this.recoveryCoordinator.clear(agentRun.id);
        return result;
      } catch (retryError) {
        // 记录重试失败
        const retryErrorContext: ErrorContext = {
          category: categorizeError(retryError instanceof Error ? retryError.message : String(retryError)),
          message: retryError instanceof Error ? retryError.message : String(retryError),
          attemptNumber: 1
        };
        this.recoveryCoordinator.recordError(agentRun.id, retryErrorContext);
        
        // 如果还能恢复，递归重试
        if (this.recoveryCoordinator.shouldRecover(agentRun.id, retryErrorContext)) {
          return this.executeWithRecovery(recoveryRun, executor);
        }
        
        throw retryError;
      }
    }
  }
}
```

### 3.3 错误上下文收集

```typescript
// src/runtime/errorContextCollector.ts

import { exec } from 'node:child_process';
import { promisify } from 'node:util';

const execAsync = promisify(exec);

export interface EnrichedErrorContext {
  error: Error;
  command?: string;
  workingDirectory: string;
  gitStatus?: string;
  recentCommits?: string;
  environmentInfo?: Record<string, string>;
}

/**
 * 收集丰富的错误上下文
 */
export async function collectErrorContext(
  error: Error,
  workingDirectory: string,
  command?: string
): Promise<EnrichedErrorContext> {
  const context: EnrichedErrorContext = {
    error,
    command,
    workingDirectory
  };

  try {
    // Git 状态
    const { stdout: gitStatus } = await execAsync('git status --short', { cwd: workingDirectory });
    context.gitStatus = gitStatus;

    // 最近提交
    const { stdout: commits } = await execAsync('git log -3 --oneline', { cwd: workingDirectory });
    context.recentCommits = commits;
  } catch {
    // Git 信息收集失败，忽略
  }

  // 环境信息
  context.environmentInfo = {
    nodeVersion: process.version,
    platform: process.platform,
    arch: process.arch
  };

  return context;
}
```

## 使用示例

```typescript
// 在任务执行时
const scheduler = new EnhancedAgentRunScheduler(runs, 8);

await scheduler.drive(async (agentRun) => {
  return await scheduler.executeWithRecovery(agentRun, async (run) => {
    // 实际执行逻辑
    const result = await executeAgentRun(run);
    return result;
  });
});
```

## 效果预期

- **自动恢复率**：60-70%（编译错误、测试失败）
- **平均恢复时间**：< 30s
- **用户介入率**：降低 50%

## 监控指标

```typescript
export interface RecoveryMetrics {
  totalErrors: number;
  recoveredErrors: number;
  failedRecoveries: number;
  averageRecoveryTime: number;
  errorsByCategory: Record<ErrorCategory, number>;
}
```
