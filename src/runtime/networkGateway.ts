import { lookup } from 'node:dns/promises';
import { createExternalTool } from '@moonshot-ai/kimi-agent-sdk';
import { z } from 'zod';

type FetchImplementation = typeof fetch;
export type HostResolver = (hostname: string) => Promise<readonly string[]>;

export const defaultHostResolver: HostResolver = async hostname => {
  try {
    const records = await lookup(hostname, { all: true, verbatim: true });
    return records.map(record => record.address);
  } catch {
    return [];
  }
};

export interface NetworkGatewayOptions {
  allowedDomains?: readonly string[];
  fetchImplementation?: FetchImplementation;
  defaultTimeoutMs?: number;
  defaultRetryAttempts?: number;
  defaultMaxResponseBytes?: number;
  userAgent?: string;
}

export interface NetworkRequestOptions {
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string;
  timeoutMs?: number;
  retryAttempts?: number;
  maxResponseBytes?: number;
}

export interface NetworkResponse {
  url: string;
  status: number;
  ok: boolean;
  redirected: boolean;
  headers: Record<string, string>;
  bodyText: string;
  bytesRead: number;
  truncated: boolean;
  attempts: number;
  elapsedMs: number;
}

export type WebSearchProvider = 'brave' | 'searxng' | 'kimi_official' | 'public';
export type WebSearchFreshness = 'any' | 'day' | 'week' | 'month' | 'year';

export interface WebSearchRequest {
  query: string;
  maxResults?: number;
  language?: string;
  freshness?: WebSearchFreshness;
}

export interface WebSearchResult {
  id: string;
  title: string;
  url: string;
  snippet: string;
  domain: string;
  publishedAt?: string;
}

export interface WebSearchResponse {
  query: string;
  provider: WebSearchProvider;
  results: WebSearchResult[];
  cached: boolean;
  elapsedMs: number;
}

export interface WebFetchRequest {
  url: string;
  sourceID?: string;
  maxChars?: number;
}

export interface WebFetchResponse {
  source: {
    id: string;
    url: string;
    title: string;
    domain: string;
    contentType: string;
  };
  content: string;
  cached: boolean;
  truncated: boolean;
  elapsedMs: number;
}

export interface WebResearchClientOptions {
  allowedDomains?: readonly string[];
  provider?: WebSearchProvider | string;
  providerAPIKey?: string;
  providerEndpoint?: string;
  defaultResultLimit?: number;
  fetchImplementation?: FetchImplementation;
  resolveHost?: HostResolver;
  searchCacheTTLms?: number;
  fetchCacheTTLms?: number;
  maxCacheEntries?: number;
  timeoutMs?: number;
  retryAttempts?: number;
}

export class WebResearchError extends Error {
  constructor(
    public readonly code: 'not_configured' | 'invalid_configuration' | 'invalid_source' | 'unsafe_target',
    message: string
  ) {
    super(message);
    this.name = 'WebResearchError';
  }
}

export interface MCPHttpInitializeResult {
  protocolVersion: string;
  serverInfo: {
    name: string;
    version: string;
  };
}

export interface MCPHttpTool {
  id: string;
  name: string;
  description: string;
  inputSchemaJSON: string;
}

export interface MCPHttpToolCallResult {
  standardOutput: string;
  rawJSON: string;
}

export interface GitHubClientOptions {
  token?: string;
  allowedDomains?: readonly string[];
  fetchImplementation?: FetchImplementation;
  apiBaseURL?: string;
}

export interface GitHubPullRequestInput {
  owner: string;
  repo: string;
  title: string;
  head: string;
  base: string;
  body?: string;
  draft?: boolean;
}

export interface GitHubCommentInput {
  owner: string;
  repo: string;
  pullNumber: number;
  body: string;
}

export interface GitHubChecksInput {
  owner: string;
  repo: string;
  ref: string;
}

export interface GitLabClientOptions {
  token?: string;
  allowedDomains?: readonly string[];
  fetchImplementation?: FetchImplementation;
  apiBaseURL?: string;
}

export interface GitLabMergeRequestInput {
  projectPath: string;
  title: string;
  sourceBranch: string;
  targetBranch: string;
  description?: string;
  draft?: boolean;
}

export interface GitLabCommentInput {
  projectPath: string;
  mergeRequestIid: number;
  body: string;
}

export interface GitLabPipelineSummaryInput {
  projectPath: string;
  ref: string;
}

export class NetworkGateway {
  private readonly allowedDomains: string[];
  private readonly fetchImplementation: FetchImplementation;
  private readonly defaultTimeoutMs: number;
  private readonly defaultRetryAttempts: number;
  private readonly defaultMaxResponseBytes: number;
  private readonly userAgent: string;

  constructor(options: NetworkGatewayOptions = {}) {
    this.allowedDomains = normalizeAllowedDomains(options.allowedDomains ?? readAllowedDomainsFromEnvironment());
    this.fetchImplementation = options.fetchImplementation ?? fetch;
    this.defaultTimeoutMs = options.defaultTimeoutMs ?? 15_000;
    this.defaultRetryAttempts = Math.max(1, options.defaultRetryAttempts ?? 2);
    this.defaultMaxResponseBytes = options.defaultMaxResponseBytes ?? 64_000;
    this.userAgent = options.userAgent ?? 'KimiAgentDesktop/0.3.0';
  }

  async request(input: NetworkRequestOptions): Promise<NetworkResponse> {
    const url = new URL(input.url);
    ensureDomainAllowed(url, this.allowedDomains);

    const attempts = Math.max(1, input.retryAttempts ?? this.defaultRetryAttempts);
    const timeoutMs = input.timeoutMs ?? this.defaultTimeoutMs;
    const maxResponseBytes = input.maxResponseBytes ?? this.defaultMaxResponseBytes;
    const startedAt = Date.now();
    let lastError: unknown;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(new Error(`Request timed out after ${timeoutMs}ms`)), timeoutMs);
      try {
        const response = await this.fetchImplementation(url, {
          method: input.method ?? 'GET',
          headers: {
            'user-agent': this.userAgent,
            ...(input.headers ?? {})
          },
          body: input.body,
          signal: controller.signal
        });
        const { bodyText, truncated, bytesRead } = await readBodyWithLimit(response, maxResponseBytes, controller);
        if (shouldRetryStatus(response.status) && attempt < attempts) {
          lastError = new Error(`HTTP ${response.status}`);
          continue;
        }
        return {
          url: response.url || url.toString(),
          status: response.status,
          ok: response.ok,
          redirected: response.redirected,
          headers: headersToRecord(response.headers),
          bodyText,
          bytesRead,
          truncated,
          attempts: attempt,
          elapsedMs: Date.now() - startedAt
        };
      } catch (error) {
        lastError = error;
        if (attempt >= attempts) {
          break;
        }
        await delay(120 * attempt);
      } finally {
        clearTimeout(timeout);
      }
    }

    throw lastError instanceof Error ? lastError : new Error(String(lastError ?? 'Network request failed'));
  }

  async json<T>(input: NetworkRequestOptions): Promise<{ response: NetworkResponse; body: T }> {
    const response = await this.request({
      ...input,
      headers: {
        accept: 'application/json',
        ...(input.headers ?? {})
      }
    });
    if (!response.bodyText.trim()) {
      throw new Error('Response body was empty.');
    }
    return { response, body: JSON.parse(response.bodyText) as T };
  }
}

