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

  if (context?.command?.includes('tsc') || lower.includes('typescript error') || lower.includes('ts(')) {
    return ErrorCategory.COMPILATION_ERROR;
  }

  if (context?.command?.includes('test') || lower.includes('test failed') || lower.includes('tests failed')) {
    return ErrorCategory.TEST_FAILURE;
  }

  if (lower.includes('permission denied') || lower.includes('eacces') || context?.exitCode === 126) {
    return ErrorCategory.PERMISSION_DENIED;
  }

  if (lower.includes('timeout') || lower.includes('timed out')) {
    return ErrorCategory.TIMEOUT;
  }

  if (lower.includes('enoent') || lower.includes('cannot find module') || lower.includes('command not found')) {
    return ErrorCategory.TOOL_EXECUTION_ERROR;
  }

  if (lower.includes('error:') || lower.includes('exception') || lower.includes('failed')) {
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

## ⚠️ 上次尝试失败 - 编译错误

\`\`\`
${error.message}
\`\`\`

${error.stackTrace ? `\n**详细错误信息**：\n\`\`\`\n${error.stackTrace.slice(0, 1000)}\n\`\`\`\n` : ''}

## 🔧 恢复指引

1. **仔细阅读错误信息**，定位具体的类型错误或语法错误位置
2. **使用 Read 工具**查看报错文件的当前完整内容
3. **修复错误**：
   - 检查类型定义是否正确
   - 确认所有导入语句完整
   - 验证泛型参数是否匹配
4. **验证修复**：修改后在心里模拟类型检查
5. 如果是复杂的类型推导问题，可以添加显式类型注解

**当前尝试次数**：${error.attemptNumber + 1}/3

${error.attemptNumber >= 2 ? '\n⚠️ **这是最后一次尝试**，请格外仔细地检查所有类型定义。\n' : ''}
`
  },

  [ErrorCategory.TEST_FAILURE]: {
    name: 'test-fix',
    description: '修复测试失败',
    maxAttempts: 3,
    shouldRetry: (error) => error.attemptNumber < 3,
    adjustPrompt: (original, error) => `
${original}

## ⚠️ 上次尝试失败 - 测试失败

\`\`\`
${error.message}
\`\`\`

${error.stackTrace ? `\n**堆栈跟踪**：\n\`\`\`\n${error.stackTrace.slice(0, 1000)}\n\`\`\`\n` : ''}

## 🔧 恢复指引

1. **分析失败原因**：
   - 断言不匹配？实际值 vs 期望值是什么？
   - 运行时错误？哪一行代码抛出异常？
   - 异步问题？Promise 是否正确等待？

2. **定位问题**：
   - 使用 Read 工具查看失败的测试文件
   - 查看被测试的实现代码
   - 检查测试数据是否正确

3. **修复方案**：
   - 如果是实现错误：修复实现逻辑
   - 如果是测试错误：调整测试期望
   - 如果是边界情况：补充边界处理

**当前尝试次数**：${error.attemptNumber + 1}/3

${error.attemptNumber >= 1 ? '\n💡 **提示**：考虑添加 console.log 或调试断点来定位问题。\n' : ''}
`
  },

  [ErrorCategory.RUNTIME_ERROR]: {
    name: 'runtime-fix',
    description: '修复运行时错误',
    maxAttempts: 2,
    shouldRetry: (error) => error.attemptNumber < 2,
    adjustPrompt: (original, error) => `
${original}

## ⚠️ 上次尝试失败 - 运行时错误

\`\`\`
${error.message}
\`\`\`

${error.stackTrace ? `\n**堆栈跟踪**：\n\`\`\`\n${error.stackTrace.slice(0, 1000)}\n\`\`\`\n` : ''}

## 🔧 恢复指引

1. **常见运行时错误检查**：
   - null/undefined 引用（使用可选链 ?. 或空值合并 ??）
   - 数组越界访问
   - 异步操作未正确处理（缺少 await）
   - 对象属性不存在

2. **防御性编程**：
   - 添加输入验证
   - 使用 try-catch 包裹可能失败的代码
   - 提供默认值和降级方案

3. **调试步骤**：
   - 从堆栈跟踪定位出错代码行
   - 检查该行代码的所有变量值
   - 理解为什么会出现意外状态

**当前尝试次数**：${error.attemptNumber + 1}/2
`
  },

  [ErrorCategory.PERMISSION_DENIED]: {
    name: 'permission-fix',
    description: '权限错误提示',
    maxAttempts: 1,
    shouldRetry: () => false,
    adjustPrompt: (original, error) => `
