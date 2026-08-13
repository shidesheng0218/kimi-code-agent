import { describe, expect, it, vi } from 'vitest';
import {
  buildComputerUseTextSummary,
  buildMacComputerUseTools,
  type ComputerUseSnapshot,
  type ScriptRunner
} from './computerUseTools.js';

describe('computer use tools', () => {
  it('formats an inspect snapshot as a readable summary', () => {
    const snapshot: ComputerUseSnapshot = {
      frontmostApp: 'Finder',
      frontmostWindow: '下载',
      screenshotPath: '/tmp/kimi-capture.png',
      elements: [
        { path: '0.0', role: 'AXButton', name: '打开', x: 120, y: 340, width: 88, height: 28 },
        { path: '0.1', role: 'AXTextField', name: '搜索', x: 180, y: 220, width: 300, height: 32 }
      ]
    };

    const summary = buildComputerUseTextSummary(snapshot);

    expect(summary).toContain('前台应用：Finder');
    expect(summary).toContain('窗口：下载');
    expect(summary).toContain('AXButton');
    expect(summary).toContain('打开');
    expect(summary).toContain('/tmp/kimi-capture.png');
  });

  it('registers the expected macOS computer use tools', () => {
    const tools = buildMacComputerUseTools({
      run: vi.fn(async () => ({ stdout: '', stderr: '' }))
    });

    expect(tools.map(tool => tool.name)).toEqual([
      'computer_use.inspect',
      'computer_use.click',
      'computer_use.click_element',
      'computer_use.type_text',
      'computer_use.press_key',
      'computer_use.screenshot'
    ]);
  });

  it('uses the runner to inspect the frontmost app', async () => {
    const runner: ScriptRunner = {
      run: vi.fn(async (_command, _args) => ({
        stdout: JSON.stringify({
          frontmostApp: 'Finder',
          frontmostWindow: '下载',
          screenshotPath: '/tmp/kimi-capture.png',
          elements: [{ path: '0.0', role: 'AXButton', name: '打开', x: 120, y: 340, width: 88, height: 28 }]
        }),
        stderr: ''
      }))
    };

    const tool = buildMacComputerUseTools(runner).find(entry => entry.name === 'computer_use.inspect');
    expect(tool).toBeTruthy();
    const result = await tool!.handler({ maxDepth: 2, maxItems: 20 });

    expect(result.output).toContain('前台应用：Finder');
    expect(result.message).toContain('Finder');
    expect(vi.mocked(runner.run)).toHaveBeenCalledOnce();
  });

  it('uses the runner to click at a coordinate', async () => {
    const calls: Array<{ command: string; args: string[] }> = [];
    const runner: ScriptRunner = {
      run: vi.fn(async (command, args) => {
        calls.push({ command, args });
        return { stdout: '', stderr: '' };
      })
    };

    const tool = buildMacComputerUseTools(runner).find(entry => entry.name === 'computer_use.click');
    const result = await tool!.handler({ x: 144, y: 288 });

    expect(result.message).toContain('点击');
    expect(calls[0]?.command).toContain('osascript');
    expect(calls[0]?.args.join(' ')).toContain('144');
    expect(calls[0]?.args.join(' ')).toContain('288');
  });

  it('can click the center of an inspected element by path', async () => {
    const calls: Array<{ command: string; args: string[] }> = [];
    const runner: ScriptRunner = {
      run: vi.fn(async (command, args) => {
        calls.push({ command, args });
        if (args.includes('-l')) {
          return {
            stdout: JSON.stringify({
              frontmostApp: 'Safari',
              frontmostWindow: 'Kimi Agent',
              elements: [
                { path: '0.2', role: 'AXButton', name: '继续', x: 100, y: 200, width: 80, height: 30 }
              ]
            }),
            stderr: ''
          };
        }
        return { stdout: '', stderr: '' };
      })
    };

    const tool = buildMacComputerUseTools(runner).find(entry => entry.name === 'computer_use.click_element');
    const result = await tool!.handler({ path: '0.2' });

    expect(result.message).toContain('继续');
    expect(result.output).toContain('"action":"click_element"');
    expect(calls.at(-1)?.args.join(' ')).toContain('140');
    expect(calls.at(-1)?.args.join(' ')).toContain('215');
  });

  it('retries transient click failures and reports attempts', async () => {
    let attempts = 0;
    const runner: ScriptRunner = {
      run: vi.fn(async () => {
        attempts += 1;
        if (attempts === 1) throw new Error('transient accessibility failure');
        return { stdout: '', stderr: '' };
      })
    };

    const tool = buildMacComputerUseTools(runner).find(entry => entry.name === 'computer_use.click');
    const result = await tool!.handler({ x: 12, y: 34 });

    expect(result.output).toContain('"attempts":2');
    expect(result.message).toContain('第 2 次');
  });
});
