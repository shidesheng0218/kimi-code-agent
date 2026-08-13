import { createHash } from 'node:crypto';
import {
  assertPublicWebFetchTarget,
  defaultHostResolver,
  isUnsafeWebTargetHostname,
  type HostResolver
} from './networkGateway.js';
import type { WebSearchRequest, WebSearchResponse, WebSearchResult } from './networkGateway.js';

type FetchImplementation = typeof fetch;
type JsonRecord = Record<string, unknown>;

export interface KimiOfficialResearchUsage {
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  toolCalls: number;
}

export interface KimiOfficialResearchResponse extends WebSearchResponse {
  provider: 'kimi_official';
  usage: KimiOfficialResearchUsage;
}

export interface KimiOfficialFetchRequest {
  url: string;
  sourceID?: string;
  maxChars?: number;
}

export interface KimiOfficialFetchResponse {
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

export interface KimiOfficialResearchClientOptions {
  apiKey: string;
  baseURL?: string;
  model?: string;
  fetchImplementation?: FetchImplementation;
  resolveHost?: HostResolver;
  cacheTTLms?: number;
  maxResults?: number;
  maxFetchChars?: number;
  protocol?: 'official' | 'formula';
  timeoutMs?: number;
}

interface CacheEntry {
  expiresAt: number;
  response: KimiOfficialResearchResponse;
}

export class KimiOfficialResearchClient {
  private readonly apiKey: string;
  private readonly baseURL: string;
  private readonly model: string;
  private readonly fetchImplementation: FetchImplementation;
  private readonly resolveHost: HostResolver;
  private readonly cacheTTLms: number;
  private readonly maxResults: number;
  private readonly maxFetchChars: number;
  private readonly protocol: 'official' | 'formula';
  private readonly timeoutMs: number;
  private readonly cache = new Map<string, CacheEntry>();
  private readonly fetchCache = new Map<string, { expiresAt: number; response: KimiOfficialFetchResponse }>();
  private readonly sourceRegistry = new Map<string, string>();
  private toolDeclaration: unknown[] | undefined;

  constructor(options: KimiOfficialResearchClientOptions) {
    this.apiKey = options.apiKey.trim();
    if (!this.apiKey) throw new Error('Kimi 官方联网需要 Kimi API Key。');
    this.baseURL = (options.baseURL ?? 'https://api.moonshot.cn/v1').replace(/\/$/, '');
    this.model = options.model?.trim() || 'kimi-k3';
    this.fetchImplementation = options.fetchImplementation ?? fetch;
    this.resolveHost = options.resolveHost ?? defaultHostResolver;
    this.cacheTTLms = Math.max(1_000, options.cacheTTLms ?? 10 * 60_000);
    this.maxResults = Math.max(1, Math.min(options.maxResults ?? 5, 10));
    this.maxFetchChars = Math.max(200, Math.min(options.maxFetchChars ?? 25_000, 50_000));
    this.protocol = options.protocol ?? 'formula';
    this.timeoutMs = Math.max(1_000, options.timeoutMs ?? 15_000);
  }

  async search(request: WebSearchRequest): Promise<KimiOfficialResearchResponse> {
    const query = request.query.trim();
    if (!query) throw new Error('Web Search 查询不能为空。');
    const cacheKey = query.toLocaleLowerCase();
    const cached = this.cache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) {
      return { ...cached.response, cached: true, elapsedMs: 0 };
    }

    if (this.protocol === 'official') return this.directSearch(request, cacheKey);

    const startedAt = Date.now();
    const tools = await this.formulaTools('moonshot/web-search:latest');
    const researchInstruction = [
      '你是桌面应用的联网研究工具。',
      '必须使用提供的 web_search 工具查询用户问题。',
      '收到工具结果后，只返回一个 JSON 对象，不要 Markdown。',
      'JSON 格式：{"sources":[{"title":"","url":"https://...","snippet":"","date":""}]}。',
      `最多返回 ${request.maxResults ?? this.maxResults} 条公开、可访问、直接相关来源。`,
      '没有可靠来源时返回 {"sources":[]}。'
    ].join('\n');
    const initialMessages: JsonRecord[] = [
      { role: 'system', content: researchInstruction },
      { role: 'user', content: query }
    ];
    const responses: JsonRecord[] = [];
    let toolCallCount = 0;
    const maximumFormulaRounds = 4;
    const maximumAttempts = 2;
    let result: WebSearchResult[] = [];
    let sawToolCall = false;

