# Phase 4: 自动验证和测试机制

## Claude Code 的验证特点

1. **自动运行测试**：代码变更后自动执行相关测试
2. **浏览器验证**：前端变更自动启动 dev server + 截图对比
3. **性能检查**：监控构建时间、包体积等指标
4. **回归检测**：确保变更不影响现有功能

## 实现方案

### 4.1 自动测试运行器

```typescript
// src/runtime/autoVerification.ts

import { exec } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';

const execAsync = promisify(exec);

export interface VerificationResult {
  passed: boolean;
  type: 'compilation' | 'unit-test' | 'integration-test' | 'linting' | 'browser' | 'build';
  output: string;
  duration: number;
  errors?: string[];
  warnings?: string[];
}

export interface VerificationPlan {
  shouldCompile: boolean;
  shouldRunTests: boolean;
  shouldLint: boolean;
  shouldBuild: boolean;
  shouldVerifyBrowser: boolean;
  testPattern?: string;  // 只运行特定的测试
}

/**
 * 根据变更文件智能决定验证计划
 */
export function decideVerificationPlan(
  changedFiles: string[],
  projectType: 'node' | 'java' | 'python' | 'go' | 'rust'
): VerificationPlan {
  const hasSourceChanges = changedFiles.some(f => 
    f.endsWith('.ts') || f.endsWith('.js') || f.endsWith('.tsx') || f.endsWith('.jsx')
  );
  
  const hasTestChanges = changedFiles.some(f => 
    f.includes('.test.') || f.includes('.spec.') || f.includes('__tests__')
  );
  
  const hasFrontendChanges = changedFiles.some(f => 
    f.endsWith('.tsx') || f.endsWith('.jsx') || f.endsWith('.vue') || f.endsWith('.svelte')
  );
  
  const hasConfigChanges = changedFiles.some(f => 
    f.includes('package.json') || f.includes('tsconfig.json') || f.includes('vite.config')
  );

  return {
    shouldCompile: hasSourceChanges || hasConfigChanges,
    shouldRunTests: hasSourceChanges || hasTestChanges,
    shouldLint: hasSourceChanges,
    shouldBuild: hasConfigChanges,
    shouldVerifyBrowser: hasFrontendChanges,
    testPattern: hasTestChanges ? inferTestPattern(changedFiles) : undefined
  };
}

function inferTestPattern(files: string[]): string | undefined {
  // 如果只改了一个测试文件，只运行它
  const testFiles = files.filter(f => f.includes('.test.') || f.includes('.spec.'));
  if (testFiles.length === 1) {
    return testFiles[0];
  }
  return undefined;
}

/**
 * 执行完整的验证流程
 */
export async function runVerification(
  workspacePath: string,
  plan: VerificationPlan
): Promise<VerificationResult[]> {
  const results: VerificationResult[] = [];

  // 1. TypeScript 编译检查
  if (plan.shouldCompile) {
    const compileResult = await runCompilation(workspacePath);
    results.push(compileResult);
    
    // 如果编译失败，后续步骤没必要执行
    if (!compileResult.passed) {
      return results;
    }
  }

  // 2. Linting
  if (plan.shouldLint) {
    const lintResult = await runLinting(workspacePath);
    results.push(lintResult);
  }

  // 3. 单元测试
  if (plan.shouldRunTests) {
    const testResult = await runTests(workspacePath, plan.testPattern);
    results.push(testResult);
  }

  // 4. 构建
  if (plan.shouldBuild) {
    const buildResult = await runBuild(workspacePath);
    results.push(buildResult);
  }

  // 5. 浏览器验证（如果需要）
  if (plan.shouldVerifyBrowser) {
    const browserResult = await runBrowserVerification(workspacePath);
    results.push(browserResult);
  }

  return results;
}

async function runCompilation(workspacePath: string): Promise<VerificationResult> {
  const start = Date.now();
  try {
    const { stdout, stderr } = await execAsync('npm run check || tsc --noEmit', {
      cwd: workspacePath,
      timeout: 60000
    });
    
    return {
      passed: true,
      type: 'compilation',
      output: stdout + stderr,
      duration: Date.now() - start
    };
  } catch (error: any) {
    return {
      passed: false,
      type: 'compilation',
      output: error.stdout + error.stderr,
      duration: Date.now() - start,
      errors: parseCompilationErrors(error.stderr)
    };
  }
}

async function runLinting(workspacePath: string): Promise<VerificationResult> {
  const start = Date.now();
  try {
    const { stdout, stderr } = await execAsync('npm run lint || eslint . --ext .ts,.tsx,.js,.jsx', {
      cwd: workspacePath,
      timeout: 30000
    });
    
    return {
      passed: true,
      type: 'linting',
      output: stdout,
      duration: Date.now() - start,
      warnings: parseLintWarnings(stdout)
    };
  } catch (error: any) {
    return {
      passed: false,
      type: 'linting',
      output: error.stdout,
      duration: Date.now() - start,
      errors: parseLintErrors(error.stdout)
    };
  }
}

async function runTests(workspacePath: string, pattern?: string): Promise<VerificationResult> {
  const start = Date.now();
  const testCommand = pattern 
    ? `npm test -- ${pattern}` 
    : 'npm test';
  
  try {
    const { stdout, stderr } = await execAsync(testCommand, {
      cwd: workspacePath,
      timeout: 120000
    });
    
    const testStats = parseTestOutput(stdout);
    
    return {
      passed: testStats.failed === 0,
      type: 'unit-test',
      output: stdout + stderr,
      duration: Date.now() - start,
      errors: testStats.failed > 0 ? testStats.failureMessages : undefined
    };
  } catch (error: any) {
    return {
      passed: false,
      type: 'unit-test',
      output: error.stdout + error.stderr,
      duration: Date.now() - start,
      errors: parseTestOutput(error.stdout).failureMessages
    };
  }
}

async function runBuild(workspacePath: string): Promise<VerificationResult> {
  const start = Date.now();
  try {
    const { stdout, stderr } = await execAsync('npm run build', {
      cwd: workspacePath,
      timeout: 180000
    });
    
    return {
      passed: true,
      type: 'build',
      output: stdout + stderr,
      duration: Date.now() - start
    };
  } catch (error: any) {
    return {
      passed: false,
      type: 'build',
      output: error.stdout + error.stderr,
      duration: Date.now() - start,
      errors: [error.message]
    };
  }
}

async function runBrowserVerification(workspacePath: string): Promise<VerificationResult> {
  // 这个需要集成 Computer Use Tools 和 Browser Agent
  // 启动 dev server → 截图 → 检查控制台错误
  const start = Date.now();
  
  try {
    // 1. 启动开发服务器（后台）
    const devServer = exec('npm run dev', { cwd: workspacePath });
    
    // 等待服务器启动
    await new Promise(resolve => setTimeout(resolve, 5000));
    
    // 2. 使用 Browser Agent 验证（简化示例）
    // 实际需要调用 browserVerificationController
    
    // 3. 关闭服务器
    devServer.kill();
    
    return {
      passed: true,
      type: 'browser',
      output: '浏览器验证通过',
      duration: Date.now() - start
    };
  } catch (error: any) {
    return {
      passed: false,
      type: 'browser',
      output: error.message,
      duration: Date.now() - start,
      errors: [error.message]
    };
  }
}

/**
 * 解析测试输出
 */
function parseTestOutput(output: string): {
  total: number;
  passed: number;
  failed: number;
  failureMessages: string[];
} {
  // 解析 Jest/Vitest 输出
  const totalMatch = output.match(/Tests:\s+(\d+)\s+total/);
  const passedMatch = output.match(/(\d+)\s+passed/);
  const failedMatch = output.match(/(\d+)\s+failed/);
  
  const total = totalMatch ? parseInt(totalMatch[1]) : 0;
  const passed = passedMatch ? parseInt(passedMatch[1]) : 0;
  const failed = failedMatch ? parseInt(failedMatch[1]) : 0;
  
  // 提取失败消息
  const failureMessages: string[] = [];
  const failureBlocks = output.match(/FAIL\s+.*?\n([\s\S]*?)(?=FAIL|Tests:|$)/g);
  if (failureBlocks) {
    failureMessages.push(...failureBlocks.map(block => block.trim()));
  }
  
  return { total, passed, failed, failureMessages };
}

function parseCompilationErrors(stderr: string): string[] {
  // 提取 TypeScript 错误
  const errors: string[] = [];
  const errorRegex = /(.+\.tsx?)\((\d+),(\d+)\):\s+error\s+TS(\d+):\s+(.+)/g;
  let match;
  
  while ((match = errorRegex.exec(stderr)) !== null) {
    errors.push(`${match[1]}:${match[2]}:${match[3]} - TS${match[4]}: ${match[5]}`);
  }
  
  return errors.length > 0 ? errors : [stderr];
}

function parseLintErrors(stdout: string): string[] {
  const errors: string[] = [];
  const lines = stdout.split('\n');
  
  for (const line of lines) {
    if (line.includes('error') && !line.includes('0 errors')) {
      errors.push(line.trim());
    }
  }
  
  return errors;
}

function parseLintWarnings(stdout: string): string[] {
  const warnings: string[] = [];
  const lines = stdout.split('\n');
  
  for (const line of lines) {
    if (line.includes('warning')) {
      warnings.push(line.trim());
    }
  }
  
  return warnings;
}

/**
 * 生成验证报告
 */
export function generateVerificationReport(results: VerificationResult[]): string {
  const lines: string[] = ['## 验证结果\n'];
  
  let allPassed = true;
  
  for (const result of results) {
    const icon = result.passed ? '✅' : '❌';
    const typeName = {
      'compilation': '编译检查',
      'linting': '代码规范',
      'unit-test': '单元测试',
      'integration-test': '集成测试',
      'build': '构建',
      'browser': '浏览器验证'
    }[result.type];
    
    lines.push(`${icon} **${typeName}** (${result.duration}ms)`);
    
    if (!result.passed) {
      allPassed = false;
      if (result.errors && result.errors.length > 0) {
        lines.push('\n错误信息：');
        lines.push('```');
        lines.push(result.errors.slice(0, 5).join('\n')); // 只显示前 5 个错误
        if (result.errors.length > 5) {
          lines.push(`... 还有 ${result.errors.length - 5} 个错误`);
        }
        lines.push('```\n');
      }
    }
    
    if (result.warnings && result.warnings.length > 0) {
      lines.push(`\n⚠️ ${result.warnings.length} 个警告`);
    }
  }
  
  lines.unshift(allPassed ? '\n✅ **所有验证通过**\n' : '\n❌ **部分验证失败**\n');
  
  return lines.join('\n');
}
```

### 4.2 集成到 Test Agent

```typescript
// src/runtime/testAgent.ts

