import { chmod, mkdir, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { createKimiOpenCodeConfig, resolveOpenCodeFusionPaths } from './openCodeFusion.js';

export type PrepareOpenCodeFusionConfigInput = {
  applicationSupportDirectory: string;
  baseURL?: string;
  modelID: string;
};

export type PreparedOpenCodeFusionConfig = ReturnType<typeof resolveOpenCodeFusionPaths>;

export async function prepareOpenCodeFusionConfig(
  input: PrepareOpenCodeFusionConfigInput
): Promise<PreparedOpenCodeFusionConfig> {
  const paths = resolveOpenCodeFusionPaths(input.applicationSupportDirectory);
  await mkdir(paths.configDirectory, { recursive: true, mode: 0o700 });
  await mkdir(paths.stateDirectory, { recursive: true, mode: 0o700 });

  const temporaryConfigFile = path.join(paths.configDirectory, `.opencode.${process.pid}.${Date.now()}.tmp`);
  const content = `${JSON.stringify(createKimiOpenCodeConfig(input), null, 2)}\n`;
  await writeFile(temporaryConfigFile, content, { encoding: 'utf8', mode: 0o600 });
  await chmod(temporaryConfigFile, 0o600);
  await rename(temporaryConfigFile, paths.configFile);
  await chmod(paths.configFile, 0o600);
  return paths;
}
