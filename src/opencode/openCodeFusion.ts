import { homedir } from 'node:os';
import path from 'node:path';

export type KimiOpenCodeProfileInput = {
  baseURL?: string;
  modelID: string;
};

export type KimiOpenCodeConfig = {
  $schema: string;
  model: string;
  small_model: string;
  plugin: string[];
  provider: Record<string, {
    name: string;
    api: string;
    npm: string;
    env: string[];
    options: Record<string, string | number | boolean>;
    models: Record<string, Record<string, unknown>>;
  }>;
  permission: Record<string, 'allow' | 'ask'>;
  compaction: {
    auto: true;
    prune: true;
    tail_turns: number;
    preserve_recent_tokens: number;
  };
  tool_output: {
    max_lines: number;
    max_bytes: number;
  };
};

const kimiHosts = new Set([
  'api.kimi.com',
  'api.moonshot.ai',
  'api.moonshot.cn',
  'api.moonshotai.cn'
]);

const defaultBaseURL = 'https://api.moonshot.cn/v1';
export const kimiCodeAgentApplicationSupportName = 'Kimi Code Agent';

export function resolveOpenCodeFoundationPaths(projectDirectory: string) {
  const foundationDirectory = path.join(projectDirectory, 'vendor', 'opencode');
  return {
    foundationDirectory,
    nativePluginFile: path.join(foundationDirectory, 'packages', 'kimi-code-agent-plugin', 'src', 'index.ts')
  };
}

export function resolveOpenCodeFusionPaths(applicationSupportDirectory: string) {
  const configDirectory = path.join(applicationSupportDirectory, 'opencode');
  return {
    configDirectory,
    configFile: path.join(configDirectory, 'opencode.json'),
    stateDirectory: path.join(configDirectory, 'state')
  };
}

export function validateKimiEndpoint(value: string = defaultBaseURL): string {
  let endpoint: URL;
  try {
    endpoint = new URL(value.trim());
  } catch {
    throw new Error('Kimi API 地址必须是有效的 HTTPS URL。');
  }

  if (endpoint.protocol !== 'https:') {
    throw new Error('Kimi API 地址必须使用 HTTPS。');
  }
  if (!kimiHosts.has(endpoint.hostname.toLowerCase())) {
    throw new Error('Kimi API 地址必须指向官方 Kimi / Moonshot 域名。');
  }
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash) {
    throw new Error('Kimi API 地址不能包含凭据、查询参数或片段。');
  }
  return endpoint.toString().replace(/\/$/, '');
}

export function createKimiOpenCodeConfig(input: KimiOpenCodeProfileInput): KimiOpenCodeConfig {
  const modelID = input.modelID.trim();
  if (!modelID) throw new Error('Kimi 模型 ID 不能为空。');

  const baseURL = validateKimiEndpoint(input.baseURL);
  return {
    $schema: 'https://opencode.ai/config.json',
    model: `moonshotai-cn/${modelID}`,
    small_model: `moonshotai-cn/${modelID}`,
    plugin: ['{env:KIMI_OPENCODE_PLUGIN}'],
    provider: {
      'moonshotai-cn': {
        name: 'Kimi / Moonshot AI',
        api: baseURL,
        npm: '@ai-sdk/openai-compatible',
        env: ['KIMI_API_KEY'],
        options: {
          apiKey: '{env:KIMI_API_KEY}',
          baseURL,
          timeout: 120000,
          headerTimeout: 15000,
          chunkTimeout: 30000,
          setCacheKey: true
        },
        models: {
          [modelID]: {
            name: modelID,
            reasoning: true,
            tool_call: true,
            interleaved: 'reasoning_content',
            limit: { context: 262144, output: 16384 },
            modalities: { input: ['text', 'image'], output: ['text'] }
          }
        }
      }
    },
    permission: {
      read: 'allow',
      glob: 'allow',
      grep: 'allow',
      list: 'allow',
      websearch: 'allow',
      webfetch: 'allow',
      task: 'allow',
      bash: 'ask',
      edit: 'ask',
      external_directory: 'ask',
      question: 'ask',
      skill: 'ask'
    },
    compaction: {
      auto: true,
      prune: true,
      tail_turns: 8,
      preserve_recent_tokens: 24000
    },
    tool_output: {
      max_lines: 2000,
      max_bytes: 51200
    }
  };
}

export function createOpenCodeLaunchEnvironment(
  environment: NodeJS.ProcessEnv,
  applicationSupportDirectory = path.join(environment.HOME ?? homedir(), 'Library', 'Application Support', kimiCodeAgentApplicationSupportName)
): NodeJS.ProcessEnv {
  const paths = resolveOpenCodeFusionPaths(applicationSupportDirectory);
  return {
    ...environment,
    OPENCODE_CLIENT: 'kimi-code-agent',
    OPENCODE_CONFIG_DIR: paths.configDirectory,
    XDG_STATE_HOME: environment.XDG_STATE_HOME ?? paths.stateDirectory
  };
}
