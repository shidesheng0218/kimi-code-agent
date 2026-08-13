export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
}

export interface BudgetLimit {
  maxTokens?: number;
}

export interface BudgetAssessment {
  state: 'active' | 'warning' | 'exhausted';
  ratio: number;
  remainingTokens: number | undefined;
}

export function assessBudget(usage: TokenUsage, limit: BudgetLimit): BudgetAssessment {
  if (limit.maxTokens === undefined) {
    return { state: 'active', ratio: 0, remainingTokens: undefined };
  }

  const usedTokens = usage.inputTokens + usage.outputTokens;
  const ratio = Number((usedTokens / limit.maxTokens).toFixed(4));
  const remainingTokens = Math.max(0, limit.maxTokens - usedTokens);

  if (ratio >= 1) {
    return { state: 'exhausted', ratio, remainingTokens };
  }

  if (ratio >= 0.8) {
    return { state: 'warning', ratio, remainingTokens };
  }

  return { state: 'active', ratio, remainingTokens };
}