interface CachedWebValue<T> {
  expiresAt: number;
  value: T;
}

interface TrustedWebSource {
  source: WebSearchResult;
  expiresAt: number;
}

interface BraveSearchPayload {
  web?: {
    results?: Array<{
      title?: string;
      url?: string;
      description?: string;
      age?: string;
    }>;
  };
}

interface SearxNGSearchPayload {
  results?: Array<{
    title?: string;
    url?: string;
    content?: string;
    publishedDate?: string;
    published_date?: string;
  }>;
}

export class WebResearchClient {
  private readonly allowedDomains: string[];
  private readonly fetchImplementation: FetchImplementation;
  private readonly resolveHost: HostResolver;
  private readonly provider: WebSearchProvider | undefined;
  private readonly providerAPIKey: string | undefined;
  private readonly providerEndpoint: string | undefined;
  private readonly fetchGateway: NetworkGateway;
  private readonly defaultResultLimit: number;
  private readonly searchCacheTTLms: number;
  private readonly fetchCacheTTLms: number;
  private readonly maxCacheEntries: number;
  private readonly timeoutMs: number;
  private readonly retryAttempts: number;
  private readonly searchCache = new Map<string, CachedWebValue<WebSearchResponse>>();
  private readonly fetchCache = new Map<string, CachedWebValue<WebFetchResponse>>();
  private readonly trustedSources = new Map<string, TrustedWebSource>();
  private nextSourceNumber = 0;

  public get providerName(): string {
    return this.provider ?? 'unconfigured';
  }

  constructor(options: WebResearchClientOptions = {}) {
    this.allowedDomains = normalizeAllowedDomains(options.allowedDomains ?? readAllowedDomainsFromEnvironment());
    this.fetchImplementation = options.fetchImplementation ?? fetch;
    this.resolveHost = options.resolveHost ?? defaultHostResolver;
    this.provider = normalizeSearchProvider(options.provider ?? process.env.KIMI_AGENT_WEB_SEARCH_PROVIDER ?? process.env.KIMI_WEB_SEARCH_PROVIDER);
    if (this.provider === 'kimi_official') {
      throw new WebResearchError(
        'invalid_configuration',
        'kimi_official 由 Web Research Bridge 提供，请通过 KIMI_AGENT_WEB_SEARCH_PROVIDER=kimi_official 的桥接服务使用。'
      );
    }
    this.providerAPIKey = normalizedString(options.providerAPIKey ?? process.env.KIMI_AGENT_WEB_SEARCH_API_KEY ?? process.env.KIMI_WEB_SEARCH_API_KEY);
    this.providerEndpoint = normalizedString(options.providerEndpoint ?? process.env.KIMI_AGENT_WEB_SEARCH_ENDPOINT ?? process.env.KIMI_WEB_SEARCH_ENDPOINT)
      ?? defaultSearchEndpoint(this.provider);
    this.timeoutMs = boundedInteger(options.timeoutMs, 15_000, 1, 120_000);
    this.retryAttempts = boundedInteger(options.retryAttempts, 2, 1, 5);
    this.fetchGateway = new NetworkGateway({
      allowedDomains: this.allowedDomains,
      fetchImplementation: this.fetchImplementation,
      defaultTimeoutMs: this.timeoutMs,
      defaultRetryAttempts: this.retryAttempts,
      defaultMaxResponseBytes: 512_000
    });
    this.defaultResultLimit = boundedInteger(
      options.defaultResultLimit ?? Number(process.env.KIMI_AGENT_WEB_SEARCH_DEFAULT_RESULTS ?? process.env.KIMI_WEB_SEARCH_DEFAULT_RESULTS),
      5,
      1,
      10
    );
    this.searchCacheTTLms = boundedInteger(options.searchCacheTTLms, 120_000, 10_000, 600_000);
    this.fetchCacheTTLms = boundedInteger(options.fetchCacheTTLms, 300_000, 10_000, 900_000);
    this.maxCacheEntries = boundedInteger(options.maxCacheEntries, 100, 10, 500);
  }

  async search(input: WebSearchRequest): Promise<WebSearchResponse> {
    const query = input.query.trim();
    if (!query) {
      throw new WebResearchError('invalid_configuration', 'Web Search 查询不能为空。');
    }
    if (query.length > 500) {
      throw new WebResearchError('invalid_configuration', 'Web Search 查询不能超过 500 个字符。');
    }
    const provider = this.requireProvider();
    const maxResults = boundedInteger(input.maxResults, this.defaultResultLimit, 1, 10);
    const language = normalizedString(input.language) ?? 'zh-Hans';
    const freshness = input.freshness ?? 'any';
    const cacheKey = JSON.stringify({ provider, query, maxResults, language, freshness });
    const cached = this.readCache(this.searchCache, cacheKey);
    if (cached) {
      return { ...cached, cached: true };
    }

    const startedAt = Date.now();
    const results = provider === 'brave'
      ? await this.searchBrave(query, maxResults, language, freshness)
      : provider === 'searxng'
        ? await this.searchSearxNG(query, maxResults, language, freshness)
        : await this.searchPublic(query, maxResults, language, freshness);
    const response: WebSearchResponse = {
      query,
      provider,
      results,
      cached: false,
      elapsedMs: Date.now() - startedAt
    };
    this.writeCache(this.searchCache, cacheKey, response, this.searchCacheTTLms);
    return response;
  }

