import { expect, test } from "bun:test"
import { resolveVisibleTools } from "../../src/tool/registry"

test("keeps a custom websearch override visible for a non-OpenCode provider", () => {
  const builtinSearch = { id: "websearch", source: "builtin" }
  const customSearch = { id: "websearch", source: "kimi-native" }
  const tools = resolveVisibleTools({
    builtin: [builtinSearch, { id: "read", source: "builtin" }],
    custom: [customSearch],
    providerID: "moonshotai-cn" as never,
    modelID: "kimi-k2.7-code" as never,
    flags: { exa: false, parallel: false },
  })

  expect(tools).toEqual([{ id: "read", source: "builtin" }, customSearch])
})
