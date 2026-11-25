import { describe, expect, it } from 'vitest';
import {
  createEngineLaunchEnvironment,
  resolveEngineFoundationPaths,
  resolveEngineFusionPaths
} from './engineFusion.js';

describe('Engine fusion launch environment', () => {
  it('passes the API key only through the launched engine process environment', () => {
    expect(createEngineLaunchEnvironment({
      KIMI_API_KEY: 'secret-api-key',
      PATH: '/usr/bin'
    })).toMatchObject({
      KIMI_API_KEY: 'secret-api-key',
      OPENCODE_CLIENT: 'kimi-code-agent',
      OPENCODE_CONFIG_DIR: expect.stringContaining('Kimi Code Agent/engine')
    });
  });

  it('keeps the engine fusion paths inside the Kimi application-support root', () => {
    expect(resolveEngineFusionPaths('/tmp/Kimi Code Agent')).toEqual({
      configDirectory: '/tmp/Kimi Code Agent/engine',
      configFile: '/tmp/Kimi Code Agent/engine/engine.json',
      stateDirectory: '/tmp/Kimi Code Agent/engine/state'
    });
  });

  it('uses the vendored engine plugin as the only native-adapter integration point', () => {
    expect(resolveEngineFoundationPaths('/tmp/kimi-agent')).toEqual({
      foundationDirectory: '/tmp/kimi-agent/vendor/engine',
      nativePluginFile: '/tmp/kimi-agent/vendor/engine/packages/kimi-code-agent-plugin/src/index.ts'
    });
  });
});
