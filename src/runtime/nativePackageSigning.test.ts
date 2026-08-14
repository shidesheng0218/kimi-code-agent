import { describe, expect, it } from 'vitest';

describe('native macOS package signing', () => {
  it('uses an ad-hoc signature when no stable signing identity is configured', async () => {
    const module = await import('../../scripts/package-native-macos.mjs') as unknown as {
      codesignArgs: (input: { appPath: string; identity?: string }) => string[];
    };
    const args = module.codesignArgs({
      appPath: '/tmp/Kimi Agent Desktop.app',
      identity: undefined
    });

    expect(args).toContain('-');
    expect(args).not.toContain(undefined);
  });

  it('derives a release version from a v-prefixed Git tag', async () => {
    const module = await import('../../scripts/package-native-macos.mjs') as unknown as {
      releaseVersion: (environment: Record<string, string | undefined>) => string;
    };

    expect(module.releaseVersion({ KIMI_VERSION: 'v1.4.0' })).toBe('1.4.0');
  });

  it('does not ship the deprecated Node web bridge in the default native runtime', async () => {
    const module = await import('../../scripts/package-native-macos.mjs') as unknown as {
      nativeRuntimeResourceNames: () => string[];
    };

    expect(module.nativeRuntimeResourceNames()).not.toContain('web-research-bridge.cjs');
  });
});
