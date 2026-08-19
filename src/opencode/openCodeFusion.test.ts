import { describe, expect, it } from 'vitest';
import {
  createKimiOpenCodeConfig,
  createOpenCodeLaunchEnvironment,
  resolveOpenCodeFoundationPaths,
  resolveOpenCodeFusionPaths,
  validateKimiEndpoint
} from './openCodeFusion.js';

describe('OpenCode fusion profile', () => {
  it('configures OpenCode through its Kimi-compatible provider without persisting the API key', () => {
    const config = createKimiOpenCodeConfig({
      baseURL: 'https://api.moonshot.cn/v1/',
      modelID: 'kimi-k2.7-code'
    });

    expect(config.model).toBe('moonshotai-cn/kimi-k2.7-code');
    expect(config.provider['moonshotai-cn']).toMatchObject({
      api: 'https://api.moonshot.cn/v1',
      npm: '@ai-sdk/openai-compatible',
      env: ['KIMI_API_KEY'],
      options: { apiKey: '{env:KIMI_API_KEY}', baseURL: 'https://api.moonshot.cn/v1' }
    });
    expect(config.provider['moonshotai-cn'].models['kimi-k2.7-code']).toMatchObject({
      reasoning: true,
      tool_call: true
    });
    expect(config.plugin).toEqual(['{env:KIMI_OPENCODE_PLUGIN}']);
    expect(JSON.stringify(config)).not.toContain('secret-api-key');
  });

  it('keeps public read-only web research automatic while retaining prompts for side effects', () => {
    const config = createKimiOpenCodeConfig({ modelID: 'kimi-k2.7-code' });

    expect(config.permission).toMatchObject({
      websearch: 'allow',
      webfetch: 'allow',
      bash: 'ask',
      edit: 'ask',
      task: 'allow'
    });
  });

  it('passes the API key only through the launched OpenCode process environment', () => {
    expect(createOpenCodeLaunchEnvironment({
      KIMI_API_KEY: 'secret-api-key',
      PATH: '/usr/bin'
    })).toMatchObject({
      KIMI_API_KEY: 'secret-api-key',
      OPENCODE_CLIENT: 'kimi-code-agent',
      OPENCODE_CONFIG_DIR: expect.stringContaining('Kimi Code Agent/opencode')
    });
  });

  it('keeps the generated OpenCode profile and state inside the Kimi application-support root', () => {
    expect(resolveOpenCodeFusionPaths('/tmp/Kimi Code Agent')).toEqual({
      configDirectory: '/tmp/Kimi Code Agent/opencode',
      configFile: '/tmp/Kimi Code Agent/opencode/opencode.json',
      stateDirectory: '/tmp/Kimi Code Agent/opencode/state'
    });
  });

  it('uses the vendored OpenCode plugin as the only native-adapter integration point', () => {
    expect(resolveOpenCodeFoundationPaths('/tmp/kimi-agent')).toEqual({
      foundationDirectory: '/tmp/kimi-agent/vendor/opencode',
      nativePluginFile: '/tmp/kimi-agent/vendor/opencode/packages/kimi-code-agent-plugin/src/index.ts'
    });
  });

  it('rejects non-HTTPS and non-Kimi endpoints before OpenCode is started', () => {
    expect(() => validateKimiEndpoint('http://api.moonshot.cn/v1')).toThrow('HTTPS');
    expect(() => validateKimiEndpoint('https://example.com/v1')).toThrow('Kimi');
  });
});
