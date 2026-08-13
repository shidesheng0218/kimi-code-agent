// tests/autoVerification.test.ts

import { describe, it, expect } from 'vitest';
import { decideVerificationPlan, generateVerificationReport } from '../src/runtime/autoVerification.js';
import type { VerificationResult } from '../src/runtime/autoVerification.js';

describe('AutoVerification', () => {
  it('should decide to compile when source files change', () => {
    const plan = decideVerificationPlan(['src/auth.ts', 'src/utils.ts']);

    expect(plan.shouldCompile).toBe(true);
    expect(plan.shouldRunTests).toBe(true);
  });

  it('should decide to run specific tests when test file changes', () => {
    const plan = decideVerificationPlan(['src/auth.test.ts']);

    expect(plan.shouldRunTests).toBe(true);
    expect(plan.testPattern).toBe('src/auth.test.ts');
  });

  it('should generate verification report', () => {
    const results: VerificationResult[] = [
      {
        passed: true,
        type: 'compilation',
        output: 'No errors',
        duration: 1000
      },
      {
        passed: false,
        type: 'unit-test',
        output: 'Test failed',
        duration: 2000,
        errors: ['Expected 200 but got 401']
      }
    ];

    const report = generateVerificationReport(results);

    expect(report).toContain('❌ **部分验证失败**');
    expect(report).toContain('✅ **编译检查**');
    expect(report).toContain('❌ **单元测试**');
  });
});
