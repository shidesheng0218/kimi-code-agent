import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { WebResearchClient, type WebFetchRequest, type WebFetchResponse, type WebSearchRequest, type WebSearchResponse } from './networkGateway.js';
import { KimiOfficialResearchClient, type KimiOfficialFetchResponse } from './kimiOfficialResearch.js';

const maximumRequestBytes = 64_000;

export function readyPayload(port: number): { type: 'ready'; url: string; healthURL: string } {
  let baseURL = `http://127.0.0.1:${port}`;
  return { type: 'ready', url: `${baseURL}/search`, healthURL: `${baseURL}/health` };
}

interface ResearchSearchClient {
  providerName?: string;
  search(request: WebSearchRequest): Promise<WebSearchResponse & { usage?: { inputTokens: number; outputTokens: number; totalTokens: number; toolCalls: number } }>;
  fetch?(request: WebFetchRequest): Promise<WebFetchResponse | KimiOfficialFetchResponse>;
}

interface WebResearchBridgeOptions {
  primaryTimeoutMs?: number;
}

export interface WebResearchBridgeUsage {
  searches: number;
  cachedSearches: number;
  fallbackSearches: number;
  lastFallbackError?: string;
  provider: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  toolCalls: number;
  fetches: number;
  cachedFetches: number;
  fetchedChars: number;
}

export function createWebResearchBridgeServer(
  client: ResearchSearchClient = createConfiguredResearchClient(),
  fallbackClient: ResearchSearchClient = createFallbackResearchClient(),
  options: WebResearchBridgeOptions = {}
): Server {
  const configuredPrimaryTimeoutMs = options.primaryTimeoutMs ?? (Number(process.env.KIMI_AGENT_WEB_SEARCH_PRIMARY_TIMEOUT_MS) || 8_000);
  const primaryTimeoutMs = Math.max(1_000, Math.min(configuredPrimaryTimeoutMs, 60_000));
  const usage: WebResearchBridgeUsage = {
    searches: 0,
    cachedSearches: 0,
    fallbackSearches: 0,
    provider: configuredProviderName(client),
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    toolCalls: 0,
    fetches: 0,
    cachedFetches: 0,
    fetchedChars: 0
  };
  return createServer(async (request, response) => {
    if (request.method === 'GET' && request.url === '/health') {
      writeJSON(response, 200, { ok: true });
      return;
    }
    if (request.method === 'GET' && request.url === '/usage') {
      writeJSON(response, 200, { ...usage });
      return;
    }
    if (request.method !== 'POST') {
      writeJSON(response, 405, { error: 'method_not_allowed' });
      return;
    }
    if (request.headers.origin) {
      writeJSON(response, 403, { error: 'origin_not_allowed' });
      return;
    }

    try {
      const body = await readJSONBody(request);
      if (request.url === '/fetch') {
        const url = typeof body.url === 'string' ? body.url : '';
        if (!url.trim()) {
          writeJSON(response, 400, { error: 'url is required' });
          return;
        }
        if (!client.fetch) {
          writeJSON(response, 501, { error: 'fetch_not_supported' });
          return;
        }
        const fetched = await client.fetch({ url, sourceID: typeof body.source_id === 'string' ? body.source_id : undefined, maxChars: typeof body.max_chars === 'number' ? body.max_chars : undefined });
        usage.fetches += 1;
        if (fetched.cached) usage.cachedFetches += 1;
        usage.fetchedChars += fetched.content.length;
        writeJSON(response, 200, fetched as unknown as Record<string, unknown>);
        return;
      }
      if (request.url !== '/search') {
        writeJSON(response, 404, { error: 'not_found' });
        return;
      }
      const query = typeof body.text_query === 'string' ? body.text_query : '';
      if (!query.trim()) {
        writeJSON(response, 400, { error: 'text_query is required' });
        return;
      }
      let fallbackError: string | undefined;
      let search: Awaited<ReturnType<ResearchSearchClient['search']>>;
      try {
        search = await withTimeout(client.search({ query }), primaryTimeoutMs, `${configuredProviderName(client)} Web Search 超时，已自动切换公开检索。`);
        if (search.results.length === 0 && configuredProviderName(client) === 'kimi_official') {
          throw new Error('Kimi 官方联网没有返回可验证来源。');
        }
      } catch (error) {
        fallbackError = sanitizeErrorMessage(error instanceof Error ? error.message : String(error));
        try {
          search = await fallbackClient.search({ query });
        } catch (fallbackFailure) {
          const finalFallbackError = sanitizeErrorMessage(fallbackFailure instanceof Error ? fallbackFailure.message : String(fallbackFailure));
          usage.lastFallbackError = fallbackError;
          writeJSON(response, 502, {
            error: `Web Search 请求失败：官方联网失败，公开检索也失败。官方：${fallbackError}；公开检索：${finalFallbackError}`,
            primary_error: fallbackError,
            fallback_error: finalFallbackError
          });
          return;
        }
        usage.fallbackSearches += 1;
        usage.lastFallbackError = fallbackError;
      }
      usage.searches += 1;
      if (search.cached) usage.cachedSearches += 1;
      usage.provider = search.provider;
      if (search.usage) {
        usage.inputTokens += search.usage.inputTokens;
        usage.outputTokens += search.usage.outputTokens;
        usage.totalTokens += search.usage.totalTokens;
        usage.toolCalls += search.usage.toolCalls;
      }
      writeJSON(response, 200, {
        search_results: search.results.map(result => ({
          title: result.title,
          url: result.url,
          snippet: result.snippet,
          ...(result.publishedAt ? { date: result.publishedAt } : {}),
          site_name: result.domain
        })),
        ...(fallbackError ? { fallback_error: fallbackError } : {})
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      writeJSON(response, 502, { error: sanitizeErrorMessage(message) });
    }
  });
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => { timer = setTimeout(() => reject(new Error(message)), timeoutMs); })
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export function createConfiguredResearchClient(environment: NodeJS.ProcessEnv = process.env): ResearchSearchClient {
  const provider = environment.KIMI_AGENT_WEB_SEARCH_PROVIDER?.trim().toLowerCase();
  if (provider === 'kimi_official') {
    const apiKey = environment.KIMI_API_KEY?.trim() || environment.MOONSHOT_API_KEY?.trim();
    if (!apiKey) throw new Error('Kimi 官方联网需要已保存的 Kimi API Key。');
    return new KimiOfficialResearchClient({
      apiKey,
      baseURL: environment.KIMI_AGENT_OFFICIAL_TOOLS_BASE_URL?.trim() || 'https://api.moonshot.cn/v1',
      model: environment.KIMI_AGENT_OFFICIAL_TOOLS_MODEL?.trim() || 'kimi-k3',
      maxResults: Number(environment.KIMI_AGENT_WEB_SEARCH_DEFAULT_RESULTS) || 5
    });
  }
  return new WebResearchClient();
}

export function createFallbackResearchClient(environment: NodeJS.ProcessEnv = process.env): ResearchSearchClient {
  const provider = environment.KIMI_AGENT_WEB_SEARCH_FALLBACK_PROVIDER?.trim().toLowerCase() || 'public';
  if (provider === 'none' || provider === 'disabled') {
    return {
      providerName: 'disabled',
      search: async () => { throw new Error('Web Search fallback 已关闭。'); }
    };
  }
  return new WebResearchClient({
    provider,
    providerAPIKey: environment.KIMI_AGENT_WEB_SEARCH_FALLBACK_API_KEY,
    providerEndpoint: environment.KIMI_AGENT_WEB_SEARCH_FALLBACK_ENDPOINT,
    defaultResultLimit: Number(environment.KIMI_AGENT_WEB_SEARCH_DEFAULT_RESULTS) || 5
  });
}

async function readJSONBody(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    totalBytes += value.length;
    if (totalBytes > maximumRequestBytes) {
      throw new Error('request body is too large');
    }
    chunks.push(value);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw.trim()) return {};
  const value = JSON.parse(raw) as unknown;
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('request body must be a JSON object');
  }
  return value as Record<string, unknown>;
}

