import { expect, test } from "bun:test"

import packageJSON from "./package.json" with { type: "json" }

test("runs the Kimi native plugin prebuild before every distributable package command", () => {
  expect(packageJSON.scripts.package).toStartWith("bun ./scripts/prebuild.ts &&")
  expect(packageJSON.scripts["package:mac"]).toStartWith("bun ./scripts/prebuild.ts &&")
})
