import { once } from 'node:events';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WebResearchClient } from './networkGateway.js';
import { createWebResearchBridgeServer, readyPayload } from './webResearchBridge.js';

const activeServers: Array<ReturnType<typeof createWebResearchBridgeServer>> = [];

afterEach(async () => {
  await Promise.all(activeServers.splice(0).map(server => new Promise<void>(resolve => server.close(() => resolve()))));
});

describe('WebResearchBridge', () => {
  it('publishes the actual ephemeral port in its ready payload', () => {
    expect(readyPayload(43_210)).toEqual({ type: 'ready', url: 'http://127.0.0.1:43210/search', healthURL: 'http://127.0.0.1:43210/health' });
  });

  it('rejects browser-originated requests to prevent CSRF abuse of local credentials', async () => {
    const search = vi.fn(async () => ({ query: '', provider: 'public', results: [], cached: false, elapsedMs: 1 }));
    const server = createWebResearchBridgeServer({ search } as never);
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${port}/search`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: 'https://evil.example' },
      body: JSON.stringify({ text_query: 'victim query' })
    });

    expect(response.status).toBe(403);
    expect(search).not.toHaveBeenCalled();
  });

  it('translates Kimi Code WebSearch requests into the configured provider response shape', async () => {
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      fetchImplementation: vi.fn(async () => new Response(JSON.stringify({
        web: {
          results: [{
            title: 'Kimi desktop guide',
            url: 'https://docs.example.com/desktop',
            description: 'Desktop integration guide.',
            age: '2026-08-07'
          }]
        }
      }), { status: 200, headers: { 'content-type': 'application/json' } }))
    });
    const server = createWebResearchBridgeServer(client);
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${port}/search`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text_query: 'Kimi desktop' })
    });
    const body = await response.json() as { search_results: Array<Record<string, string>> };

    expect(response.status).toBe(200);
    expect(body.search_results).toEqual([
      {
        title: 'Kimi desktop guide',
        url: 'https://docs.example.com/desktop',
        snippet: 'Desktop integration guide.',
        date: '2026-08-07',
        site_name: 'docs.example.com'
      }
    ]);

    const usageResponse = await fetch(`http://127.0.0.1:${port}/usage`);
    const usage = await usageResponse.json() as { searches: number; cachedSearches: number; provider: string };
    expect(usage).toMatchObject({ searches: 1, cachedSearches: 0, provider: 'brave', inputTokens: 0, outputTokens: 0, toolCalls: 0 });
  });

  it('translates an official fetch request into a structured source response', async () => {
    const server = createWebResearchBridgeServer({
      search: async () => ({ query: '', provider: 'kimi_official', results: [], cached: false, elapsedMs: 1 }),
      fetch: async () => ({
        source: { id: 'source-1', url: 'https://docs.example.com/kimi', title: 'Kimi docs', domain: 'docs.example.com', contentType: 'text/markdown' },
        content: '# Kimi',
        cached: false,
        truncated: false,
        elapsedMs: 2
      })
    });
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${port}/fetch`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ url: 'https://docs.example.com/kimi', source_id: 'source-1' })
    });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({
      source: { id: 'source-1', url: 'https://docs.example.com/kimi' },
      content: '# Kimi'
    });
  });

  it('reports the configured SearxNG provider before the first request', async () => {
    const client = new WebResearchClient({
      provider: 'searxng',
      providerEndpoint: 'http://localhost:8080/search',
      fetchImplementation: vi.fn()
    });
    const server = createWebResearchBridgeServer(client);
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${port}/usage`);
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toMatchObject({ provider: 'searxng' });
  });

  it('falls back to public web search when the primary Kimi official client fails', async () => {
    const server = createWebResearchBridgeServer({
      providerName: 'kimi_official',
      search: async request => {
        if (request.query === 'Kimi desktop') throw new Error('Kimi 官方联网已执行搜索，但没有返回可验证来源。');
        return { query: request.query, provider: 'public', results: [], cached: false, elapsedMs: 0 };
      }
    }, {
      search: async request => ({
        query: request.query,
        provider: 'public',
        results: [{ id: 'src_1', title: 'Kimi docs', url: 'https://platform.kimi.ai/docs', snippet: 'Official docs.', domain: 'platform.kimi.ai' }],
        cached: false,
        elapsedMs: 3
      })
    });
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${port}/search`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text_query: 'Kimi desktop' })
    });
    const body = await response.json() as { search_results: Array<Record<string, string>>; fallback_error?: string };

    expect(response.status).toBe(200);
    expect(body.search_results).toHaveLength(1);
    expect(body.fallback_error).toContain('Kimi 官方联网');
    const usageResponse = await fetch(`http://127.0.0.1:${port}/usage`);
    await expect(usageResponse.json()).resolves.toMatchObject({ provider: 'public', fallbackSearches: 1 });
  });

  it('uses fallback search before a slow primary client can block the user-visible request', async () => {
    const server = createWebResearchBridgeServer({
      providerName: 'kimi_official',
      search: async () => new Promise(resolve => setTimeout(() => resolve({ query: '', provider: 'kimi_official', results: [], cached: false, elapsedMs: 5_000 }), 5_000))
    }, {
      search: async request => ({
        query: request.query,
        provider: 'public',
        results: [{ id: 'src_1', title: 'Fast fallback', url: 'https://platform.kimi.ai/docs', snippet: 'Fallback result.', domain: 'platform.kimi.ai' }],
        cached: false,
        elapsedMs: 3
      })
    }, { primaryTimeoutMs: 1_000 });
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const startedAt = Date.now();
    const response = await fetch(`http://127.0.0.1:${port}/search`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text_query: 'Kimi desktop' })
    });
    const body = await response.json() as { search_results: Array<Record<string, string>>; fallback_error?: string };

    expect(response.status).toBe(200);
    expect(Date.now() - startedAt).toBeLessThan(2_000);
    expect(body.search_results[0]?.title).toBe('Fast fallback');
    expect(body.fallback_error).toContain('超时');
  });

  it('returns both primary and fallback diagnostics when every search provider fails', async () => {
    const server = createWebResearchBridgeServer({
      providerName: 'kimi_official',
      search: async () => { throw new Error('Kimi 官方联网 400 invalid_request_error'); }
    }, {
      providerName: 'public',
      search: async () => { throw new Error('公开检索 502 bad gateway'); }
    });
    activeServers.push(server);
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const { port } = server.address() as AddressInfo;

    const response = await fetch(`http://127.0.0.1:${port}/search`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ text_query: 'Kimi desktop' })
    });
    const body = await response.json() as { error?: string; primary_error?: string; fallback_error?: string };

    expect(response.status).toBe(502);
    expect(body.error).toContain('Web Search 请求失败');
    expect(body.primary_error).toContain('Kimi 官方联网 400');
    expect(body.fallback_error).toContain('公开检索 502');
  });
});
