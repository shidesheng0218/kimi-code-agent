// src/runtime/autoVerification.ts

import { exec } from 'node:child_process';
import { promisify } from 'node:util';

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
  testPattern?: string;
}

/**
 * 根据变更文件智能决定验证计划
 */
export function decideVerificationPlan(
  changedFiles: string[],
  projectType: 'node' | 'java' | 'python' | 'go' | 'rust' = 'node'
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
    f.includes('package.json') || f.includes('tsconfig.json') || f.includes('vite.config') || f.includes('webpack.config')
  );

  return {
    shouldCompile: hasSourceChanges || hasConfigChanges,
    shouldRunTests: hasSourceChanges || hasTestChanges,
    shouldLint: hasSourceChanges,
    shouldBuild: hasConfigChanges,
    shouldVerifyBrowser: hasFrontendChanges,
    testPattern: hasTestChanges && changedFiles.filter(f => f.includes('.test.') || f.includes('.spec.')).length === 1
      ? changedFiles.find(f => f.includes('.test.') || f.includes('.spec.'))
      : undefined
  };
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

  return results;
}

async function runCompilation(workspacePath: string): Promise<VerificationResult> {
  const start = Date.now();
  try {
    const { stdout, stderr } = await execAsync('npm run check 2>&1 || npx tsc --noEmit 2>&1', {
      cwd: workspacePath,
      timeout: 60000,
      shell: '/bin/bash'
    });

    const output = stdout + stderr;
    const hasErrors = /error\s+TS\d+/i.test(output);

    return {
      passed: !hasErrors,
      type: 'compilation',
      output,
      duration: Date.now() - start,
      errors: hasErrors ? parseCompilationErrors(output) : undefined
    };
  } catch (error: any) {
    return {
      passed: false,
      type: 'compilation',
      output: error.stdout + error.stderr,
      duration: Date.now() - start,
      errors: parseCompilationErrors(error.stdout + error.stderr)
    };
  }
}

async function runLinting(workspacePath: string): Promise<VerificationResult> {
  const start = Date.now();
  try {
    const { stdout, stderr } = await execAsync('npm run lint 2>&1 || npx eslint . --ext .ts,.tsx,.js,.jsx 2>&1', {
      cwd: workspacePath,
      timeout: 30000,
      shell: '/bin/bash'
    });

    const output = stdout + stderr;
    const warnings = parseLintWarnings(output);

    return {
      passed: true,
      type: 'linting',
      output,
      duration: Date.now() - start,
      warnings: warnings.length > 0 ? warnings : undefined
    };
  } catch (error: any) {
    const output = error.stdout + error.stderr;
    return {
      passed: false,
      type: 'linting',
      output,
      duration: Date.now() - start,
      errors: parseLintErrors(output)
    };
  }
}

async function runTests(workspacePath: string, pattern?: string): Promise<VerificationResult> {
  const start = Date.now();
  const testCommand = pattern
    ? `npm test -- ${pattern} 2>&1`
    : 'npm test 2>&1';

  try {
    const { stdout, stderr } = await execAsync(testCommand, {
      cwd: workspacePath,
      timeout: 120000,
      shell: '/bin/bash'
    });

    const output = stdout + stderr;
    const testStats = parseTestOutput(output);

    return {
      passed: testStats.failed === 0,
      type: 'unit-test',
      output,
      duration: Date.now() - start,
      errors: testStats.failed > 0 ? testStats.failureMessages : undefined
    };
  } catch (error: any) {
    const output = error.stdout + error.stderr;
    return {
      passed: false,
      type: 'unit-test',
      output,
      duration: Date.now() - start,
      errors: parseTestOutput(output).failureMessages
    };
  }
}

async function runBuild(workspacePath: string): Promise<VerificationResult> {
  const start = Date.now();
  try {
    const { stdout, stderr } = await execAsync('npm run build 2>&1', {
      cwd: workspacePath,
      timeout: 180000,
      shell: '/bin/bash'
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
  const totalMatch = output.match(/Tests?:\s+(\d+)\s+total/i);
  const passedMatch = output.match(/(\d+)\s+passed/i);
  const failedMatch = output.match(/(\d+)\s+failed/i);

  const total = totalMatch ? parseInt(totalMatch[1]) : 0;
  const passed = passedMatch ? parseInt(passedMatch[1]) : 0;
  const failed = failedMatch ? parseInt(failedMatch[1]) : 0;

  // 提取失败消息
  const failureMessages: string[] = [];
  const lines = output.split('\n');
  let inFailureBlock = false;
  let currentFailure = '';

  for (const line of lines) {
    if (line.includes('FAIL') || line.includes('✕') || line.includes('×')) {
      if (currentFailure) {
        failureMessages.push(currentFailure.trim());
      }
      currentFailure = line;
      inFailureBlock = true;
    } else if (inFailureBlock) {
      if (line.trim() === '' || line.includes('Test Suites:') || line.includes('Tests:')) {
        if (currentFailure) {
          failureMessages.push(currentFailure.trim());
        }
        currentFailure = '';
        inFailureBlock = false;
      } else {
        currentFailure += '\n' + line;
      }
    }
  }

  if (currentFailure) {
    failureMessages.push(currentFailure.trim());
  }

  return { total, passed, failed, failureMessages: failureMessages.slice(0, 5) };
}

function parseCompilationErrors(stderr: string): string[] {
  const errors: string[] = [];

  // TypeScript 错误格式
  const errorRegex = /(.+\.tsx?)\((\d+),(\d+)\):\s+error\s+TS(\d+):\s+(.+)/g;
  let match;

  while ((match = errorRegex.exec(stderr)) !== null) {
    errors.push(`${match[1]}:${match[2]}:${match[3]} - TS${match[4]}: ${match[5]}`);
  }

  // 通用错误行
  if (errors.length === 0) {
    const lines = stderr.split('\n').filter(line =>
      line.toLowerCase().includes('error') && !line.includes('0 error')
    );
    errors.push(...lines.slice(0, 10));
  }

  return errors.length > 0 ? errors : [stderr.slice(0, 500)];
}

function parseLintErrors(stdout: string): string[] {
  const errors: string[] = [];
  const lines = stdout.split('\n');

  for (const line of lines) {
    if ((line.includes('error') || line.includes('✖')) && !line.includes('0 error')) {
      errors.push(line.trim());
    }
  }

  return errors.slice(0, 10);
}

function parseLintWarnings(stdout: string): string[] {
  const warnings: string[] = [];
  const lines = stdout.split('\n');

  for (const line of lines) {
    if (line.includes('warning') || line.includes('⚠')) {
      warnings.push(line.trim());
    }
  }

  return warnings.slice(0, 10);
}

/**
 * 生成验证报告
 */
export function generateVerificationReport(results: VerificationResult[]): string {
  const lines: string[] = [];

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
        lines.push(result.errors.slice(0, 3).join('\n'));
        if (result.errors.length > 3) {
          lines.push(`... 还有 ${result.errors.length - 3} 个错误`);
        }
        lines.push('```\n');
      }
    }

    if (result.warnings && result.warnings.length > 0) {
      lines.push(`⚠️ ${result.warnings.length} 个警告\n`);
    }
  }

  const summary = allPassed ? '✅ **所有验证通过**' : '❌ **部分验证失败**';
  return `${summary}\n\n${lines.join('\n')}`;
}
