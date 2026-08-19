import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { afterEach, describe, expect, it } from 'vitest';
import { prepareEngineFusionConfig } from './prepareFusion.js';

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(directory => rm(directory, { recursive: true, force: true })));
});

describe('prepareEngineFusionConfig', () => {
  it('writes a private secret-free engine profile and state directory', async () => {
    const applicationSupportDirectory = await mkdtemp(path.join(tmpdir(), 'kimi-engine-'));
    temporaryDirectories.push(applicationSupportDirectory);

    const prepared = await prepareEngineFusionConfig({
      applicationSupportDirectory,
      baseURL: 'https://api.moonshot.cn/v1',
      modelID: 'kimi-k2.7-code'
    });

    const config = await readFile(prepared.configFile, 'utf8');
    expect(JSON.parse(config)).toMatchObject({
      model: 'moonshotai-cn/kimi-k2.7-code',
      provider: { 'moonshotai-cn': { options: { apiKey: '{env:KIMI_API_KEY}' } } }
    });
    expect(config).not.toContain('secret-api-key');
    expect((await stat(prepared.configFile)).mode & 0o777).toBe(0o600);
    expect((await stat(prepared.stateDirectory)).isDirectory()).toBe(true);
  });

  it('does not import Kimi Agent Desktop state into the Kimi Code Agent directory', async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'kimi-brand-migration-'));
    temporaryDirectories.push(root);
    const legacySupportDirectory = path.join(root, 'Kimi Agent Desktop');
    const applicationSupportDirectory = path.join(root, 'Kimi Code Agent');
    const legacyStateFile = path.join(legacySupportDirectory, 'opencode', 'state', 'session.json');
    await mkdir(path.dirname(legacyStateFile), { recursive: true });
    await writeFile(legacyStateFile, '{"session":"legacy"}\n', 'utf8');

    const prepared = await prepareEngineFusionConfig({
      applicationSupportDirectory,
      modelID: 'kimi-k2.7-code'
    });

    await expect(readFile(path.join(prepared.stateDirectory, 'session.json'), 'utf8')).rejects.toThrow('ENOENT');
    expect(await readFile(legacyStateFile, 'utf8')).toBe('{"session":"legacy"}\n');
  });
});