    for (let attempt = 0; attempt < maximumAttempts && result.length === 0; attempt += 1) {
      // A bounded retry starts a fresh research conversation. This avoids
      // asking a reasoning model to repair an already-empty JSON answer while
      // still guaranteeing we never loop indefinitely or duplicate a settled
      // user-visible operation.
      const messages = [...initialMessages];
      if (attempt > 0) {
        messages.push({ role: 'user', content: '上一次检索没有返回可验证来源。请换一种关键词重新搜索，并继续使用 web_search；最终只返回包含真实 URL 的 JSON。' });
      }
      for (let round = 0; round < maximumFormulaRounds; round += 1) {
        const completion = await this.chatCompletion(messages, tools);
        responses.push(completion);
        const assistant = choiceMessage(completion);
        const toolCalls = asArray(assistant.tool_calls);

        if (toolCalls.length === 0) {
          if (!sawToolCall && attempt === 0) throw new Error('Kimi 官方联网未触发 web_search 工具调用。');
          result = parseSources(choiceContent(completion));
          break;
        }

        sawToolCall = true;
        messages.push(compactAssistantMessage(assistant));
        for (const rawToolCall of toolCalls) {
          const toolCall = asRecord(rawToolCall);
          const functionInfo = asRecord(toolCall.function);
          const name = String(functionInfo.name ?? '');
          const argumentsValue = String(functionInfo.arguments ?? '{}');
          if (name !== 'web_search') throw new Error(`Kimi 官方联网返回了不支持的工具：${name || 'unknown'}。`);
          const fiber = await this.fiber('moonshot/web-search:latest', name, argumentsValue);
          const context = asRecord(fiber.context);
          const output = String(context.output ?? context.encrypted_output ?? '');
          if (!output) throw new Error('Kimi 官方联网工具未返回可用结果。');
          messages.push({ role: 'tool', tool_call_id: String(toolCall.id ?? ''), content: output });
          toolCallCount += 1;
        }
      }
    }

    if (result.length === 0) throw new Error('Kimi 官方联网已执行搜索，但没有返回可验证来源。请稍后重试或更换关键词。');
    const usage = addUsage(responses, toolCallCount);
    const response: KimiOfficialResearchResponse = {
      query,
      provider: 'kimi_official',
      results: result.slice(0, request.maxResults ?? this.maxResults),
      cached: false,
      elapsedMs: Date.now() - startedAt,
      usage
    };
    this.cache.set(cacheKey, { expiresAt: Date.now() + this.cacheTTLms, response });
    for (const source of response.results) this.sourceRegistry.set(source.id, source.url);
    return response;
  }

  async fetch(request: KimiOfficialFetchRequest): Promise<KimiOfficialFetchResponse> {
    const url = normalizePublicURL(request.url);
    await assertPublicWebFetchTarget(new URL(url).hostname, this.resolveHost);
    if (request.sourceID && this.sourceRegistry.get(request.sourceID) !== url) {
      throw new Error('Web Fetch 的 sourceID 与 URL 不匹配。');
    }
    const cacheKey = url.toLowerCase();
    const cached = this.fetchCache.get(cacheKey);
    if (cached && cached.expiresAt > Date.now()) return { ...cached.response, cached: true, elapsedMs: 0 };
    const startedAt = Date.now();
    const response = await this.rawRequest('POST', '/fetch', { url }, { accept: 'text/markdown' });
    const maxChars = Math.max(200, Math.min(request.maxChars ?? this.maxFetchChars, this.maxFetchChars));
    let contentType = response.contentType;
    let content = extractOfficialFetchContent(response.bodyText, contentType);
    if (!content.trim()) {
      const fallback = await this.fetchPublicDocument(url);
      contentType = fallback.contentType;
      content = fallback.bodyText;
    }
    const title = extractDocumentTitle(content) || new URL(url).hostname;
    const result: KimiOfficialFetchResponse = {
      source: {
        id: createHash('sha256').update(url).digest('hex').slice(0, 16),
        url,
        title,
        domain: new URL(url).hostname,
        contentType
      },
      content: content.slice(0, maxChars),
      cached: false,
      truncated: content.length > maxChars,
      elapsedMs: Date.now() - startedAt
    };
    this.fetchCache.set(cacheKey, { expiresAt: Date.now() + this.cacheTTLms, response: result });
    this.sourceRegistry.set(result.source.id, url);
    return result;
  }

