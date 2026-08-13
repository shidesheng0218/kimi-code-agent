import { describe, expect, it, vi } from 'vitest';
import {
  GitHubClient,
  GitLabClient,
  MCPHttpClient,
  NetworkGateway,
  WebResearchClient,
  buildNetworkTools
} from './networkGateway.js';

describe('NetworkGateway', () => {
  it('blocks requests to domains outside the allowlist', async () => {
    const gateway = new NetworkGateway({
      allowedDomains: ['localhost'],
      fetchImplementation: vi.fn()
    });

    await expect(gateway.request({ url: 'https://example.com/api' })).rejects.toThrow('example.com');
  });

  it('retries transient failures before returning a result', async () => {
    const fetchImplementation = vi
      .fn()
      .mockRejectedValueOnce(new Error('temporary outage'))
      .mockResolvedValueOnce(new Response('ok', { status: 200, headers: { 'content-type': 'text/plain' } }));

    const gateway = new NetworkGateway({
      allowedDomains: ['localhost'],
      fetchImplementation
    });

    const result = await gateway.request({
      url: 'https://localhost/health',
      retryAttempts: 2
    });

    expect(result.status).toBe(200);
    expect(result.bodyText).toBe('ok');
    expect(result.attempts).toBe(2);
    expect(fetchImplementation).toHaveBeenCalledTimes(2);
  });

  it('exposes tools for fetch, MCP HTTP, GitHub, and GitLab workflows', () => {
    const tools = buildNetworkTools({
      allowedDomains: ['localhost'],
      githubToken: 'github-token',
      gitlabToken: 'gitlab-token',
      fetchImplementation: vi.fn()
    });

    expect(tools.map(tool => tool.name)).toEqual(
      expect.arrayContaining([
        'network.fetch',
        'web.search',
        'web.fetch',
        'mcp.http.initialize',
        'mcp.http.tools_list',
        'mcp.http.tools_call',
        'github.pull_request.create',
        'github.pull_request.comment',
        'github.checks.summary',
        'gitlab.merge_request.create',
        'gitlab.merge_request.comment',
        'gitlab.pipeline.summary'
      ])
    );
  });
});

const publicResolver = async () => ['93.184.216.34'] as const;

