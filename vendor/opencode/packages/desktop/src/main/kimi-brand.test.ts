import { expect, test } from "bun:test"

import { KIMI_CODE_AGENT, supportedDeepLinkSchemes } from "./kimi-brand"

test("uses only Kimi Code Agent as the Desktop identity", () => {
  expect(KIMI_CODE_AGENT).toMatchObject({
    appID: "com.kimicode.agent",
    productName: "Kimi Code Agent",
    scheme: "kimi-code-agent",
  })
  expect(supportedDeepLinkSchemes).toEqual(["kimi-code-agent"])
})