  private async fetchPublicDocument(url: string): Promise<{ bodyText: string; contentType: string }> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImplementation(url, {
        method: 'GET',
        signal: controller.signal,
        headers: { accept: 'text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.1' }
      });
      const bodyText = await response.text();
      if (!response.ok) throw new Error(`Web Fetch 直接读取失败：HTTP ${response.status}`);
      return { bodyText, contentType: response.headers.get('content-type') ?? 'text/plain' };
    } finally {
      clearTimeout(timer);
    }
  }

  private async directSearch(request: WebSearchRequest, cacheKey: string): Promise<KimiOfficialResearchResponse> {
    const startedAt = Date.now();
    const response = await this.rawRequest('POST', '/search', { text_query: request.query.trim() });
    const rawResults = Array.isArray(response.json.search_results) ? response.json.search_results : [];
    const results = rawResults.flatMap(value => parseOfficialSearchResult(value)).slice(0, request.maxResults ?? this.maxResults);
    const result: KimiOfficialResearchResponse = {
      query: request.query.trim(),
      provider: 'kimi_official',
      results,
      cached: false,
      elapsedMs: Date.now() - startedAt,
      usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0, toolCalls: 1 }
    };
    this.cache.set(cacheKey, { expiresAt: Date.now() + this.cacheTTLms, response: result });
    for (const source of result.results) this.sourceRegistry.set(source.id, source.url);
    return result;
  }

  private async formulaTools(uri: string): Promise<unknown[]> {
    if (this.toolDeclaration) return this.toolDeclaration;
    const response = await this.request('GET', `/formulas/${uri}/tools`);
    const tools = asArray(response.tools);
    if (tools.length === 0) throw new Error('Kimi 官方联网未返回 web-search 工具声明。');
    this.toolDeclaration = tools;
    return tools;
  }

  private async fiber(uri: string, name: string, argumentsValue: string): Promise<JsonRecord> {
    return this.request('POST', `/formulas/${uri}/fibers`, { name, arguments: argumentsValue });
  }

  private async chatCompletion(messages: JsonRecord[], tools: unknown[]): Promise<JsonRecord> {
    return this.request('POST', '/chat/completions', { model: this.model, messages, tools });
  }

  private async request(method: string, path: string, body?: JsonRecord): Promise<JsonRecord> {
    const result = await this.rawRequest(method, path, body);
    return result.json;
  }

  private async rawRequest(method: string, path: string, body?: JsonRecord, options: { accept?: string } = {}): Promise<{ json: JsonRecord; bodyText: string; contentType: string }> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImplementation(`${this.baseURL}${path}`, {
        method,
        signal: controller.signal,
        headers: {
          authorization: `Bearer ${this.apiKey}`,
          accept: options.accept ?? 'application/json',
          ...(body ? { 'content-type': 'application/json' } : {})
        },
        ...(body ? { body: JSON.stringify(body) } : {})
      });
      const bodyText = await response.text();
      let parsed: unknown;
      try { parsed = bodyText ? JSON.parse(bodyText) : {}; } catch { parsed = {}; }
      if (!response.ok) {
        const message = officialAPIErrorMessage(parsed, bodyText, response.status);
        throw new Error(`Kimi 官方联网请求失败：${sanitize(message)}`);
      }
      return {
        json: asRecord(parsed),
        bodyText: options.accept === 'text/markdown' ? bodyText : bodyText,
        contentType: response.headers.get('content-type') ?? 'application/json'
      };
    } finally {
      clearTimeout(timer);
    }
  }
}

