import { expect, test } from "bun:test"
import type { Configuration } from "electron-builder"

const legacyDesktopEntry = "resources/linux/opencode-desktop.desktop"

const channels = [
  { channel: "dev", appId: "com.kimicode.agent.dev", productName: "Kimi Code Agent Dev" },
  { channel: "beta", appId: "com.kimicode.agent.beta", productName: "Kimi Code Agent Beta" },
  { channel: "prod", appId: "com.kimicode.agent", productName: "Kimi Code Agent" },
] as const

for (const channel of channels) {
  test(`uses one Linux desktop identity for ${channel.channel}`, async () => {
    const previous = process.env.OPENCODE_CHANNEL
    process.env.OPENCODE_CHANNEL = channel.channel

    const module = await import(`./electron-builder.config.ts?channel=${channel.channel}`)
    const config = module.default as Configuration

    if (previous === undefined) delete process.env.OPENCODE_CHANNEL
    else process.env.OPENCODE_CHANNEL = previous

    expect(config.appId).toBe(channel.appId)
    expect(config.productName).toBe(channel.productName)
    expect(config.artifactName).toBe("Kimi-Code-Agent-${version}-${os}-${arch}.${ext}")
    expect(config.extraMetadata?.desktopName).toBe(`${channel.appId}.desktop`)
    expect(config.linux?.executableName).toBe(channel.appId)
    expect(config.linux?.desktop?.entry?.StartupWMClass).toBe(channel.appId)
    expect(config.deb?.fpm).toContainEqual(expect.stringContaining(`/usr/share/metainfo/${channel.appId}.metainfo.xml`))
    expect(config.rpm?.fpm).toContainEqual(expect.stringContaining(`/usr/share/metainfo/${channel.appId}.metainfo.xml`))
    expect(config.protocols).toEqual({ name: channel.productName, schemes: ["kimi-code-agent"] })
  })
}

test("bundles the CLI outside the dev app archive", async () => {
  const previous = process.env.OPENCODE_CHANNEL
  process.env.OPENCODE_CHANNEL = "dev"
  const module = await import("./electron-builder.config.ts?cli-resource")
  const config = module.default as Configuration
  if (previous === undefined) delete process.env.OPENCODE_CHANNEL
  else process.env.OPENCODE_CHANNEL = previous

  expect(config.files).toContain("!resources/opencode-cli*")
  expect(config.extraResources).toContainEqual({
    from: "resources/",
    to: "",
    filter: ["opencode-cli*"],
  })
})

test("does not attempt macOS notarization when Apple credentials are absent", async () => {
  const appleID = process.env.APPLE_ID
  const appleTeamID = process.env.APPLE_TEAM_ID
  const applePassword = process.env.APPLE_APP_SPECIFIC_PASSWORD
  delete process.env.APPLE_ID
  delete process.env.APPLE_TEAM_ID
  delete process.env.APPLE_APP_SPECIFIC_PASSWORD

  const module = await import("./electron-builder.config.ts?notarize=none")
  const config = module.default as Configuration

  if (appleID === undefined) delete process.env.APPLE_ID
  else process.env.APPLE_ID = appleID
  if (appleTeamID === undefined) delete process.env.APPLE_TEAM_ID
  else process.env.APPLE_TEAM_ID = appleTeamID
  if (applePassword === undefined) delete process.env.APPLE_APP_SPECIFIC_PASSWORD
  else process.env.APPLE_APP_SPECIFIC_PASSWORD = applePassword

  expect(config.mac?.notarize).toBe(false)
})

for (const channel of ["beta", "prod"] as const) {
  test(`does not bundle the CLI in ${channel} builds`, async () => {
    const previous = process.env.OPENCODE_CHANNEL
    process.env.OPENCODE_CHANNEL = channel
    const module = await import(`./electron-builder.config.ts?no-cli-resource=${channel}`)
    const config = module.default as Configuration
    if (previous === undefined) delete process.env.OPENCODE_CHANNEL
    else process.env.OPENCODE_CHANNEL = previous

    expect(config.extraResources).not.toContainEqual({
      from: "resources/",
      to: "",
      filter: ["opencode-cli*"],
    })
  })
}
