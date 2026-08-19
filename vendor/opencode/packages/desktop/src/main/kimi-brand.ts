export const KIMI_CODE_AGENT = {
  appID: "com.kimicode.agent",
  productName: "Kimi Code Agent",
  scheme: "kimi-code-agent",
} as const

export const KIMI_CODE_AGENT_CHANNELS = {
  dev: { appID: "com.kimicode.agent.dev", productName: "Kimi Code Agent Dev" },
  beta: { appID: "com.kimicode.agent.beta", productName: "Kimi Code Agent Beta" },
  prod: KIMI_CODE_AGENT,
} as const

export const supportedDeepLinkSchemes = [KIMI_CODE_AGENT.scheme] as const