${original}

## 🚫 权限错误

\`\`\`
${error.message}
\`\`\`

${error.failedCommand ? `**失败的命令**：\`${error.failedCommand}\`\n\n` : ''}

权限错误通常需要用户手动处理：

1. **文件权限**：检查文件/目录是否有读写权限
2. **进程占用**：确认没有其他进程占用文件
3. **系统权限**：某些操作可能需要管理员权限

**建议操作**：
- macOS/Linux: \`chmod +x <file>\` 或 \`sudo <command>\`
- 检查文件是否被其他程序打开
- 确认工作目录路径正确

⚠️ 权限问题无法自动恢复，请人工解决后重新运行任务。
`
  },

  [ErrorCategory.TOOL_EXECUTION_ERROR]: {
    name: 'tool-fix',
    description: '工具执行错误修复',
    maxAttempts: 2,
    shouldRetry: (error) => error.attemptNumber < 2,
    adjustPrompt: (original, error) => `
${original}

## ⚠️ 上次尝试失败 - 工具执行错误

\`\`\`
${error.message}
\`\`\`

${error.failedCommand ? `**失败的命令**：\`${error.failedCommand}\`\n\n` : ''}

## 🔧 恢复指引

1. **依赖检查**：
   - 运行 \`npm install\` 确保所有依赖已安装
   - 检查 package.json 中的 dependencies 和 devDependencies

2. **命令检查**：
   - 验证命令拼写是否正确
   - 检查 package.json 的 scripts 部分
   - 尝试使用 npx 运行：\`npx <command>\`

3. **路径检查**：
   - 确认可执行文件路径正确
   - 检查相对路径 vs 绝对路径

4. **环境检查**：
   - Node.js 版本是否符合要求
   - 环境变量是否正确设置

**当前尝试次数**：${error.attemptNumber + 1}/2

${error.attemptNumber >= 1 ? '\n💡 **提示**：尝试运行 \`npm ci\` 清理并重新安装依赖。\n' : ''}
`
  },

  [ErrorCategory.TIMEOUT]: {
    name: 'timeout-recovery',
    description: '超时恢复',
    maxAttempts: 1,
    shouldRetry: (error) => error.attemptNumber === 0,
    adjustPrompt: (original, error) => `
${original}

## ⏱️ 执行超时

${error.failedCommand ? `命令 \`${error.failedCommand}\` 执行超时。\n\n` : ''}

## 🔧 恢复指引

1. **简化任务**：将大任务分解为多个小步骤
2. **优化性能**：
   - 检查是否有死循环
   - 优化算法复杂度
   - 减少不必要的计算

3. **检查阻塞**：
   - 是否有未完成的异步操作
   - 是否在等待用户输入
   - 网络请求是否卡住

4. **增加超时时间**（如果任务本身需要长时间运行）

**当前尝试次数**：${error.attemptNumber + 1}/1
`
  },

  [ErrorCategory.UNKNOWN]: {
    name: 'generic-retry',
    description: '通用重试',
    maxAttempts: 1,
    shouldRetry: (error) => error.attemptNumber === 0,
    adjustPrompt: (original, error) => `
${original}

## ⚠️ 上次尝试遇到错误

\`\`\`
${error.message}
\`\`\`

请重新分析问题并尝试不同的实现方式。考虑：
1. 是否理解错了需求？
2. 是否有更简单的实现方案？
3. 是否需要查看更多相关代码？

**当前尝试次数**：${error.attemptNumber + 1}/1
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
   * 获取错误历史
   */
  getHistory(agentRunId: string): ErrorContext[] {
    return this.errorHistory.get(agentRunId) ?? [];
  }

  /**
   * 清除历史
   */
  clear(agentRunId: string): void {
    this.errorHistory.delete(agentRunId);
  }

  /**
   * 生成错误摘要
   */
  generateErrorSummary(agentRunId: string): string {
    const history = this.getHistory(agentRunId);
    if (history.length === 0) return '无错误记录';

    const summary: string[] = ['## 错误历史\n'];

    const byCategory = new Map<ErrorCategory, number>();
    for (const error of history) {
      byCategory.set(error.category, (byCategory.get(error.category) ?? 0) + 1);
    }

    for (const [category, count] of byCategory) {
      summary.push(`- ${category}: ${count} 次`);
    }

    summary.push(`\n总尝试次数：${history.length}`);

    return summary.join('\n');
  }
}
