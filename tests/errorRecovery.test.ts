// tests/errorRecovery.test.ts

import { describe, it, expect } from 'vitest';
import { categorizeError, ErrorCategory, ErrorRecoveryCoordinator } from '../src/core/errorRecovery.js';

describe('ErrorRecovery', () => {
  it('should categorize compilation errors', () => {
    const error = "src/index.ts(10,5): error TS2322: Type 'string' is not assignable to type 'number'";
    const category = categorizeError(error);

    expect(category).toBe(ErrorCategory.COMPILATION_ERROR);
  });

  it('should categorize test failures', () => {
    const error = "FAIL src/auth.test.ts - Expected 200 but got 401";
    const category = categorizeError(error, { command: 'npm test' });

    expect(category).toBe(ErrorCategory.TEST_FAILURE);
  });

  it('should track error history', () => {
    const coordinator = new ErrorRecoveryCoordinator();
    const agentId = 'test-agent-1';

    coordinator.recordError(agentId, {
      category: ErrorCategory.COMPILATION_ERROR,
      message: 'Type error',
      attemptNumber: 0
    });

    const history = coordinator.getHistory(agentId);
    expect(history).toHaveLength(1);
  });

  it('should decide when to retry', () => {
    const coordinator = new ErrorRecoveryCoordinator();
    const agentId = 'test-agent-1';

    const error = {
      category: ErrorCategory.COMPILATION_ERROR,
      message: 'Type error',
      attemptNumber: 0
    };

    coordinator.recordError(agentId, error);

    const shouldRecover = coordinator.shouldRecover(agentId, error);
    expect(shouldRecover).toBe(true);
  });

  it('should stop retrying after max attempts', () => {
    const coordinator = new ErrorRecoveryCoordinator();
    const agentId = 'test-agent-1';

    // 记录 3 次编译错误
    for (let i = 0; i < 3; i++) {
      coordinator.recordError(agentId, {
        category: ErrorCategory.COMPILATION_ERROR,
        message: 'Type error',
        attemptNumber: i
      });
    }

    const shouldRecover = coordinator.shouldRecover(agentId, {
      category: ErrorCategory.COMPILATION_ERROR,
      message: 'Type error',
      attemptNumber: 3
    });

    expect(shouldRecover).toBe(false);
  });
});