function writeJSON(response: ServerResponse, status: number, body: Record<string, unknown>): void {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload)
  });
  response.end(payload);
}

function sanitizeErrorMessage(value: string): string {
  return value
    .replace(/Bearer\s+[^\s]+/gi, 'Bearer [redacted]')
    .replace(/(api[_ -]?key\s*[:=]\s*)[^\s,;]+/gi, '$1[redacted]');
}

function configuredProviderName(client: ResearchSearchClient): string {
  return client.providerName
    ?? (client instanceof KimiOfficialResearchClient ? 'kimi_official' : 'custom');
}

function requestedPort(argumentsList: string[]): number {
  const index = argumentsList.indexOf('--port');
  const candidate = index >= 0 ? Number(argumentsList[index + 1]) : 0;
  return Number.isInteger(candidate) && candidate >= 0 && candidate < 65_536 ? candidate : 0;
}

function startBridgeFromCommandLine(): void {
  const port = requestedPort(process.argv.slice(2));
  const server = createWebResearchBridgeServer();
  server.once('error', error => {
    process.stderr.write(`web research bridge: ${error.message}\n`);
    process.exitCode = 1;
  });
  server.listen(port, '127.0.0.1', () => {
    const address = server.address();
    const actualPort = typeof address === 'object' && address ? address.port : port;
    process.stdout.write(`${JSON.stringify(readyPayload(actualPort))}\n`);
  });
  const stop = () => server.close(() => process.exit(0));
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}

if (require.main === module) {
  startBridgeFromCommandLine();
}