function parseOfficialSearchResult(value: unknown): WebSearchResult[] {
  const source = asRecord(value);
  const url = typeof source.url === 'string' ? source.url.trim() : '';
  if (!/^https?:\/\//i.test(url)) return [];
  let domain = '';
  try { domain = new URL(url).hostname; } catch { return []; }
  return [{
    id: createHash('sha256').update(url).digest('hex').slice(0, 16),
    title: typeof source.title === 'string' && source.title.trim() ? source.title.trim() : url,
    url,
    snippet: typeof source.snippet === 'string' ? source.snippet.trim() : '',
    domain,
    ...(typeof source.date === 'string' && source.date.trim() ? { publishedAt: source.date.trim() } : {})
  }];
}

function extractOfficialFetchContent(bodyText: string, contentType: string): string {
  if (!/application\/json/i.test(contentType)) return bodyText;
  try {
    const value = asRecord(JSON.parse(bodyText));
    for (const key of ['content', 'text', 'markdown', 'body', 'html']) {
      if (typeof value[key] === 'string' && value[key].trim()) return value[key] as string;
    }
  } catch {
    // A non-JSON response with a misleading content type is still usable as text.
    return bodyText;
  }
  return '';
}

function extractDocumentTitle(value: string): string | undefined {
  const match = /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(value);
  return match ? decodeHTMLEntities(match[1]).replace(/\s+/g, ' ').trim() || undefined : undefined;
}

function decodeHTMLEntities(value: string): string {
  return value
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'");
}

function normalizePublicURL(value: string): string {
  const parsed = new URL(value.trim());
  if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('Web Fetch 只允许 HTTP(S) 地址。');
  if (isUnsafeWebTargetHostname(parsed.hostname)) {
    throw new Error('Web Fetch 不允许访问本机或私有网络地址。');
  }
  return parsed.toString();
}

function choiceMessage(response: JsonRecord): JsonRecord {
  const first = asRecord(asArray(response.choices)[0]);
  const message = asRecord(first.message);
  if (Object.keys(message).length === 0) throw new Error('Kimi 官方联网未返回模型消息。');
  return message;
}

function choiceContent(response: JsonRecord): string {
  const content = choiceMessage(response).content;
  if (typeof content !== 'string') throw new Error('Kimi 官方联网未返回结构化来源。');
  return content;
}

function compactAssistantMessage(message: JsonRecord): JsonRecord {
  return {
    role: 'assistant',
    ...(typeof message.content === 'string' ? { content: message.content } : {}),
    // Kimi reasoning models require the assistant reasoning from a tool-call
    // turn to be returned unchanged with its tool results. Dropping this
    // field breaks the Formula continuation: the next request can repeat the
    // search or produce an empty answer even though the Fiber succeeded.
    ...(typeof message.reasoning_content === 'string' ? { reasoning_content: message.reasoning_content } : {}),
    tool_calls: asArray(message.tool_calls)
  };
}

function parseSources(content: string): WebSearchResult[] {
  const parsed = asRecord(parseJSONObject(content));
  const values = asArray(parsed.sources);
  const unique = new Map<string, WebSearchResult>();
  for (const value of values) {
    const source = asRecord(value);
    const url = typeof source.url === 'string' ? source.url.trim() : '';
    if (!/^https?:\/\//i.test(url)) continue;
    let domain = '';
    try { domain = new URL(url).hostname; } catch { continue; }
    unique.set(url, {
      id: createHash('sha256').update(url).digest('hex').slice(0, 16),
      title: typeof source.title === 'string' && source.title.trim() ? source.title.trim() : url,
      url,
      snippet: typeof source.snippet === 'string' ? source.snippet.trim() : '',
      domain,
      ...(typeof source.date === 'string' && source.date.trim() ? { publishedAt: source.date.trim() } : {})
    });
  }
  return [...unique.values()];
}

function parseJSONObject(value: string): unknown {
  const trimmed = value.trim();
  const match = trimmed.match(/\{[\s\S]*\}/);
  if (!match) throw new Error('Kimi 官方联网返回的来源格式无效。');
  try { return JSON.parse(match[0]); } catch { throw new Error('Kimi 官方联网返回的来源 JSON 无法解析。'); }
}

function addUsage(responses: JsonRecord[], toolCalls: number): KimiOfficialResearchUsage {
  let inputTokens = 0;
  let outputTokens = 0;
  for (const response of responses) {
    const usage = asRecord(response.usage);
    inputTokens += numberValue(usage.prompt_tokens);
    outputTokens += numberValue(usage.completion_tokens);
  }
  return { inputTokens, outputTokens, totalTokens: inputTokens + outputTokens, toolCalls };
}

function numberValue(value: unknown): number { return typeof value === 'number' && Number.isFinite(value) ? value : 0; }
function asArray(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function asRecord(value: unknown): JsonRecord { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonRecord : {}; }
function officialAPIErrorMessage(parsed: unknown, bodyText: string, status: number): string {
  const error = asRecord(asRecord(parsed).error);
  const candidates = [
    error.message,
    error.code,
    asRecord(parsed).message,
    asRecord(parsed).code,
    typeof asRecord(parsed).error === 'string' ? asRecord(parsed).error : undefined,
    bodyText.trim() || undefined,
    `HTTP ${status}`
  ];
  for (const candidate of candidates) {
    if (typeof candidate === 'string' && candidate.trim()) return candidate.trim();
  }
  return `HTTP ${status}`;
}
function sanitize(value: string): string { return value.replace(/Bearer\s+[^\s]+/gi, 'Bearer [redacted]').slice(0, 400); }
