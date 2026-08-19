import { resolveChannel } from "./utils"

const arg = process.argv[2]
const channel = arg === "dev" || arg === "beta" || arg === "prod" ? arg : resolveChannel()

const appId = channel === "prod" ? "com.kimicode.agent" : `com.kimicode.agent.${channel}`
const productName = channel === "prod" ? "Kimi Code Agent" : `Kimi Code Agent ${channel.charAt(0).toUpperCase() + channel.slice(1)}`
const summary = `Local-first Kimi coding agent${channel !== "prod" ? ` (${channel})` : ""}`

const xml = `<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>${appId}</id>

  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>

  <name>${productName}</name>
  <summary>${summary}</summary>

  <developer id="com.kimicode">
    <name>Kimi Code Agent contributors</name>
  </developer>

  <description>
    <p>
      Kimi Code Agent is a local-first coding agent built on an OpenCode-derived runtime.
    </p>
  </description>

  <launchable type="desktop-id">${appId}.desktop</launchable>

  <content_rating type="oars-1.1" />

  <url type="bugtracker">https://github.com/shidesheng0218/kimi-agent-desktop-macos/issues</url>
  <url type="homepage">https://github.com/shidesheng0218/kimi-agent-desktop-macos</url>
  <url type="vcs-browser">https://github.com/shidesheng0218/kimi-agent-desktop-macos</url>

  <screenshots>
    <screenshot type="default">
      <image>https://raw.githubusercontent.com/shidesheng0218/kimi-agent-desktop-macos/dev/media/kimi-readme.svg</image>
    </screenshot>
  </screenshots>
</component>
`

await Bun.write(`resources/${appId}.metainfo.xml`, xml)
console.log(`Generated metainfo for ${channel} at resources/${appId}.metainfo.xml`)
