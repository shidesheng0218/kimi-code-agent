import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { build } from 'esbuild';
import { afterEach, describe, expect, it } from 'vitest';

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(directory => rm(directory, { recursive: true, force: true })));
});

describe('Native ACP Agent Host', () => {
  it('runs the ACP lifecycle and forwards web source evidence to the desktop bridge', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'kimi-acp-host-test-'));
    temporaryDirectories.push(directory);
    const hostPath = join(directory, 'agent-host.cjs');
    const runtimePath = join(directory, 'mock-kimi-runtime.cjs');
    await build({
      entryPoints: [join(process.cwd(), 'src/runtime/nativeAgentHost.ts')],
      outfile: hostPath,
      bundle: true,
      platform: 'node',
      format: 'cjs',
      target: 'node22',
      legalComments: 'none'
    });
    await writeFile(runtimePath, mockAcpRuntime, 'utf8');

    const child = spawn(process.execPath, [hostPath], { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => { output += chunk; });
    child.stdin.write(`${JSON.stringify({
      type: 'start',
      sessionID: '00000000-0000-0000-0000-000000000001',
      taskID: '00000000-0000-0000-0000-000000000002',
      workspacePath: directory,
      runtimePath,
      nodePath: process.execPath,
      prompt: '搜索 Kimi 文档',
      modelID: 'kimi-code'
    })}\n`);
    const exitCode = await new Promise<number | null>((resolve, reject) => {
      child.once('error', reject);
      child.once('exit', resolve);
    });
    const messages = output.trim().split('\n').map(line => JSON.parse(line) as Record<string, unknown>);
    const ready = messages.find(message => message.type === 'ready');
    const sourceEvent = messages.find(message => {
      const event = message.event as Record<string, unknown> | undefined;
      const payload = event?.payload as Record<string, string> | undefined;
      return event?.kind === 'toolFinished' && payload?.webResearchAction === 'search';
    });

    expect(exitCode).toBe(0);
    expect(ready).toMatchObject({ runtimeSessionID: 'session_mock_1' });
    expect(sourceEvent).toMatchObject({
      type: 'event',
      event: {
        kind: 'toolFinished',
        payload: expect.objectContaining({
          webResearchAction: 'search',
          sources: expect.stringContaining('https://docs.example.com/kimi')
        })
      }
    });
    expect(messages.some(message => message.type === 'completed')).toBe(true);
  });
});

const mockAcpRuntime = String.raw`
process.stdin.setEncoding('utf8');
let buffer = '';
process.stdin.on('data', chunk => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const message = JSON.parse(buffer.slice(0, newline));
    buffer = buffer.slice(newline + 1);
    if (message.method === 'initialize') reply(message.id, { protocolVersion: 1 });
    else if (message.method === 'session/new') {
      if (!Array.isArray(message.params?.mcpServers)) replyError(message.id, -32602, 'mcpServers is required');
      else reply(message.id, { sessionId: 'session_mock_1' });
    }
    else if (message.method === 'session/set_model') reply(message.id, {});
    else if (message.method === 'session/prompt') {
      notify('session/update', { sessionId: 'session_mock_1', update: { sessionUpdate: 'tool_call', toolCallId: 'tool-1', title: 'WebSearch', kind: 'fetch', status: 'in_progress', rawInput: { query: 'Kimi docs' } } });
      notify('session/update', { sessionId: 'session_mock_1', update: { sessionUpdate: 'tool_call_update', toolCallId: 'tool-1', status: 'completed', rawOutput: { search_results: [{ title: 'Kimi Docs', url: 'https://docs.example.com/kimi', snippet: 'Kimi reference.' }] } } });
      notify('session/update', { sessionId: 'session_mock_1', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '已找到来源。' } } });
      reply(message.id, { stopReason: 'end_turn' });
    }
  }
});
function reply(id, result) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n'); }
function replyError(id, code, message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n'); }
function notify(method, params) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n'); }
`;