describe('WebResearchClient', () => {
  it('times out a hanging fetch instead of leaving Web Fetch pending forever', async () => {
    const fetchImplementation = vi.fn((_input: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new Error('request aborted')));
    }));
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      allowedDomains: ['docs.example.com'],
      timeoutMs: 20,
      retryAttempts: 1,
      resolveHost: publicResolver,
      fetchImplementation
    });

    await expect(client.fetch({ url: 'https://docs.example.com/slow' })).rejects.toThrow('request aborted');
    expect(fetchImplementation).toHaveBeenCalledTimes(1);
  });

  it('searches Brave with a compact, source-identifiable response and caches repeated queries', async () => {
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toContain('https://api.search.brave.com/res/v1/web/search?');
      expect(String(input)).toContain('q=Kimi+ACP');
      expect((init?.headers as Record<string, string>)['X-Subscription-Token']).toBe('brave-test-key');
      return new Response(JSON.stringify({
        type: 'search',
        web: {
          results: [
            {
              title: 'Kimi ACP migration',
              url: 'https://docs.example.com/kimi/acp',
              description: 'Official ACP migration documentation.',
              age: '2 days ago'
            }
          ]
        }
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    });
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      allowedDomains: ['docs.example.com'],
      fetchImplementation
    });

    const first = await client.search({ query: 'Kimi ACP', maxResults: 5, language: 'en', freshness: 'week' });
    const second = await client.search({ query: 'Kimi ACP', maxResults: 5, language: 'en', freshness: 'week' });

    expect(first.cached).toBe(false);
    expect(second.cached).toBe(true);
    expect(first.results).toEqual([
      expect.objectContaining({
        id: 'src_1',
        title: 'Kimi ACP migration',
        url: 'https://docs.example.com/kimi/acp',
        domain: 'docs.example.com',
        snippet: 'Official ACP migration documentation.'
      })
    ]);
    expect(fetchImplementation).toHaveBeenCalledTimes(1);
  });

  it('searches the public fallback provider through Bing HTML without a user supplied API key', async () => {
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL) => {
      expect(String(input)).toContain('https://www.bing.com/search?');
      return new Response(`<!doctype html>
        <ol>
          <li class="b_algo">
            <h2><a href="https://platform.kimi.ai/docs/guide/use-web-search">Use Kimi API web search</a></h2>
            <p>Official web search documentation.</p>
          </li>
        </ol>`, { status: 200, headers: { 'content-type': 'text/html' } });
    });
    const client = new WebResearchClient({ provider: 'public', fetchImplementation });

    const result = await client.search({ query: 'Kimi API web search official', maxResults: 3 });

    expect(result.provider).toBe('public');
    expect(result.results).toEqual([expect.objectContaining({
      title: 'Use Kimi API web search',
      url: 'https://platform.kimi.ai/docs/guide/use-web-search',
      domain: 'platform.kimi.ai',
      snippet: 'Official web search documentation.'
    })]);
  });

  it('fetches a source returned by search without broadening the permanent domain allowlist', async () => {
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url.startsWith('https://api.search.brave.com/')) {
        return new Response(JSON.stringify({
          web: {
            results: [{
              title: 'Release notes',
              url: 'https://release.example.org/notes',
              description: 'Current release notes.'
            }]
          }
        }), { status: 200, headers: { 'content-type': 'application/json' } });
      }
      if (url === 'https://release.example.org/notes') {
        return new Response('<html><head><title>Release notes</title></head><body><nav>navigation</nav><main><h1>Version 1.0</h1><p>Important release details.</p><script>ignored()</script></main></body></html>', {
          status: 200,
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }
      throw new Error(`Unexpected URL: ${url}`);
    });
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      resolveHost: publicResolver,
      fetchImplementation
    });

    const search = await client.search({ query: 'release notes' });
    const fetched = await client.fetch({ url: search.results[0]!.url, sourceID: search.results[0]!.id, maxChars: 2_000 });

    expect(fetched.source.id).toBe('src_1');
    expect(fetched.content).toContain('Version 1.0');
    expect(fetched.content).toContain('Important release details.');
    expect(fetched.content).not.toContain('navigation');
    expect(fetched.content).not.toContain('ignored()');
  });

  it('requires a configured provider and rejects direct fetches outside the allowlist', async () => {
    const missingProvider = new WebResearchClient({ fetchImplementation: vi.fn() });
    await expect(missingProvider.search({ query: 'Kimi ACP' })).rejects.toThrow('Web Search 尚未配置');

    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      resolveHost: publicResolver,
      fetchImplementation: vi.fn()
    });
    await expect(client.fetch({ url: 'https://untrusted.example.net/docs' })).rejects.toThrow('untrusted.example.net');
  });

  it('rejects IPv6-mapped loopback and private targets even when allowlisted', async () => {
    const fetchImplementation = vi.fn();
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      resolveHost: publicResolver,
      allowedDomains: ['127.0.0.1'],
      fetchImplementation
    });

    await expect(client.fetch({ url: 'http://[::ffff:127.0.0.1]/admin' })).rejects.toThrow('本机或私有网络');
    await expect(client.fetch({ url: 'http://[::ffff:7f00:1]/admin' })).rejects.toThrow('本机或私有网络');
    await expect(client.fetch({ url: 'http://[fe80::1]/' })).rejects.toThrow('本机或私有网络');
    await expect(client.fetch({ url: 'http://[fc00::1]/' })).rejects.toThrow('本机或私有网络');
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it('rejects hosts whose DNS resolves to loopback or private addresses', async () => {
    const fetchImplementation = vi.fn();
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      resolveHost: async () => ['127.0.0.1'],
      allowedDomains: ['metadata.local'],
      fetchImplementation
    });

    await expect(client.fetch({ url: 'http://metadata.local/latest' })).rejects.toThrow('解析到本机');
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it('rejects hosts that resolve to IPv4-mapped private addresses', async () => {
    const fetchImplementation = vi.fn();
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      resolveHost: async () => ['::ffff:127.0.0.1'],
      allowedDomains: ['metadata.local'],
      fetchImplementation
    });

    await expect(client.fetch({ url: 'http://metadata.local/latest' })).rejects.toThrow('解析到本机');
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it('rejects targets that cannot be resolved', async () => {
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      resolveHost: async () => [],
      allowedDomains: ['unresolvable.example'],
      fetchImplementation: vi.fn()
    });

    await expect(client.fetch({ url: 'https://unresolvable.example/docs' })).rejects.toThrow('解析到本机');
  });

  it('truncates oversized responses without buffering the whole body', async () => {
    const big = new Uint8Array(200_000).fill(65);
    const fetchImplementation = vi.fn(async () => new Response(big, { status: 200, headers: { 'content-type': 'text/plain' } }));
    const gateway = new NetworkGateway({
      allowedDomains: ['localhost'],
      defaultMaxResponseBytes: 64_000,
      defaultRetryAttempts: 1,
      fetchImplementation
    });

    const result = await gateway.request({ url: 'https://localhost/big', maxResponseBytes: 64_000 });

    expect(result.truncated).toBe(true);
    expect(result.bytesRead).toBe(64_000);
    expect(result.bodyText.length).toBe(64_000);
  });

  it('uses the configured default result limit when the model does not specify one', async () => {
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL) => {
      expect(String(input)).toContain('count=3');
      return new Response(JSON.stringify({ web: { results: [] } }), {
        status: 200,
        headers: { 'content-type': 'application/json' }
      });
    });
    const client = new WebResearchClient({
      provider: 'brave',
      providerAPIKey: 'brave-test-key',
      defaultResultLimit: 3,
      fetchImplementation
    });

    await client.search({ query: 'Kimi' });

    expect(fetchImplementation).toHaveBeenCalledTimes(1);
  });
});

