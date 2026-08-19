import { $ } from 'bun'
import { describe, expect, test } from 'bun:test'

describe('models.dev generator', () => {
  test('falls back to the vendored snapshot when the catalog endpoint is unavailable', async () => {
    const result = await $`OPENCODE_MODELS_URL=http://127.0.0.1:9 bun --eval "await import('./script/generate.ts')"`.nothrow().quiet()

    expect(result.exitCode).toBe(0)
    expect(result.stdout.toString()).toContain('Loaded vendored models.dev snapshot')
  })
})