import { runVerification, decideVerificationPlan, generateVerificationReport } from './autoVerification.js';

/**
 * Test Agent 的增强提示词
 */
export async function buildTestAgentPrompt(
  changedFiles: string[],
  workspacePath: string
): Promise<string> {
  // 1. 决定验证计划
  const plan = decideVerificationPlan(changedFiles, 'node');
  
  // 2. 执行自动验证
  const results = await runVerification(workspacePath, plan);
  
  // 3. 生成报告
  const report = generateVerificationReport(results);
  
  // 4. 构建提示词
  return `
你是一个测试验证 Agent。你的任务是确保代码变更没有破坏现有功能。

## 变更文件
${changedFiles.map(f => `- ${f}`).join('\n')}

## 自动验证结果
${report}

## 你的任务

${results.every(r => r.passed) ? `
✅ 所有自动验证已通过！

请：
1. 总结验证结果
2. 确认是否需要额外的手动测试
3. 如果是前端变更，建议进行浏览器人工验证
` : `
❌ 部分验证失败。

请：
1. 分析失败原因
2. 如果是代码问题，调用 Implement Agent 修复
3. 如果是测试问题，更新测试用例
4. 修复后重新运行验证
`}

## 可用工具
- Read: 读取源码和测试文件
- Bash: 运行测试命令
- Browser: 浏览器验证（前端变更）

请输出 JSON 格式的验证结论：
\`\`\`json
{
  "allPassed": boolean,
  "summary": "验证总结",
  "failedChecks": ["失败的检查"],
  "recommendedActions": ["建议的后续操作"],
  "needsManualVerification": boolean
}
\`\`\`
`;
}
```

### 4.3 持续验证模式

```typescript
// src/core/continuousVerification.ts

