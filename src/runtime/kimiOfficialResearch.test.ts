import { describe, expect, it, vi } from 'vitest';
import { KimiOfficialResearchClient } from './kimiOfficialResearch.js';

const publicResolver = async () => ['8.8.8.8'] as const;

describe('KimiOfficialResearchClient', () => {
  it('falls back to the authorized public URL when official fetch returns only a URL wrapper', async () => {
    const fetchImplementation = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ url: 'https://platform.kimi.com/docs/tools' }))
      .mockResolvedValueOnce(new Response('<html><head><title>Kimi Tools</title></head><body><main><p>Official tools content.</p></main></body></html>', {
        status: 200,
        headers: { 'content-type': 'text/html; charset=utf-8' }
      }));
    const client = new KimiOfficialResearchClient({
      apiKey: 'kimi-test-key',
      resolveHost: publicResolver,
      fetchImplementation,
      maxFetchChars: 800
    });

    const result = await client.fetch({ url: 'https://platform.kimi.com/docs/tools' });

    expect(result.source.title).toBe('Kimi Tools');
    expect(result.content).toContain('Official tools content.');
    expect(fetchImplementation).toHaveBeenCalledTimes(2);
  });

  it('keeps the legacy direct /search contract only when explicitly requested', async () => {
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toBe('https://api.moonshot.cn/v1/search');
      expect(init?.method).toBe('POST');
      expect(init?.body).toBe(JSON.stringify({ text_query: 'Kimi 官方工具' }));
      return jsonResponse({ search_results: [{
        title: 'Kimi 官方工具',
        url: 'https://platform.kimi.com/docs/tools',
        snippet: '官方工具说明。',
        date: '2026-08-08',
        site_name: 'platform.kimi.com'
      }] });
    });
    const client = new KimiOfficialResearchClient({
      apiKey: 'kimi-test-key',
      baseURL: 'https://api.moonshot.cn/v1',
      protocol: 'official',
      fetchImplementation
    });

    const result = await client.search({ query: 'Kimi 官方工具' });

    expect(result.provider).toBe('kimi_official');
    expect(result.results[0]).toMatchObject({
      title: 'Kimi 官方工具',
      url: 'https://platform.kimi.com/docs/tools',
      domain: 'platform.kimi.com'
    });
    expect(fetchImplementation).toHaveBeenCalledTimes(1);
  });

  it('uses the official /fetch contract and limits retained body text', async () => {
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toBe('https://api.moonshot.cn/v1/fetch');
      expect(init?.body).toBe(JSON.stringify({ url: 'https://platform.kimi.com/docs/tools' }));
      return new Response('正文'.repeat(5000), { status: 200, headers: { 'content-type': 'text/markdown' } });
    });
    const client = new KimiOfficialResearchClient({ apiKey: 'kimi-test-key', resolveHost: publicResolver, fetchImplementation, maxFetchChars: 800 });

    const result = await client.fetch({ url: 'https://platform.kimi.com/docs/tools' });

    expect(result.source.url).toBe('https://platform.kimi.com/docs/tools');
    expect(result.content.length).toBe(800);
    expect(result.truncated).toBe(true);
    expect(fetchImplementation).toHaveBeenCalledTimes(1);
  });

  it('rejects URLs whose DNS resolves to private addresses before any network call', async () => {
    const fetchImplementation = vi.fn();
    const client = new KimiOfficialResearchClient({
      apiKey: 'kimi-test-key',
      resolveHost: async () => ['10.0.0.1'],
      fetchImplementation
    });

    await expect(client.fetch({ url: 'https://internal.example/admin' })).rejects.toThrow('解析到本机');
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it('rejects a source ID that does not belong to the requested URL', async () => {
    const client = new KimiOfficialResearchClient({
      apiKey: 'kimi-test-key',
      resolveHost: publicResolver,
      fetchImplementation: vi.fn(async () => jsonResponse({ search_results: [] }))
    });

    await expect(client.fetch({
      url: 'https://platform.kimi.com/docs/tools',
      sourceID: 'source-from-another-url'
    })).rejects.toThrow('sourceID');
  });

  it('uses the Formula tool lifecycle by default and returns source records suitable for the ACP WebSearch bridge', async () => {
    const fetchImplementation = vi.fn()
      .mockResolvedValueOnce(jsonResponse({
        tools: [{ type: 'function', function: { name: 'web_search', description: 'search', parameters: { type: 'object' } } }]
      }))
      .mockResolvedValueOnce(jsonResponse({
        choices: [{ message: {
          role: 'assistant',
          reasoning_content: '先调用官方联网工具，再根据加密回执整理来源。',
          tool_calls: [{ id: 'call-1', type: 'function', function: { name: 'web_search', arguments: '{"query":"Kimi 官方工具"}' } }]
        } }],
        usage: { prompt_tokens: 30, completion_tokens: 12, total_tokens: 42 }
      }))
      .mockResolvedValueOnce(jsonResponse({
        status: 'succeeded',
        context: { encrypted_output: '----MOONSHOT ENCRYPTED BEGIN----value----MOONSHOT ENCRYPTED END----' }
      }))
      .mockResolvedValueOnce(jsonResponse({
        choices: [{ message: { content: JSON.stringify({
          sources: [{ title: '官方工具列表', url: 'https://platform.kimi.com/docs/guide/use-official-tools', snippet: '官方工具文档。', date: '2026-08-04' }]
        }) } }],
        usage: { prompt_tokens: 48, completion_tokens: 26, total_tokens: 74 }
      }));
    const client = new KimiOfficialResearchClient({
      apiKey: 'kimi-test-key',
      model: 'kimi-k3',
      fetchImplementation
    });

    const result = await client.search({ query: 'Kimi 官方工具' });

    expect(result.provider).toBe('kimi_official');
    expect(result.results).toEqual([{
      id: expect.any(String),
      title: '官方工具列表',
      url: 'https://platform.kimi.com/docs/guide/use-official-tools',
      snippet: '官方工具文档。',
      domain: 'platform.kimi.com',
      publishedAt: '2026-08-04'
    }]);
    expect(result.usage).toEqual({ inputTokens: 78, outputTokens: 38, totalTokens: 116, toolCalls: 1 });
    expect(fetchImplementation).toHaveBeenNthCalledWith(1, 'https://api.moonshot.cn/v1/formulas/moonshot/web-search:latest/tools', expect.objectContaining({
      headers: expect.objectContaining({ authorization: 'Bearer kimi-test-key' })
    }));
    expect(fetchImplementation).toHaveBeenNthCalledWith(3, 'https://api.moonshot.cn/v1/formulas/moonshot/web-search:latest/fibers', expect.objectContaining({
      method: 'POST',
      body: JSON.stringify({ name: 'web_search', arguments: '{"query":"Kimi 官方工具"}' })
    }));
    const finalRequest = fetchImplementation.mock.calls[3]?.[1] as RequestInit;
    const finalBody = JSON.parse(String(finalRequest.body)) as { messages: Array<Record<string, unknown>> };
    expect(finalBody.messages).toContainEqual(expect.objectContaining({
      role: 'assistant',
      reasoning_content: '先调用官方联网工具，再根据加密回执整理来源。'
    }));
  });

  it('caches an identical normalized query locally instead of consuming another Formula run', async () => {
    const fetchImplementation = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ tools: [{ type: 'function', function: { name: 'web_search', parameters: { type: 'object' } } }] }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: { tool_calls: [{ id: 'call-1', function: { name: 'web_search', arguments: '{"query":"Kimi"}' } }] } }] }))
      .mockResolvedValueOnce(jsonResponse({ status: 'succeeded', context: { encrypted_output: 'encrypted' } }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: { content: '{"sources":[{"title":"Kimi","url":"https://kimi.com","snippet":"Kimi"}]}' } }] }));
    const client = new KimiOfficialResearchClient({ apiKey: 'kimi-test-key', protocol: 'formula', fetchImplementation });

    await client.search({ query: ' Kimi ' });
    const cached = await client.search({ query: 'Kimi' });

    expect(cached.cached).toBe(true);
    expect(fetchImplementation).toHaveBeenCalledTimes(4);
  });

  it('continues Formula search until the model returns final sources instead of treating an intermediate tool round as empty success', async () => {
    const fetchImplementation = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ tools: [{ type: 'function', function: { name: 'web_search', parameters: { type: 'object' } } }] }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: {
        role: 'assistant',
        reasoning_content: '先检索官方文档。',
        tool_calls: [{ id: 'call-1', function: { name: 'web_search', arguments: '{"query":"Kimi API"}' } }]
      } }] }))
      .mockResolvedValueOnce(jsonResponse({ status: 'succeeded', context: { encrypted_output: 'first-search-receipt' } }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: {
        role: 'assistant',
        reasoning_content: '还需要补充官方来源。',
        tool_calls: [{ id: 'call-2', function: { name: 'web_search', arguments: '{"query":"site:platform.kimi.ai web search"}' } }]
      } }] }))
      .mockResolvedValueOnce(jsonResponse({ status: 'succeeded', context: { encrypted_output: 'second-search-receipt' } }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: {
        role: 'assistant',
        content: JSON.stringify({ sources: [{ title: 'Kimi Web Search', url: 'https://platform.kimi.ai/docs/guide/use-web-search', snippet: 'Official guide.' }] })
      } }] }));
    const client = new KimiOfficialResearchClient({ apiKey: 'kimi-test-key', fetchImplementation });

    const result = await client.search({ query: 'Kimi API' });

    expect(result.results).toEqual([expect.objectContaining({ url: 'https://platform.kimi.ai/docs/guide/use-web-search' })]);
    expect(result.usage.toolCalls).toBe(2);
    expect(fetchImplementation).toHaveBeenCalledTimes(6);
    const finalRequest = fetchImplementation.mock.calls[5]?.[1] as RequestInit;
    const finalBody = JSON.parse(String(finalRequest.body)) as { messages: Array<Record<string, unknown>> };
    expect(finalBody.messages).toContainEqual(expect.objectContaining({ role: 'tool', tool_call_id: 'call-2', content: 'second-search-receipt' }));
  });

  it('retries one bounded Formula research attempt when a completed search incorrectly returns an empty source list', async () => {
    const fetchImplementation = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ tools: [{ type: 'function', function: { name: 'web_search', parameters: { type: 'object' } } }] }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: {
        role: 'assistant',
        tool_calls: [{ id: 'empty-call', function: { name: 'web_search', arguments: '{"query":"Kimi API"}' } }]
      } }] }))
      .mockResolvedValueOnce(jsonResponse({ status: 'succeeded', context: { encrypted_output: 'empty-search-receipt' } }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: { role: 'assistant', content: '{"sources":[]}' } }] }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: {
        role: 'assistant',
        tool_calls: [{ id: 'retry-call', function: { name: 'web_search', arguments: '{"query":"Kimi API official web search"}' } }]
      } }] }))
      .mockResolvedValueOnce(jsonResponse({ status: 'succeeded', context: { encrypted_output: 'retry-search-receipt' } }))
      .mockResolvedValueOnce(jsonResponse({ choices: [{ message: { role: 'assistant', content: JSON.stringify({
        sources: [{ title: 'Kimi official search', url: 'https://platform.kimi.ai/docs/guide/use-web-search', snippet: 'Official web search guide.' }]
      }) } }] }));
    const client = new KimiOfficialResearchClient({ apiKey: 'kimi-test-key', fetchImplementation });

    const result = await client.search({ query: 'Kimi API' });

    expect(result.results).toEqual([expect.objectContaining({ url: 'https://platform.kimi.ai/docs/guide/use-web-search' })]);
    expect(result.usage.toolCalls).toBe(2);
    expect(fetchImplementation).toHaveBeenCalledTimes(7);
  });

  it('surfaces the nested official API error message instead of coercing it to [object Object]', async () => {
    const client = new KimiOfficialResearchClient({
      apiKey: 'kimi-test-key',
      fetchImplementation: vi.fn(async () => new Response(JSON.stringify({
        error: { message: '当前账号没有 web-search Formula 权限', type: 'invalid_request_error' }
      }), { status: 403, headers: { 'content-type': 'application/json' } }))
    });

    await expect(client.search({ query: 'Kimi 官方工具' }))
      .rejects.toThrow('当前账号没有 web-search Formula 权限');
  });
});

function jsonResponse(body: unknown): Response {
  return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } });
}
