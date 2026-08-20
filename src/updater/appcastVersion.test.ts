import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';

// vitest runs from the repository root (npm test).
const repoRoot = process.cwd();

/**
 * Sparkle compares sparkle:version against the host app's CFBundleVersion
 * component-wise as integers. A stripped build number like "034" outranks an
 * installed "0.3.4" (34 > 0), so the updater would offer the same version
 * forever. The contract: feed versions and CFBundleVersion share the exact
 * dotted semver form.
 */
describe('Sparkle appcast version contract', () => {
  const appcast = readFileSync(path.join(repoRoot, 'appcast.xml'), 'utf8');

  it('every sparkle:version is a dotted semver, never a stripped build number', () => {
    const versions = [...appcast.matchAll(/<sparkle:version>([^<]+)<\/sparkle:version>/g)].map((m) => m[1]);
    expect(versions.length).toBeGreaterThan(0);
    for (const version of versions) {
      expect(version, `sparkle:version ${version} must keep dots`).toMatch(/^\d+\.\d+\.\d+$/);
    }
  });

  it('sparkle:version always equals the item shortVersionString', () => {
    const items = [...appcast.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => m[1]);
    expect(items.length).toBeGreaterThan(0);
    for (const item of items) {
      const version = item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1];
      const short = item.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1];
      expect(version, 'item must carry sparkle:version').toBeTruthy();
      expect(short, 'item must carry sparkle:shortVersionString').toBeTruthy();
      expect(version).toBe(short);
    }
  });

  it('packaging passes the dotted version to update-appcast, never a stripped one', () => {
    const script = readFileSync(path.join(repoRoot, 'scripts/package-kimi-code-agent-native.mjs'), 'utf8');
    expect(script).not.toContain('"--build", version.replaceAll(".", "")');
  });

  it('CFBundleVersion is written as the dotted version', () => {
    const script = readFileSync(path.join(repoRoot, 'scripts/package-kimi-code-agent-native.mjs'), 'utf8');
    expect(script).toContain('<key>CFBundleVersion</key><string>${version}</string>');
  });
});
