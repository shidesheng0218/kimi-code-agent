import os from 'node:os';
import path from 'node:path';

export const kimiCodeAgentApplicationSupportName = 'Kimi Code Agent';

export interface EngineFoundationPaths {
  foundationDirectory: string;
  nativePluginFile: string;
}

export interface EngineFusionPaths {
  configDirectory: string;
  configFile: string;
  stateDirectory: string;
}

export function resolveEngineFoundationPaths(rootDirectory: string): EngineFoundationPaths {
  const foundationDirectory = path.join(rootDirectory, 'vendor', 'engine');
  return {
    foundationDirectory,
    nativePluginFile: path.join(foundationDirectory, 'packages', 'kimi-code-agent-plugin', 'src', 'index.ts')
  };
}

export function resolveEngineFusionPaths(applicationSupportRoot: string): EngineFusionPaths {
  const configDirectory = path.join(applicationSupportRoot, 'engine');
  return {
    configDirectory,
    configFile: path.join(configDirectory, 'engine.json'),
    stateDirectory: path.join(configDirectory, 'state')
  };
}

export function createEngineLaunchEnvironment(environment: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const applicationSupport = path.join(os.homedir(), 'Library', 'Application Support', kimiCodeAgentApplicationSupportName);
  return {
    ...environment,
    OPENCODE_CLIENT: 'kimi-code-agent',
    OPENCODE_CONFIG_DIR: resolveEngineFusionPaths(applicationSupport).configDirectory
  };
}