  async fetch(input: WebFetchRequest): Promise<WebFetchResponse> {
    const url = parseSafeWebFetchURL(input.url);
    await assertPublicWebFetchTarget(url.hostname, this.resolveHost);
    const maxChars = boundedInteger(input.maxChars, 12_000, 1_000, 64_000);
    const trustedSource = this.resolveTrustedSource(input.sourceID, url);
    const cacheKey = JSON.stringify({ url: url.toString(), sourceID: trustedSource?.id ?? '', maxChars });
    const cached = this.readCache(this.fetchCache, cacheKey);
    if (cached) {
      return { ...cached, cached: true };
    }

    const startedAt = Date.now();
    const gateway = trustedSource
      ? new NetworkGateway({
        allowedDomains: mergeDomains(this.allowedDomains, [url.hostname]),
        fetchImplementation: this.fetchImplementation,
        defaultTimeoutMs: this.timeoutMs,
        defaultRetryAttempts: this.retryAttempts,
        defaultMaxResponseBytes: Math.min(512_000, Math.max(64_000, maxChars * 4))
      })
      : this.fetchGateway;
    const response = await gateway.request({
      url: url.toString(),
      method: 'GET',
      headers: { accept: 'text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.1' },
      maxResponseBytes: Math.min(512_000, Math.max(64_000, maxChars * 4))
    });
    const contentType = response.headers['content-type'] ?? 'text/plain';
    const title = trustedSource?.title || extractDocumentTitle(response.bodyText) || url.hostname;
    const readable = isHTMLContentType(contentType) ? extractReadableText(response.bodyText) : normalizeWhitespace(response.bodyText);
    const content = readable.slice(0, maxChars);
    const result: WebFetchResponse = {
      source: {
        id: trustedSource?.id ?? sourceIDForURL(url),
        url: response.url,
        title,
        domain: url.hostname,
        contentType
      },
      content,
      cached: false,
      truncated: response.truncated || readable.length > maxChars,
      elapsedMs: Date.now() - startedAt
    };
    this.writeCache(this.fetchCache, cacheKey, result, this.fetchCacheTTLms);
    return result;
  }

  private async searchBrave(
    query: string,
    maxResults: number,
    language: string,
    freshness: WebSearchFreshness
  ): Promise<WebSearchResult[]> {
    if (!this.providerAPIKey) {
      throw new WebResearchError('not_configured', 'Web Search 尚未配置：Brave Search 需要 API Key。');
    }
    const endpoint = this.requireProviderEndpoint('brave');
    const requestURL = new URL(endpoint);
    requestURL.searchParams.set('q', query);
    requestURL.searchParams.set('count', String(maxResults));
    requestURL.searchParams.set('search_lang', language);
    const braveFreshness = braveFreshnessValue(freshness);
    if (braveFreshness) requestURL.searchParams.set('freshness', braveFreshness);
    const { body } = await this.searchGateway(endpoint).json<BraveSearchPayload>({
      url: requestURL.toString(),
      headers: { 'X-Subscription-Token': this.providerAPIKey }
    });
    return this.registerSources((body.web?.results ?? [])
      .map(result => toWebSearchResult({
        title: result.title,
        url: result.url,
        snippet: result.description,
        publishedAt: result.age
      }, () => this.nextSourceID()))
      .filter((result): result is WebSearchResult => result !== undefined)
      .slice(0, maxResults));
  }

  private async searchSearxNG(
    query: string,
    maxResults: number,
    language: string,
    freshness: WebSearchFreshness
  ): Promise<WebSearchResult[]> {
    const endpoint = this.requireProviderEndpoint('searxng');
    const requestURL = new URL(endpoint);
    requestURL.searchParams.set('q', query);
    requestURL.searchParams.set('format', 'json');
    requestURL.searchParams.set('language', language);
    if (freshness !== 'any') requestURL.searchParams.set('time_range', freshness);
    const { body } = await this.searchGateway(endpoint).json<SearxNGSearchPayload>({ url: requestURL.toString() });
    return this.registerSources((body.results ?? [])
      .map(result => toWebSearchResult({
        title: result.title,
        url: result.url,
        snippet: result.content,
        publishedAt: result.publishedDate ?? result.published_date
      }, () => this.nextSourceID()))
      .filter((result): result is WebSearchResult => result !== undefined)
      .slice(0, maxResults));
  }

  private async searchPublic(
    query: string,
    maxResults: number,
    language: string,
    freshness: WebSearchFreshness
  ): Promise<WebSearchResult[]> {
    const endpoint = this.providerEndpoint ?? 'https://www.bing.com/search';
    const requestURL = new URL(endpoint);
    requestURL.searchParams.set('q', query);
    requestURL.searchParams.set('count', String(maxResults));
    const market = language.toLowerCase().startsWith('zh') ? 'zh-CN' : 'en-US';
    requestURL.searchParams.set('mkt', market);
    const recency = bingFreshnessValue(freshness);
    if (recency) requestURL.searchParams.set('filters', `ex1:"ez${recency}"`);
    const response = await this.searchGateway(endpoint).request({
      url: requestURL.toString(),
      headers: {
        accept: 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1',
        'user-agent': 'Mozilla/5.0 KimiAgentDesktop/0.3.0'
      }
    });
    return this.registerSources(parseBingHTMLResults(response.bodyText, () => this.nextSourceID()).slice(0, maxResults));
  }

  private searchGateway(endpoint: string): NetworkGateway {
    const endpointURL = parseHTTPURL(endpoint, 'Web Search 服务地址无效。');
    return new NetworkGateway({
      allowedDomains: mergeDomains(this.allowedDomains, [endpointURL.hostname]),
      fetchImplementation: this.fetchImplementation,
      defaultTimeoutMs: this.timeoutMs,
      defaultRetryAttempts: this.retryAttempts,
      defaultMaxResponseBytes: 256_000
    });
  }

  private requireProvider(): WebSearchProvider {
    if (!this.provider) {
      throw new WebResearchError('not_configured', 'Web Search 尚未配置：请在连接设置中选择搜索服务并保存凭据，或配置自托管 SearxNG。');
    }
    return this.provider;
  }

  private requireProviderEndpoint(provider: WebSearchProvider): string {
    if (!this.providerEndpoint) {
      throw new WebResearchError('not_configured', `Web Search 尚未配置：${provider === 'brave' ? 'Brave' : 'SearxNG'} 服务地址为空。`);
    }
    try {
      return parseHTTPURL(this.providerEndpoint, 'Web Search 服务地址无效。').toString();
    } catch (error) {
      throw error instanceof WebResearchError
        ? error
        : new WebResearchError('invalid_configuration', 'Web Search 服务地址无效。');
    }
  }

  private registerSources(results: WebSearchResult[]): WebSearchResult[] {
    const expiresAt = Date.now() + this.fetchCacheTTLms;
    for (const source of results) {
      this.trustedSources.set(source.id, { source, expiresAt });
    }
    this.trimMap(this.trustedSources);
    return results;
  }

