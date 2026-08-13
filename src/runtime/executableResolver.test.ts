import { describe, expect, it } from 'vitest';
import { resolveKimiExecutable } from './executableResolver';

describe('resolveKimiExecutable', () => {
  it('uses the managed CLI when it is available', () => {
    const result = resolveKimiExecutable('managed', '/extension', candidate => candidate.endsWith('kimi.mjs'));

    expect(result).toBe('/extension/dist/runtime/kimi.mjs');
  });

  it('falls back to PATH when the managed CLI is unavailable', () => {
    expect(resolveKimiExecutable('managed', '/extension', () => false)).toBe('kimi');
  });

  it('honors an explicit executable path', () => {
    expect(resolveKimiExecutable('/opt/homebrew/bin/kimi', '/extension', () => true)).toBe(
      '/opt/homebrew/bin/kimi'
    );
  });
});