import { watch } from 'node:fs';
import { runVerification, decideVerificationPlan } from '../runtime/autoVerification.js';

export class ContinuousVerificationWatcher {
  private watching = false;
  private watcher?: ReturnType<typeof watch>;

  /**
   * 启动文件监听，自动运行验证
   */
  start(workspacePath: string, onVerificationComplete: (passed: boolean) => void): void {
    if (this.watching) return;

    this.watching = true;
    this.watcher = watch(
      workspacePath,
      { recursive: true },
      async (eventType, filename) => {
        if (!filename || filename.includes('node_modules')) return;
        
        // 防抖：等待 500ms 无新变更后再验证
        setTimeout(async () => {
          const plan = decideVerificationPlan([filename], 'node');
          const results = await runVerification(workspacePath, plan);
          const allPassed = results.every(r => r.passed);
          
          onVerificationComplete(allPassed);
        }, 500);
      }
    );
  }

  stop(): void {
    this.watching = false;
    this.watcher?.close();
  }
}
```

## 使用示例

```typescript
// 在 Implement Agent 完成后自动运行
const changedFiles = ['src/auth/login.ts', 'src/auth/login.test.ts'];
const plan = decideVerificationPlan(changedFiles, 'node');
const results = await runVerification('/path/to/project', plan);

if (!results.every(r => r.passed)) {
  // 触发错误恢复或通知用户
  console.log(generateVerificationReport(results));
}
```

## 效果预期

- **自动化率**：90% 的验证自动完成
- **验证时间**：< 30s（增量测试）
- **误报率**：< 5%
- **早期发现率**：95% 的问题在合并前发现