describe('GitHubClient', () => {
  it('creates a pull request with an authenticated GitHub request', async () => {
    const fetchImplementation = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(JSON.stringify({ number: 7, html_url: 'https://github.com/moonshotai/kimi/pull/7' }), {
        status: 201,
        headers: { 'content-type': 'application/json' }
      });
    });

    const client = new GitHubClient({
      token: 'ghp_test-token',
      allowedDomains: ['api.github.com'],
      fetchImplementation
    });

    const result = await client.createPullRequest({
      owner: 'moonshotai',
      repo: 'kimi-agent-desktop',
      title: 'Ship the network gateway',
      head: 'codex/network-gateway',
      base: 'main',
      body: 'Adds the unified network gateway.'
    });

    expect(result.number).toBe(7);
    const [url, init] = (fetchImplementation.mock.calls[0] ?? []) as [RequestInfo | URL, RequestInit | undefined];
    expect((url as URL).href).toBe('https://api.github.com/repos/moonshotai/kimi-agent-desktop/pulls');
    expect((init as RequestInit | undefined)?.method).toBe('POST');
    expect((init as RequestInit | undefined)?.headers).toEqual(
      expect.objectContaining({
        Authorization: 'Bearer ghp_test-token'
      })
    );
  });
});

describe('GitLabClient', () => {
  it('creates a merge request with an authenticated GitLab request', async () => {
    const fetchImplementation = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(JSON.stringify({ iid: 11, web_url: 'https://gitlab.com/moonshot/kimi-agent/-/merge_requests/11' }), {
        status: 201,
        headers: { 'content-type': 'application/json' }
      });
    });

    const client = new GitLabClient({
      token: 'glpat_test-token',
      allowedDomains: ['gitlab.com'],
      fetchImplementation
    });

    const result = await client.createMergeRequest({
      projectPath: 'moonshot/kimi-agent',
      title: 'Ship the network gateway',
      sourceBranch: 'codex/network-gateway',
      targetBranch: 'main',
      description: 'Adds the unified network gateway.'
    });

    expect(result.iid).toBe(11);
    const [url, init] = (fetchImplementation.mock.calls[0] ?? []) as [RequestInfo | URL, RequestInit | undefined];
    expect((url as URL).href).toBe('https://gitlab.com/api/v4/projects/moonshot%2Fkimi-agent/merge_requests');
    expect((init as RequestInit | undefined)?.method).toBe('POST');
    expect((init as RequestInit | undefined)?.headers).toEqual(
      expect.objectContaining({
        'Private-Token': 'glpat_test-token'
      })
    );
  });
});

describe('MCPHttpClient', () => {
  it('speaks JSON-RPC over HTTP and reuses the same endpoint for tool calls', async () => {
    const requests: Array<{ url: string; init?: RequestInit }> = [];
    const fetchImplementation = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      requests.push({ url: String(input), init });
      const body = JSON.parse(String(init?.body ?? '{}')) as { method?: string; id?: number };
      if (body.method === 'initialize') {
        return new Response(
          JSON.stringify({
            jsonrpc: '2.0',
            id: body.id,
            result: {
              protocolVersion: '2024-11-05',
              serverInfo: { name: 'http-mcp', version: '1.0.0' },
              capabilities: { tools: {} }
            }
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        );
      }
      if (body.method === 'tools/list') {
        return new Response(
          JSON.stringify({
            jsonrpc: '2.0',
            id: body.id,
            result: {
              tools: [{ name: 'echo', description: 'echo text', inputSchema: { type: 'object' } }]
            }
          }),
          { status: 200, headers: { 'content-type': 'application/json' } }
        );
      }
      return new Response(
        JSON.stringify({
          jsonrpc: '2.0',
          id: body.id,
          result: {
            content: [{ type: 'text', text: 'echo:HTTP' }]
          }
        }),
        { status: 200, headers: { 'content-type': 'application/json' } }
      );
    });

    const client = new MCPHttpClient({
      endpoint: 'https://mcp.example/jsonrpc',
      allowedDomains: ['mcp.example'],
      fetchImplementation
    });

    const initializeResult = await client.initialize();
    const tools = await client.listTools();
    const call = await client.callTool('echo', { text: 'HTTP' });

    expect(initializeResult.serverInfo.name).toBe('http-mcp');
    expect(tools[0]?.name).toBe('echo');
    expect(call.standardOutput).toContain('echo:HTTP');
    expect(requests.map(request => request.url)).toEqual([
      'https://mcp.example/jsonrpc',
      'https://mcp.example/jsonrpc',
      'https://mcp.example/jsonrpc',
      'https://mcp.example/jsonrpc'
    ]);
  });
});
