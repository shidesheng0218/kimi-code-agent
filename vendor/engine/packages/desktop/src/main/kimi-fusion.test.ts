import { expect, test } from "bun:test"

import { createKimiSidecarEnvironment, resolveKimiAPIKey } from "./kimi-fusion"

test("prefers an explicitly supplied Kimi key without consulting the credential reader", () => {
  let credentialReaderCalls = 0
  const key = resolveKimiAPIKey(
    { KIMI_API_KEY: " environment-key " },
    () => {
      credentialReaderCalls += 1
      return "keychain-key"
    },
  )

  expect(key).toBe("environment-key")
  expect(credentialReaderCalls).toBe(0)
})

test("uses the existing Kimi Keychain record only for the launched sidecar process", () => {
  const environment = createKimiSidecarEnvironment({
    environment: { PATH: "/usr/bin" },
    stateDirectory: "/tmp/kimi-state",
    pluginURL: "file:///Applications/Kimi%20Code%20Agent.app/kimi-native-plugin.mjs",
    bridgePath: "/Applications/Kimi Code Agent.app/KimiNativeBridge",
    readCredential: () => " keychain-key ",
  })

  expect(environment).toMatchObject({
    KIMI_API_KEY: "keychain-key",
    KIMI_OPENCODE_PLUGIN: "file:///Applications/Kimi%20Code%20Agent.app/kimi-native-plugin.mjs",
    KIMI_NATIVE_BRIDGE: "/Applications/Kimi Code Agent.app/KimiNativeBridge",
    XDG_STATE_HOME: "/tmp/kimi-state",
  })
  expect(JSON.parse(environment.OPENCODE_CONFIG_CONTENT ?? "{}")).toMatchObject({
    model: "moonshotai-cn/kimi-k2.7-code",
    plugin: ["{env:KIMI_OPENCODE_PLUGIN}"],
    permission: { websearch: "allow", webfetch: "allow", bash: "ask", edit: "ask" },
  })
  expect(environment.OPENCODE_CONFIG_CONTENT).not.toContain("keychain-key")
})

test("consults only the Kimi Code Agent Keychain service", () => {
  const services: string[] = []
  const key = resolveKimiAPIKey({}, (service) => {
    services.push(service)
    return undefined
  })

  expect(key).toBeUndefined()
  expect(services).toEqual(["com.kimicode.agent.native"])
})

test("returns no key when neither the environment nor Keychain has one", () => {
  expect(resolveKimiAPIKey({}, () => undefined)).toBeUndefined()
})
