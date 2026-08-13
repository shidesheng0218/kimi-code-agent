import { describe, expect, it, vi } from 'vitest';
import { runKimiLogin, type LoginImplementation } from './authAdapter';

describe('runKimiLogin', () => {
  it('opens the OAuth URL supplied by Kimi CLI', async () => {
    const openUrl = vi.fn(async (_url: string) => undefined);
    const login: LoginImplementation = vi.fn(async options => {
      options.onUrl?.('https://kimi.com/oauth');
      return { success: true };
    });

    const result = await runKimiLogin('/managed/kimi.mjs', openUrl, login);

    expect(result).toEqual({ success: true });
    expect(openUrl).toHaveBeenCalledWith('https://kimi.com/oauth');
    expect(login).toHaveBeenCalledWith(
      expect.objectContaining({ executable: '/managed/kimi.mjs', onUrl: expect.any(Function) })
    );
  });
});
