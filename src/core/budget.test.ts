import { describe, expect, it } from 'vitest';
import { assessBudget } from './budget';

describe('assessBudget', () => {
  it('reports warning after reaching eighty percent', () => {
    expect(assessBudget({ inputTokens: 600, outputTokens: 200 }, { maxTokens: 1_000 })).toEqual({
      state: 'warning',
      ratio: 0.8,
      remainingTokens: 200
    });
  });

  it('pauses when the hard token budget is exhausted', () => {
    expect(assessBudget({ inputTokens: 900, outputTokens: 200 }, { maxTokens: 1_000 })).toEqual({
      state: 'exhausted',
      ratio: 1.1,
      remainingTokens: 0
    });
  });

  it('stays active when no token limit is configured', () => {
    expect(assessBudget({ inputTokens: 10_000, outputTokens: 5_000 }, {})).toEqual({
      state: 'active',
      ratio: 0,
      remainingTokens: undefined
    });
  });
});
