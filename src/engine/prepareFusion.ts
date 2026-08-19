import { chmod, mkdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createKimiEngineConfig, resolveEngineFusionPaths } from './engineFusion.js';

export type PrepareEngineFusionConfigInput = {
  applicationSupportDirectory: string;
  baseURL?: string;
  modelID: string;
};

export type PreparedEngineFusionConfig = ReturnType<typeof resolveEngineFusionPaths>;

export async function prepareEngineFusionConfig(
  input: PrepareEngineFusionConfigInput
): Promise<PreparedEngineFusionConfig> {
  const paths = resolveEngineFusionPaths(input.applicationSupportDirectory);
  await mkdir(paths.configDirectory, { recursive: true, mode: 0o700 });
  await mkdir(paths.stateDirectory, { recursive: true, mode: 0o700 });

  const temporaryConfigFile = path.join(paths.configDirectory, `.engine.${process.pid}.${Date.now()}.tmp`);
  const content = `${JSON.stringify(createKimiEngineConfig(input), null, 2)}\n`;
  await writeFile(temporaryConfigFile, content, { encoding: 'utf8', mode: 0o600 });
  await chmod(temporaryConfigFile, 0o600);
  await rename(temporaryConfigFile, paths.configFile);
  await chmod(paths.configFile, 0o600);
  return paths;
}