  private resolveTrustedSource(sourceID: string | undefined, url: URL): WebSearchResult | undefined {
    if (!sourceID?.trim()) return undefined;
    const trusted = this.trustedSources.get(sourceID);
    if (!trusted || trusted.expiresAt <= Date.now()) {
      this.trustedSources.delete(sourceID);
      throw new WebResearchError('invalid_source', 'Web Fetch 的来源已过期；请先重新搜索，再抓取该来源。');
    }
    if (new URL(trusted.source.url).toString() !== url.toString()) {
      throw new WebResearchError('invalid_source', 'Web Fetch 的 sourceID 与 URL 不匹配。');
    }
    return trusted.source;
  }

  private nextSourceID(): string {
    this.nextSourceNumber += 1;
    return `src_${this.nextSourceNumber}`;
  }

  private readCache<T>(cache: Map<string, CachedWebValue<T>>, key: string): T | undefined {
    const cached = cache.get(key);
    if (!cached) return undefined;
    if (cached.expiresAt <= Date.now()) {
      cache.delete(key);
      return undefined;
    }
    return cached.value;
  }

  private writeCache<T>(cache: Map<string, CachedWebValue<T>>, key: string, value: T, ttlMs: number): void {
    cache.set(key, { value, expiresAt: Date.now() + ttlMs });
    this.trimMap(cache);
  }

  private trimMap<T>(map: Map<string, T>): void {
    while (map.size > this.maxCacheEntries) {
      const oldest = map.keys().next().value;
      if (!oldest) return;
      map.delete(oldest);
    }
  }
}

export class MCPHttpClient {
  private readonly endpoint: URL;
  private readonly gateway: NetworkGateway;
  private readonly timeoutMs: number;
  private nextID = 0;
  private initializeResult: MCPHttpInitializeResult | undefined;

  constructor(options: { endpoint: string | URL; allowedDomains?: readonly string[]; fetchImplementation?: FetchImplementation; timeoutMs?: number }) {
    this.endpoint = new URL(String(options.endpoint));
    this.gateway = new NetworkGateway({
      allowedDomains: options.allowedDomains ?? [],
      fetchImplementation: options.fetchImplementation,
      defaultTimeoutMs: options.timeoutMs
    });
    this.timeoutMs = options.timeoutMs ?? 15_000;
  }

  async initialize(): Promise<MCPHttpInitializeResult> {
    if (this.initializeResult) {
      return this.initializeResult;
    }
    const result = await this.post<{
      protocolVersion?: string;
      serverInfo?: { name?: string; version?: string };
    }>('initialize', {
      protocolVersion: '2024-11-05',
      clientInfo: { name: 'KimiAgentDesktop', version: '0.3.0' },
      capabilities: { tools: {} }
    });
    const initializeResult = {
      protocolVersion: result.protocolVersion ?? '2024-11-05',
      serverInfo: {
        name: result.serverInfo?.name ?? 'unknown',
        version: result.serverInfo?.version ?? 'unknown'
      }
    };
    this.initializeResult = initializeResult;
    await this.post('notifications/initialized', {}, false);
    return initializeResult;
  }

  async listTools(): Promise<MCPHttpTool[]> {
    const result = await this.post<{ tools?: Array<Record<string, unknown>> }>('tools/list', {});
    return (result.tools ?? []).map(tool => ({
      id: String(tool.name ?? ''),
      name: String(tool.name ?? ''),
      description: String(tool.description ?? ''),
      inputSchemaJSON: JSON.stringify(tool.inputSchema ?? {})
    }));
  }

  async callTool(name: string, argumentsRecord: Record<string, string>): Promise<MCPHttpToolCallResult> {
    const result = await this.post<{ content?: Array<Record<string, unknown>> }>('tools/call', {
      name,
      arguments: argumentsRecord
    });
    const rawJSON = JSON.stringify(result);
    const standardOutput = (result.content ?? [])
      .map(block => String(block.text ?? ''))
      .filter(Boolean)
      .join('\n');
    return { standardOutput, rawJSON };
  }

  close(): void {}

  private async post<T>(method: string, params: Record<string, unknown>, expectResult = true): Promise<T> {
    const id = ++this.nextID;
    const payload = {
      jsonrpc: '2.0',
      id,
      method,
      params
    };
    if (!expectResult) {
      await this.gateway.request({
        url: this.endpoint.toString(),
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload),
        timeoutMs: this.timeoutMs
      });
      return {} as T;
    }
    const { body } = await this.gateway.json<Record<string, unknown>>({
      url: this.endpoint.toString(),
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload),
      timeoutMs: this.timeoutMs
    });
    if ('error' in body && body.error) {
      const error = body.error as { message?: string };
      throw new Error(error.message ?? 'MCP HTTP error');
    }
    if (!('result' in body)) {
      throw new Error('MCP response did not contain a result.');
    }
    return body.result as T;
  }
}

export class GitHubClient {
  private readonly gateway: NetworkGateway;
  private readonly token?: string;
  private readonly apiBaseURL: string;

  constructor(options: GitHubClientOptions = {}) {
    this.gateway = new NetworkGateway({
      allowedDomains: mergeDomains(['api.github.com'], options.allowedDomains),
      fetchImplementation: options.fetchImplementation
    });
    this.token = options.token?.trim() || undefined;
    this.apiBaseURL = options.apiBaseURL ?? 'https://api.github.com';
  }

  async createPullRequest(input: GitHubPullRequestInput): Promise<Record<string, unknown>> {
    this.ensureToken('create pull requests');
    return this.requestJSON('POST', `/repos/${encodePathSegment(input.owner)}/${encodePathSegment(input.repo)}/pulls`, {
      title: input.title,
      head: input.head,
      base: input.base,
      body: input.body,
      draft: input.draft ?? false
    });
  }

  async addPullRequestComment(input: GitHubCommentInput): Promise<Record<string, unknown>> {
    this.ensureToken('comment on pull requests');
    return this.requestJSON(
      'POST',
      `/repos/${encodePathSegment(input.owner)}/${encodePathSegment(input.repo)}/issues/${input.pullNumber}/comments`,
      { body: input.body }
    );
  }

  async checksSummary(input: GitHubChecksInput): Promise<Record<string, unknown>> {
    return this.requestJSON(
      'GET',
      `/repos/${encodePathSegment(input.owner)}/${encodePathSegment(input.repo)}/commits/${encodeURIComponent(input.ref)}/status`
    );
  }

