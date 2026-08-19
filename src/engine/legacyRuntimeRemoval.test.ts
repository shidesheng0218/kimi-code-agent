import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

const root = process.cwd();

describe('Kimi Code Agent native runtime', () => {
  it('exposes the native SwiftUI packaging path and no retired Desktop target', async () => {
    const packageJSON = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8')) as { scripts: Record<string, string> };
    const swiftPackage = await readFile(path.join(root, 'macos', 'Package.swift'), 'utf8');

    expect(packageJSON.scripts).toHaveProperty('native:build');
    expect(packageJSON.scripts).toHaveProperty('native:package');
    expect(packageJSON.scripts['engine:package']).toBe('npm run native:package');
    expect(packageJSON.scripts).not.toHaveProperty('opencode:dev');
    expect(packageJSON.scripts).not.toHaveProperty('update');
    expect(swiftPackage).not.toContain('KimiAgentDesktop');
    expect(swiftPackage).toContain('name: "KimiCodeAgent"');
  });
});
