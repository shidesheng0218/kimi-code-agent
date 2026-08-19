import { execFileSync } from "node:child_process"

type CredentialReader = (service: string) => string | undefined

type KimiSidecarEnvironmentInput = {
  environment: NodeJS.ProcessEnv
  stateDirectory: string
  pluginURL?: string
  bridgePath?: string
  readCredential?: CredentialReader
}

const defaultBaseURL = "https://api.moonshot.cn/v1"
const defaultModelID = "kimi-k2.7-code"
const kimiHosts = new Set(["api.kimi.com", "api.moonshot.ai", "api.moonshot.cn", "api.moonshotai.cn"])
const keychainServices = ["com.kimicode.agent.native"]

export function resolveKimiAPIKey(environment: NodeJS.ProcessEnv, readCredential: CredentialReader = readKimiAPIKeyFromKeychain) {
  const environmentKey = environment.KIMI_API_KEY?.trim()
  if (environmentKey) return environmentKey
  for (const service of keychainServices) {
    const key = readCredential(service)?.trim()
    if (key) return key
  }
  return undefined
}

export function createKimiSidecarEnvironment(input: KimiSidecarEnvironmentInput): Record<string, string> {
  const apiKey = resolveKimiAPIKey(input.environment, input.readCredential)
  const pluginURL = input.pluginURL?.trim() || input.environment.KIMI_OPENCODE_PLUGIN?.trim()
  const bridgePath = input.bridgePath?.trim() || input.environment.KIMI_NATIVE_BRIDGE?.trim()
  const baseURL = resolveKimiBaseURL(input.environment.KIMI_BASE_URL)
  const modelID = resolveModelID(input.environment.KIMI_MODEL)
  const environment: Record<string, string> = Object.fromEntries(
    Object.entries(input.environment).flatMap(([key, value]) => (value === undefined ? [] : [[key, String(value)]])),
  )

  environment.XDG_STATE_HOME = environment.XDG_STATE_HOME || input.stateDirectory
  environment.OPENCODE_CONFIG_CONTENT = JSON.stringify(createKimiConfig(baseURL, modelID))
  if (pluginURL) environment.KIMI_OPENCODE_PLUGIN = pluginURL
  if (bridgePath) environment.KIMI_NATIVE_BRIDGE = bridgePath
  if (apiKey) environment.KIMI_API_KEY = apiKey
  return environment
}

function createKimiConfig(baseURL: string, modelID: string) {
  return {
    $schema: "https://opencode.ai/config.json",
    model: `moonshotai-cn/${modelID}`,
    small_model: `moonshotai-cn/${modelID}`,
    plugin: ["{env:KIMI_OPENCODE_PLUGIN}"],
    provider: {
      "moonshotai-cn": {
        name: "Kimi / Moonshot AI",
        api: baseURL,
        npm: "@ai-sdk/openai-compatible",
        env: ["KIMI_API_KEY"],
        options: {
          apiKey: "{env:KIMI_API_KEY}",
          baseURL,
          timeout: 120000,
          headerTimeout: 15000,
          chunkTimeout: 30000,
          setCacheKey: true,
        },
        models: {
          [modelID]: {
            name: modelID,
            reasoning: true,
            tool_call: true,
            interleaved: "reasoning_content",
            limit: { context: 262144, output: 16384 },
            modalities: { input: ["text", "image"], output: ["text"] },
          },
        },
      },
    },
    permission: {
      read: "allow",
      glob: "allow",
      grep: "allow",
      list: "allow",
      websearch: "allow",
      webfetch: "allow",
      task: "allow",
      bash: "ask",
      edit: "ask",
      external_directory: "ask",
      question: "ask",
      skill: "ask",
    },
    compaction: {
      auto: true,
      prune: true,
      tail_turns: 8,
      preserve_recent_tokens: 24000,
    },
    tool_output: {
      max_lines: 2000,
      max_bytes: 51200,
    },
  }
}

function resolveKimiBaseURL(value: string | undefined) {
  const candidate = value?.trim() || defaultBaseURL
  const url = new URL(candidate)
  if (url.protocol !== "https:" || !kimiHosts.has(url.hostname.toLowerCase()) || url.username || url.password || url.search || url.hash) {
    return defaultBaseURL
  }
  return url.toString().replace(/\/$/, "")
}

function resolveModelID(value: string | undefined) {
  const candidate = value?.trim()
  if (!candidate || candidate.length > 128 || /[\s\\/]/.test(candidate)) return defaultModelID
  return candidate
}

function readKimiAPIKeyFromKeychain(service: string) {
  try {
    const value = execFileSync(
      "/usr/bin/security",
      [
        "find-generic-password",
        "-s",
        service,
        "-a",
        "kimi.runtime.identity.apiKey",
        "-w",
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    )
    return value.trim() || undefined
  } catch {
    return undefined
  }
}
