import path from "node:path"
import { expect, test } from "bun:test"

test("falls back to the vendored catalog when models.dev does not answer before the build timeout", async () => {
  using server = Bun.serve({
    port: 0,
    fetch() {
      return new Promise<Response>(() => {})
    },
  })
  const child = Bun.spawn([process.execPath, "--eval", "await import('./script/generate.ts')"], {
    cwd: path.resolve(import.meta.dir, "../.."),
    env: {
      ...process.env,
      OPENCODE_MODELS_URL: server.url.toString(),
      OPENCODE_MODELS_TIMEOUT_MS: "50",
    },
    stdout: "pipe",
    stderr: "pipe",
  })
  const exitCode = await Promise.race([
    child.exited,
    new Promise<undefined>((resolve) => setTimeout(resolve, 1_500)),
  ])
  if (exitCode === undefined) child.kill()

  expect(exitCode).toBe(0)
  expect(await new Response(child.stdout).text()).toContain("Loaded vendored models.dev snapshot")
})