  private async requestJSON(method: string, path: string, body?: Record<string, unknown>): Promise<Record<string, unknown>> {
    const headers: Record<string, string> = {
      accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28'
    };
    if (this.token) {
      headers.Authorization = `Bearer ${this.token}`;
    }
    const request = {
      url: new URL(path.replace(/^\//, ''), this.apiBaseURL.endsWith('/') ? this.apiBaseURL : `${this.apiBaseURL}/`).toString(),
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined
    };
    const { body: responseBody } = await this.gateway.json<Record<string, unknown>>(request);
    return responseBody;
  }

  private ensureToken(operation: string): void {
    if (!this.token) {
      throw new Error(`GitHub token is required to ${operation}.`);
    }
  }
}

export class GitLabClient {
  private readonly gateway: NetworkGateway;
  private readonly token?: string;
  private readonly apiBaseURL: string;

  constructor(options: GitLabClientOptions = {}) {
    this.gateway = new NetworkGateway({
      allowedDomains: mergeDomains(['gitlab.com'], options.allowedDomains),
      fetchImplementation: options.fetchImplementation
    });
    this.token = options.token?.trim() || undefined;
    this.apiBaseURL = options.apiBaseURL ?? 'https://gitlab.com/api/v4';
  }

  async createMergeRequest(input: GitLabMergeRequestInput): Promise<Record<string, unknown>> {
    this.ensureToken('create merge requests');
    const title = input.draft ? ensureDraftTitle(input.title) : input.title;
    return this.requestJSON(
      'POST',
      `/projects/${encodeURIComponent(input.projectPath)}/merge_requests`,
      {
        title,
        source_branch: input.sourceBranch,
        target_branch: input.targetBranch,
        description: input.description,
        remove_source_branch: true
      }
    );
  }

  async addMergeRequestComment(input: GitLabCommentInput): Promise<Record<string, unknown>> {
    this.ensureToken('comment on merge requests');
    return this.requestJSON(
      'POST',
      `/projects/${encodeURIComponent(input.projectPath)}/merge_requests/${input.mergeRequestIid}/notes`,
      { body: input.body }
    );
  }

  async pipelineSummary(input: GitLabPipelineSummaryInput): Promise<Record<string, unknown>> {
    return this.requestJSON(
      'GET',
      `/projects/${encodeURIComponent(input.projectPath)}/pipelines?ref=${encodeURIComponent(input.ref)}`
    );
  }

  private async requestJSON(method: string, path: string, body?: Record<string, unknown>): Promise<Record<string, unknown>> {
    const headers: Record<string, string> = {
      Accept: 'application/json'
    };
    if (this.token) {
      headers['Private-Token'] = this.token;
    }
    const { body: responseBody } = await this.gateway.json<Record<string, unknown>>({
      url: new URL(path.replace(/^\//, ''), this.apiBaseURL.endsWith('/') ? this.apiBaseURL : `${this.apiBaseURL}/`).toString(),
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined
    });
    return responseBody;
  }

  private ensureToken(operation: string): void {
    if (!this.token) {
      throw new Error(`GitLab token is required to ${operation}.`);
    }
  }
}

export function buildNetworkTools(options: {
  allowedDomains?: readonly string[];
  githubToken?: string;
  gitlabToken?: string;
  webSearchProvider?: WebSearchProvider | string;
  webSearchAPIKey?: string;
  webSearchEndpoint?: string;
  webSearchDefaultResultLimit?: number;
  fetchImplementation?: FetchImplementation;
} = {}) {
  const allowedDomains = normalizeAllowedDomains([
    ...(options.allowedDomains ?? []),
    ...readAllowedDomainsFromEnvironment()
  ]);
  const fetchImplementation = options.fetchImplementation ?? fetch;
  const webResearchClient = new WebResearchClient({
    allowedDomains,
    provider: options.webSearchProvider,
    providerAPIKey: options.webSearchAPIKey,
    providerEndpoint: options.webSearchEndpoint,
    defaultResultLimit: options.webSearchDefaultResultLimit,
    fetchImplementation
  });
  const githubClient = new GitHubClient({
    token: options.githubToken ?? readTokenFromEnvironment(['KIMI_GITHUB_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN']),
    allowedDomains: [...allowedDomains, 'api.github.com'],
    fetchImplementation
  });
  const gitlabClient = new GitLabClient({
    token: options.gitlabToken ?? readTokenFromEnvironment(['KIMI_GITLAB_TOKEN', 'GITLAB_TOKEN', 'GITLAB_PRIVATE_TOKEN']),
    allowedDomains: [...allowedDomains, 'gitlab.com'],
    fetchImplementation
  });
  return [
    createExternalTool({
      name: 'network.fetch',
      description: 'Fetch a permitted URL through the unified network gateway and return a structured summary.',
      parameters: z.object({
        url: z.string().url(),
        method: z.string().default('GET'),
        headers: z.record(z.string(), z.string()).default({}),
        body: z.string().optional(),
        timeoutMs: z.number().int().min(1).max(120_000).default(15_000),
        retryAttempts: z.number().int().min(1).max(5).default(2),
        maxResponseBytes: z.number().int().min(1_024).max(2_000_000).default(64_000)
      }),
      handler: async params => {
        const gateway = new NetworkGateway({
          allowedDomains,
          fetchImplementation
        });
        const result = await gateway.request({
          url: params.url,
          method: params.method,
          headers: params.headers,
          body: params.body,
          timeoutMs: params.timeoutMs,
          retryAttempts: params.retryAttempts,
          maxResponseBytes: params.maxResponseBytes
        });
        return {
          output: JSON.stringify(result),
          message: `${params.method} ${new URL(params.url).hostname} · ${result.status} · ${result.attempts} 次`
        };
      }
    }),
    createExternalTool({
      name: 'web.search',
      description: 'Search the configured web provider and return compact, source-identifiable results. Use web.fetch with the returned sourceID to read a result.',
      parameters: z.object({
        query: z.string().trim().min(1).max(500),
        maxResults: z.number().int().min(1).max(10).default(5),
        language: z.string().trim().min(1).max(32).default('zh-Hans'),
        freshness: z.enum(['any', 'day', 'week', 'month', 'year']).default('any')
      }),
      handler: async params => {
        const result = await webResearchClient.search(params);
        return {
          output: JSON.stringify(result),
          message: `Web Search · ${result.results.length} 个来源 · ${result.cached ? '缓存命中' : `${result.elapsedMs}ms`}`
        };
      }
    }),
    createExternalTool({
      name: 'web.fetch',
      description: 'Fetch readable text from an authorized URL or a source returned by web.search. This is read-only and returns provenance metadata for citation.',
      parameters: z.object({
        url: z.string().url().max(4_096),
        sourceID: z.string().trim().min(1).max(128).optional(),
        maxChars: z.number().int().min(1_000).max(64_000).default(12_000)
      }),
      handler: async params => {
        const result = await webResearchClient.fetch(params);
        return {
          output: JSON.stringify(result),
          message: `Web Fetch · ${result.source.domain} · ${result.cached ? '缓存命中' : `${result.elapsedMs}ms`}${result.truncated ? ' · 已截断' : ''}`
        };
      }
    }),
    createExternalTool({
      name: 'mcp.http.initialize',
      description: 'Initialize an HTTP transport MCP server and return its server info.',
      parameters: z.object({
        endpoint: z.string().url(),
        timeoutMs: z.number().int().min(1).max(120_000).default(15_000)
      }),
      handler: async params => {
        const client = new MCPHttpClient({
          endpoint: params.endpoint,
          allowedDomains,
          fetchImplementation,
          timeoutMs: params.timeoutMs
        });
        const result = await client.initialize();
        return {
          output: JSON.stringify(result),
          message: `已初始化 HTTP MCP：${result.serverInfo.name}`
        };
      }
    }),
    createExternalTool({
      name: 'mcp.http.tools_list',
      description: 'List tools from an HTTP transport MCP server.',
      parameters: z.object({
        endpoint: z.string().url(),
        timeoutMs: z.number().int().min(1).max(120_000).default(15_000)
      }),
      handler: async params => {
        const client = new MCPHttpClient({
          endpoint: params.endpoint,
          allowedDomains,
          fetchImplementation,
          timeoutMs: params.timeoutMs
        });
        await client.initialize();
        const tools = await client.listTools();
        return {
          output: JSON.stringify({ tools }),
          message: `已读取 HTTP MCP 工具列表：${tools.length} 个`
        };
      }
    }),
    createExternalTool({
      name: 'mcp.http.tools_call',
      description: 'Call a tool from an HTTP transport MCP server.',
      parameters: z.object({
        endpoint: z.string().url(),
        name: z.string(),
        arguments: z.record(z.string(), z.string()).default({}),
        timeoutMs: z.number().int().min(1).max(120_000).default(15_000)
      }),
      handler: async params => {
        const client = new MCPHttpClient({
          endpoint: params.endpoint,
          allowedDomains,
          fetchImplementation,
          timeoutMs: params.timeoutMs
        });
        await client.initialize();
        const result = await client.callTool(params.name, params.arguments);
        return {
          output: JSON.stringify(result),
          message: `已调用 HTTP MCP 工具：${params.name}`
        };
      }
    }),
    createExternalTool({
      name: 'github.pull_request.create',
      description: 'Create a GitHub pull request for the authenticated repository.',
      parameters: z.object({
        owner: z.string(),
        repo: z.string(),
        title: z.string(),
        head: z.string(),
        base: z.string(),
        body: z.string().optional(),
        draft: z.boolean().default(false)
      }),
      handler: async params => {
        const result = await githubClient.createPullRequest(params);
        return {
          output: JSON.stringify(result),
          message: `已创建 GitHub Pull Request：${String(result.number ?? 'unknown')}`
        };
      }
    }),
    createExternalTool({
      name: 'github.pull_request.comment',
      description: 'Add a comment to a GitHub pull request.',
      parameters: z.object({
        owner: z.string(),
        repo: z.string(),
        pullNumber: z.number().int().positive(),
        body: z.string()
      }),
      handler: async params => {
        const result = await githubClient.addPullRequestComment(params);
        return {
          output: JSON.stringify(result),
          message: `已评论 GitHub Pull Request #${params.pullNumber}`
        };
      }
    }),
    createExternalTool({
      name: 'github.checks.summary',
      description: 'Read the combined status summary for a GitHub commit reference.',
      parameters: z.object({
        owner: z.string(),
        repo: z.string(),
        ref: z.string()
      }),
      handler: async params => {
        const result = await githubClient.checksSummary(params);
        return {
          output: JSON.stringify(result),
          message: `已读取 GitHub 检查状态：${params.owner}/${params.repo}@${params.ref}`
        };
      }
    }),
    createExternalTool({
      name: 'gitlab.merge_request.create',
      description: 'Create a GitLab merge request for the authenticated project.',
      parameters: z.object({
        projectPath: z.string(),
        title: z.string(),
        sourceBranch: z.string(),
        targetBranch: z.string(),
        description: z.string().optional(),
        draft: z.boolean().default(false)
      }),
      handler: async params => {
        const result = await gitlabClient.createMergeRequest(params);
        return {
          output: JSON.stringify(result),
          message: `已创建 GitLab Merge Request：${String(result.iid ?? 'unknown')}`
        };
      }
    }),
    createExternalTool({
      name: 'gitlab.merge_request.comment',
      description: 'Add a comment to a GitLab merge request.',
      parameters: z.object({
        projectPath: z.string(),
        mergeRequestIid: z.number().int().positive(),
        body: z.string()
      }),
      handler: async params => {
        const result = await gitlabClient.addMergeRequestComment(params);
        return {
          output: JSON.stringify(result),
          message: `已评论 GitLab Merge Request !${params.mergeRequestIid}`
        };
      }
    }),
    createExternalTool({
      name: 'gitlab.pipeline.summary',
      description: 'Read the latest GitLab pipeline summary for a branch.',
      parameters: z.object({
        projectPath: z.string(),
        ref: z.string()
      }),
      handler: async params => {
        const result = await gitlabClient.pipelineSummary(params);
        return {
          output: JSON.stringify(result),
          message: `已读取 GitLab Pipeline：${params.projectPath}@${params.ref}`
        };
      }
    })
  ];
}

function normalizeAllowedDomains(domains: readonly string[]): string[] {
  const normalized = domains
    .map(domain => domain.trim().toLowerCase())
    .filter(Boolean);
  return Array.from(new Set(['localhost', '127.0.0.1', '::1', ...normalized]));
}

function normalizeSearchProvider(value: string | undefined): WebSearchProvider | undefined {
  const normalized = value?.trim().toLowerCase();
  if (!normalized) return undefined;
  if (normalized === 'brave' || normalized === 'searxng' || normalized === 'kimi_official' || normalized === 'public') return normalized;
  throw new WebResearchError('invalid_configuration', `不支持的 Web Search 服务：${value}。可选值为 brave、searxng、kimi_official 或 public。`);
}

function defaultSearchEndpoint(provider: WebSearchProvider | undefined): string | undefined {
  if (provider === 'brave') return 'https://api.search.brave.com/res/v1/web/search';
  if (provider === 'public') return 'https://www.bing.com/search';
  return undefined;
}

function normalizedString(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed || undefined;
}

function boundedInteger(value: number | undefined, fallback: number, minimum: number, maximum: number): number {
  const candidate = Number.isFinite(value) ? Math.trunc(value as number) : fallback;
  return Math.min(maximum, Math.max(minimum, candidate));
}

function parseHTTPURL(value: string, errorMessage: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new WebResearchError('invalid_configuration', errorMessage);
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw new WebResearchError('invalid_configuration', errorMessage);
  }
  return url;
}

function parseSafeWebFetchURL(value: string): URL {
  const url = parseHTTPURL(value, 'Web Fetch 只支持合法的 HTTP(S) URL。');
  if (isUnsafeWebTargetHostname(url.hostname)) {
    throw new WebResearchError('unsafe_target', 'Web Fetch 不允许抓取本机或私有网络地址；本地开发服务请使用 network.fetch。');
  }
  return url;
}

export function isUnsafeWebTargetHostname(hostname: string): boolean {
  const host = stripIPBrackets(hostname.trim().toLowerCase());
  if (host === 'localhost' || host === 'ip6-localhost' || host === '0.0.0.0' || host.endsWith('.localhost')) {
    return true;
  }
  if (host.includes(':')) return isUnsafeIPv6Literal(host);
  return isIPv4Literal(host) && isUnsafeIPv4(host);
}

export async function assertPublicWebFetchTarget(
  hostname: string,
  resolveHost: HostResolver = defaultHostResolver
): Promise<void> {
  const host = stripIPBrackets(hostname.trim().toLowerCase());
  if (host === 'localhost' || host === 'ip6-localhost' || host === '0.0.0.0' || host.endsWith('.localhost')) {
    throw new WebResearchError('unsafe_target', 'Web Fetch 不允许抓取本机或私有网络地址。');
  }
  if (host.includes(':')) {
    if (isUnsafeIPv6Literal(host)) {
      throw new WebResearchError('unsafe_target', 'Web Fetch 不允许抓取本机或私有网络地址。');
    }
    return;
  }
  if (isIPv4Literal(host)) {
    if (isUnsafeIPv4(host)) {
      throw new WebResearchError('unsafe_target', 'Web Fetch 不允许抓取本机或私有网络地址。');
    }
    return;
  }
  const addresses = await resolveHost(host);
  if (addresses.length === 0 || addresses.some(isUnsafeResolvedAddress)) {
    throw new WebResearchError(
      'unsafe_target',
      'Web Fetch 的目标域名解析到本机、私有网络或不可用地址，已拒绝访问。'
    );
  }
}

function isUnsafeResolvedAddress(address: string): boolean {
  const host = stripIPBrackets(address.trim().toLowerCase());
  if (host.includes(':')) return isUnsafeIPv6Literal(host);
  return isUnsafeIPv4(host);
}

function stripIPBrackets(hostname: string): string {
  return hostname.startsWith('[') && hostname.endsWith(']') ? hostname.slice(1, -1) : hostname;
}

function isIPv4Literal(host: string): boolean {
  return /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host);
}

function isUnsafeIPv4(address: string): boolean {
  const parts = address.split('.');
  if (parts.length !== 4 || parts.some(part => !/^\d{1,3}$/.test(part) || Number(part) > 255)) {
    return false;
  }
  const [first, second] = parts.map(part => Number(part));
  return first === 0
    || first === 10
    || first === 127
    || (first === 100 && second >= 64 && second <= 127)
    || (first === 169 && second === 254)
    || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168)
    || (first === 192 && second === 0 && thirdIn(parts, 2))
    || (first === 198 && second === 51 && thirdIn(parts, 100))
    || (first === 203 && second === 0 && thirdIn(parts, 113));
}

function thirdIn(parts: string[], value: number): boolean {
  return Number(parts[2]) === value;
}

function parseIPv6Groups(host: string): number[] | undefined {
  const lower = host.toLowerCase();
  if (!lower.includes(':')) return undefined;
  const parseGroups = (part: string): number[] | undefined => {
    const groups: number[] = [];
    for (const raw of part.split(':').filter(Boolean)) {
      if (raw.includes('.')) {
        const octets = raw.split('.');
        if (octets.length !== 4 || octets.some(octet => !/^\d{1,3}$/.test(octet) || Number(octet) > 255)) {
          return undefined;
        }
        const [a, b, c, d] = octets.map(octet => Number(octet));
        groups.push((a << 8) | b, (c << 8) | d);
      } else {
        if (!/^[0-9a-f]{1,4}$/.test(raw)) return undefined;
        groups.push(Number.parseInt(raw, 16));
      }
    }
    return groups;
  };
  const pieces = lower.split('::');
  if (pieces.length === 1) {
    const groups = parseGroups(pieces[0]);
    return groups && groups.length === 8 ? groups : undefined;
  }
  if (pieces.length !== 2) return undefined;
  const head = pieces[0] ? parseGroups(pieces[0]) : [];
  const tail = pieces[1] ? parseGroups(pieces[1]) : [];
  if (head === undefined || tail === undefined) return undefined;
  const missing = 8 - head.length - tail.length;
  if (missing < 1) return undefined;
  return [...head, ...Array<number>(missing).fill(0), ...tail];
}

function isUnsafeIPv6Literal(host: string): boolean {
  const groups = parseIPv6Groups(host);
  if (!groups || groups.length !== 8) return true;
  if (groups.every(group => group === 0)) return true;
  if (groups.slice(0, 7).every(group => group === 0) && groups[7] === 1) return true;
  const v4Mapped = groups.slice(0, 5).every(group => group === 0) && groups[5] === 0xffff;
  const v4Compatible = groups.slice(0, 6).every(group => group === 0);
  if (v4Mapped || v4Compatible) {
    const hi = groups[6];
    const lo = groups[7];
    return isUnsafeIPv4(`${hi >> 8}.${hi & 0xff}.${lo >> 8}.${lo & 0xff}`);
  }
  if ((groups[0] & 0xffc0) === 0xfe80) return true;
  if ((groups[0] & 0xfe00) === 0xfc00) return true;
  if ((groups[0] & 0xff00) === 0xff00) return true;
  return false;
}

function braveFreshnessValue(freshness: WebSearchFreshness): string | undefined {
  switch (freshness) {
    case 'day': return 'pd';
    case 'week': return 'pw';
    case 'month': return 'pm';
    case 'year': return 'py';
    case 'any': return undefined;
  }
}

function bingFreshnessValue(freshness: WebSearchFreshness): string | undefined {
  switch (freshness) {
    case 'day': return '1';
    case 'week': return '2';
    case 'month': return '3';
    case 'year': return '5';
    case 'any': return undefined;
  }
}

function parseBingHTMLResults(html: string, nextID: () => string): WebSearchResult[] {
  const results: WebSearchResult[] = [];
  const itemPattern = /<li\b[^>]*class=(['"])[^'"]*\bb_algo\b[^'"]*\1[^>]*>([\s\S]*?)<\/li>/gi;
  let itemMatch: RegExpExecArray | null;
  while ((itemMatch = itemPattern.exec(html)) && results.length < 10) {
    const item = itemMatch[2];
    const anchor = /<h2\b[^>]*>[\s\S]*?<a\b[^>]*href=(['"])(.*?)\1[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/h2>/i.exec(item);
    if (!anchor) continue;
    const snippetMatch = /<p\b[^>]*>([\s\S]*?)<\/p>/i.exec(item);
    const result = toWebSearchResult({
      title: htmlToPlainText(anchor[3]),
      url: decodeHTMLEntities(anchor[2]),
      snippet: snippetMatch ? htmlToPlainText(snippetMatch[1]) : ''
    }, nextID);
    if (result && !results.some(existing => existing.url === result.url)) results.push(result);
  }
  if (results.length > 0) return results;

  const anchorPattern = /<a\b[^>]*href=(['"])(https?:\/\/[^'"]+)\1[^>]*>([\s\S]*?)<\/a>/gi;
  let anchorMatch: RegExpExecArray | null;
  while ((anchorMatch = anchorPattern.exec(html)) && results.length < 10) {
    const title = htmlToPlainText(anchorMatch[3]);
    if (!title || title.length < 3) continue;
    const result = toWebSearchResult({ title, url: decodeHTMLEntities(anchorMatch[2]), snippet: '' }, nextID);
    if (result && !results.some(existing => existing.url === result.url)) results.push(result);
  }
  return results;
}

function htmlToPlainText(value: string): string {
  return normalizeWhitespace(decodeHTMLEntities(value.replace(/<[^>]+>/g, ' ')));
}

function toWebSearchResult(
  input: { title?: string; url?: string; snippet?: string; publishedAt?: string },
  nextID: () => string
): WebSearchResult | undefined {
  const title = normalizeWhitespace(input.title ?? '');
  const rawURL = normalizedString(input.url);
  if (!title || !rawURL) return undefined;
  let url: URL;
  try {
    url = parseSafeWebFetchURL(rawURL);
  } catch {
    return undefined;
  }
  return {
    id: nextID(),
    title,
    url: url.toString(),
    snippet: normalizeWhitespace(input.snippet ?? ''),
    domain: url.hostname,
    publishedAt: normalizedString(input.publishedAt)
  };
}

function extractDocumentTitle(html: string): string | undefined {
  const match = /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  return match ? normalizeWhitespace(decodeHTMLEntities(match[1])) || undefined : undefined;
}

function isHTMLContentType(contentType: string): boolean {
  return /\btext\/html\b|\bapplication\/xhtml\+xml\b/i.test(contentType);
}

function extractReadableText(html: string): string {
  const withoutNonContent = html
    .replace(/<(script|style|noscript|svg|canvas|iframe|nav|footer|header|aside)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|section|article|main|h1|h2|h3|h4|h5|h6|tr|blockquote)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ');
  return normalizeWhitespace(decodeHTMLEntities(withoutNonContent));
}

function decodeHTMLEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&#(x[0-9a-f]+|\d+);/gi, (_, encoded: string) => {
      const numeric = encoded.toLowerCase().startsWith('x')
        ? Number.parseInt(encoded.slice(1), 16)
        : Number.parseInt(encoded, 10);
      return Number.isFinite(numeric) ? String.fromCodePoint(numeric) : '';
    });
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/g, ' ').trim();
}

function sourceIDForURL(url: URL): string {
  let hash = 5381;
  for (const character of url.toString()) {
    hash = ((hash << 5) + hash) ^ character.charCodeAt(0);
  }
  return `url_${(hash >>> 0).toString(36)}`;
}

function readAllowedDomainsFromEnvironment(): string[] {
  return splitList(process.env.KIMI_AGENT_ALLOWED_DOMAINS);
}

function readTokenFromEnvironment(names: readonly string[]): string | undefined {
  for (const name of names) {
    const value = process.env[name]?.trim();
    if (value) {
      return value;
    }
  }
  return undefined;
}

function splitList(value: string | undefined): string[] {
  if (!value) return [];
  return value
    .split(/[,\s;]+/)
    .map(item => item.trim())
    .filter(Boolean);
}

function ensureDomainAllowed(url: URL, allowedDomains: readonly string[]): void {
  const hostname = url.hostname.toLowerCase();
  if (isLocalhost(hostname)) {
    return;
  }
  if (allowedDomains.some(domain => matchesDomain(hostname, domain))) {
    return;
  }
  throw new Error(`Domain ${hostname} is not in the allowed network list.`);
}

function isLocalhost(hostname: string): boolean {
  return hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1';
}

function matchesDomain(hostname: string, domain: string): boolean {
  const normalizedDomain = domain.trim().toLowerCase();
  if (!normalizedDomain) return false;
  if (normalizedDomain.startsWith('*.')) {
    const suffix = normalizedDomain.slice(1);
    return hostname === normalizedDomain.slice(2) || hostname.endsWith(suffix);
  }
  return hostname === normalizedDomain || hostname.endsWith(`.${normalizedDomain}`);
}

function shouldRetryStatus(status: number): boolean {
  return status === 429 || status >= 500;
}

function headersToRecord(headers: Headers): Record<string, string> {
  const result: Record<string, string> = {};
  headers.forEach((value, key) => {
    result[key] = value;
  });
  return result;
}

function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function readBodyWithLimit(
  response: Response,
  maxResponseBytes: number,
  controller: AbortController
): Promise<{ bodyText: string; truncated: boolean; bytesRead: number }> {
  const reader = response.body?.getReader();
  if (!reader) {
    const payload = Buffer.from(await response.arrayBuffer());
    return {
      bodyText: payload.subarray(0, maxResponseBytes).toString('utf8'),
      truncated: payload.length > maxResponseBytes,
      bytesRead: payload.length
    };
  }
  const chunks: Buffer[] = [];
  let bytesRead = 0;
  let truncated = false;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const remaining = maxResponseBytes - bytesRead;
      if (remaining <= 0) {
        truncated = true;
        await reader.cancel().catch(() => undefined);
        controller.abort();
        break;
      }
      chunks.push(Buffer.from(value).subarray(0, remaining));
      bytesRead += Math.min(value.length, remaining);
      if (value.length > remaining) truncated = true;
    }
  } finally {
    reader.releaseLock();
  }
  return { bodyText: Buffer.concat(chunks).toString('utf8'), truncated, bytesRead };
}

function mergeDomains(required: readonly string[], additional?: readonly string[]): string[] {
  return Array.from(new Set([...required, ...(additional ?? [])].map(domain => domain.trim()).filter(Boolean)));
}

function ensureDraftTitle(title: string): string {
  return /^draft:/i.test(title) ? title : `Draft: ${title}`;
}

function encodePathSegment(value: string): string {
  return encodeURIComponent(value).replaceAll('%2F', '/');
}
