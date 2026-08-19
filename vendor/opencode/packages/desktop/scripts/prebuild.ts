#!/usr/bin/env bun
import { $ } from "bun"
import { existsSync } from "node:fs"
import { join } from "node:path"

import { downloadCliToResources, resolveChannel } from "./utils"

const channel = resolveChannel()
await $`bun ./scripts/copy-icons.ts ${channel}`
await $`bun ./scripts/copy-metainfo.ts ${channel}`

await $`cd ../opencode && bun script/build-node.ts`
const kimiNativePlugin = join(import.meta.dir, "../../kimi-code-agent-plugin/src/index.ts")
if (existsSync(kimiNativePlugin)) {
  await $`bun build ${kimiNativePlugin} --outfile resources/kimi-native-plugin.mjs --target bun --format esm`
}
if (channel === "dev") await downloadCliToResources()
