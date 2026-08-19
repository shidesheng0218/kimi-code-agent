import { describe, expect, test } from 'bun:test'
import { prepareBrowserPlan } from '../src/index'

async function webRequestPreparers() {
  return await import('../src/index') as typeof import('../src/index') & {
    prepareWebSearchRequest?: (input: unknown) => { query: string; maxResults: number }
    prepareWebFetchRequest?: (input: unknown) => { url: string; sourceID?: string; maxCharacters: number }
  }
}

describe('Kimi OpenCode native plugin browser policy', () => {
  test('automatically admits a public read-only browser plan and pins its allowed domain', () => {
    expect(
      prepareBrowserPlan(JSON.stringify({
        steps: [{ kind: 'open', url: 'https://docs.example.com/guide' }, { kind: 'inspect', selector: 'h1' }],
      })),
    ).toEqual({
      plan: {
        allowedDomains: ['docs.example.com'],
        steps: [{ kind: 'open', url: 'https://docs.example.com/guide' }, { kind: 'inspect', selector: 'h1' }],
      },
      requiresApproval: false,
    })
  })

  test('requires explicit approval before a browser plan can click, type or press a key', () => {
    expect(
      prepareBrowserPlan(JSON.stringify({
        allowedDomains: ['example.com'],
        steps: [{ kind: 'open', url: 'https://example.com' }, { kind: 'click', selector: '#submit' }],
      })).requiresApproval,
    ).toBe(true)
  })

  test('rejects private browser targets instead of silently loading them', () => {
    expect(() => prepareBrowserPlan(JSON.stringify({ steps: [{ kind: 'open', url: 'https://127.0.0.1/admin' }] }))).toThrow(
      'private',
    )
  })
})

describe('Kimi OpenCode native plugin web policy', () => {
  test('replaces OpenCode default web tools with the Kimi native bridge names', async () => {
    const module = await import('../src/index')
    const hooks = await module.default.server({} as never)

    expect(Object.keys(hooks.tool ?? {}).sort()).toEqual(expect.arrayContaining(['websearch', 'webfetch']))
    expect(hooks.tool?.kimi_web_search).toBeUndefined()
    expect(hooks.tool?.kimi_web_fetch).toBeUndefined()
  })

  test('normalizes a public web search request without asking for approval', async () => {
    const plugin = await webRequestPreparers()

    expect(plugin.prepareWebSearchRequest).toBeTypeOf('function')
    expect(plugin.prepareWebSearchRequest?.({ query: '  Kimi Code Agent  ', maxResults: 99 })).toEqual({
      query: 'Kimi Code Agent',
      maxResults: 8,
    })
  })

  test('normalizes a public fetch request and refuses a credential-bearing URL before it reaches the bridge', async () => {
    const plugin = await webRequestPreparers()

    expect(plugin.prepareWebFetchRequest).toBeTypeOf('function')
    expect(plugin.prepareWebFetchRequest?.({
      url: 'https://docs.example.com/guide',
      sourceID: 'source-1',
      maxCharacters: 999999,
    })).toEqual({
      url: 'https://docs.example.com/guide',
      sourceID: 'source-1',
      maxCharacters: 100000,
    })
    expect(() => plugin.prepareWebFetchRequest?.({ url: 'https://user:password@example.com/' })).toThrow('credential')
  })
})
