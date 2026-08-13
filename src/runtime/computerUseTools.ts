import { execFile } from 'node:child_process';
import { mkdtemp, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { createExternalTool } from '@moonshot-ai/kimi-agent-sdk';
import { z } from 'zod';

const execFileAsync = promisify(execFile);

export interface ScriptRunner {
  run(command: string, args: string[]): Promise<{ stdout: string; stderr: string }>;
}

export interface ComputerUseElement {
  path: string;
  role: string;
  name?: string;
  value?: string;
  description?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
}

export interface ComputerUseSnapshot {
  frontmostApp: string;
  frontmostWindow?: string;
  windowBounds?: {
    x: number;
    y: number;
    width: number;
    height: number;
  };
  screenshotPath?: string;
  elements: ComputerUseElement[];
}

interface ToolResult {
  output: string;
  message: string;
}

const defaultRunner: ScriptRunner = {
  async run(command, args) {
    const result = await execFileAsync(command, args, {
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024
    });
    return {
      stdout: typeof result.stdout === 'string' ? result.stdout : String(result.stdout ?? ''),
      stderr: typeof result.stderr === 'string' ? result.stderr : String(result.stderr ?? '')
    };
  }
};

export function buildMacComputerUseTools(runner: ScriptRunner = defaultRunner) {
  return [
    createExternalTool({
      name: 'computer_use.inspect',
      description: 'Inspect the frontmost macOS window and return a compact accessibility summary.',
      parameters: z.object({
        maxDepth: z.number().int().min(0).max(5).default(2),
        maxItems: z.number().int().min(1).max(200).default(50)
      }),
      handler: async (params): Promise<ToolResult> => {
        const snapshot = await inspectFrontmostWindow(runner, params.maxDepth, params.maxItems);
        const output = buildComputerUseTextSummary(snapshot);
        return {
          output,
          message: `已检查前台窗口：${snapshot.frontmostApp}${snapshot.frontmostWindow ? ` / ${snapshot.frontmostWindow}` : ''}`
        };
      }
    }),
    createExternalTool({
      name: 'computer_use.click',
      description: 'Click at a screen coordinate.',
      parameters: z.object({
        x: z.number(),
        y: z.number()
      }),
      handler: async params => {
        const x = Math.round(params.x);
        const y = Math.round(params.y);
        const result = await runWithRetry(runner, () => runAppleScript(runner, `tell application "System Events" to click at {${x}, ${y}}`));
        return buildActionResult('click', `已点击坐标 (${x}, ${y})`, { x, y, attempts: result.attempts });
      }
    }),
    createExternalTool({
      name: 'computer_use.click_element',
      description: 'Inspect the frontmost window and click a visible element by path or label.',
      parameters: z.object({
        path: z.string().optional(),
        name: z.string().optional(),
        role: z.string().optional(),
        maxDepth: z.number().int().min(0).max(5).default(2),
        maxItems: z.number().int().min(1).max(200).default(50)
      }),
      handler: async params => {
        const snapshot = await inspectFrontmostWindow(runner, params.maxDepth, params.maxItems);
        const element = findTargetElement(snapshot, params.path, params.name, params.role);
        if (!element) {
          throw new Error(`未找到可点击元素：${params.path ?? params.name ?? params.role ?? 'unknown'}`);
        }
        const x = centerCoordinate(element.x, element.width);
        const y = centerCoordinate(element.y, element.height);
        if (x === undefined || y === undefined) {
          throw new Error(`元素缺少坐标：${element.path}`);
        }
        const result = await runWithRetry(runner, () => runAppleScript(runner, `tell application "System Events" to click at {${x}, ${y}}`));
        return buildActionResult('click_element', `已点击元素 ${element.name ?? element.role}（${element.path}）`, {
          path: element.path,
          name: element.name ?? '',
          role: element.role,
          x,
          y,
          attempts: result.attempts
        });
      }
    }),
    createExternalTool({
      name: 'computer_use.type_text',
      description: 'Type text into the current focused control.',
      parameters: z.object({
        text: z.string()
      }),
      handler: async params => {
        const result = await runWithRetry(runner, () =>
          runAppleScript(runner, `tell application "System Events" to keystroke "${escapeAppleScriptString(params.text)}"`)
        );
        return buildActionResult('type_text', `已输入 ${params.text.length} 个字符`, {
          characters: params.text.length,
          attempts: result.attempts
        });
      }
    }),
    createExternalTool({
      name: 'computer_use.press_key',
      description: 'Press a key or shortcut such as Enter, Tab, Escape, command+l.',
      parameters: z.object({
        key: z.string()
      }),
      handler: async params => {
        const script = buildKeyScript(params.key);
        const result = await runWithRetry(runner, () => runAppleScript(runner, script));
        return buildActionResult('press_key', `已按键 ${params.key}`, { key: params.key, attempts: result.attempts });
      }
    }),
    createExternalTool({
      name: 'computer_use.screenshot',
      description: 'Capture a screenshot of the current screen.',
      parameters: z.object({
        label: z.string().optional().default('capture')
      }),
      handler: async params => {
        const result = await runWithRetry(runner, () => captureScreenshot(runner, params.label));
        return buildActionResult('screenshot', `已保存截图：${result.value}`, { path: result.value, attempts: result.attempts });
      }
    })
  ];
}

export function buildComputerUseTextSummary(snapshot: ComputerUseSnapshot): string {
  const lines = [
    `前台应用：${snapshot.frontmostApp}`,
    snapshot.frontmostWindow ? `窗口：${snapshot.frontmostWindow}` : undefined,
    snapshot.windowBounds
      ? `窗口位置：${snapshot.windowBounds.x},${snapshot.windowBounds.y} · ${snapshot.windowBounds.width}×${snapshot.windowBounds.height}`
      : undefined,
    snapshot.screenshotPath ? `截图：${snapshot.screenshotPath}` : undefined,
    `可见元素：${snapshot.elements.length} 个`
  ].filter(Boolean) as string[];

  snapshot.elements.slice(0, 30).forEach((element, index) => {
    const details = [
      `${index + 1}.`,
      element.role,
      element.path ? `路径=${element.path}` : undefined,
      element.name ? `“${element.name}”` : undefined,
      element.value ? `值=${element.value}` : undefined,
      element.description ? `描述=${element.description}` : undefined,
      frameText(element)
    ].filter(Boolean).join(' ');
    lines.push(details);
  });

  if (snapshot.elements.length > 30) {
    lines.push(`... 还有 ${snapshot.elements.length - 30} 个元素`);
  }

  return lines.join('\n');
}

async function inspectFrontmostWindow(runner: ScriptRunner, maxDepth: number, maxItems: number): Promise<ComputerUseSnapshot> {
  const script = buildInspectScript(maxDepth, maxItems);
  const { stdout } = await runner.run('/usr/bin/osascript', ['-l', 'JavaScript', '-e', script]);
  const parsed = JSON.parse(stdout.trim()) as ComputerUseSnapshot;
  return parsed;
}

async function runAppleScript(runner: ScriptRunner, script: string): Promise<void> {
  await runner.run('/usr/bin/osascript', ['-e', script]);
}

async function captureScreenshot(runner: ScriptRunner, label: string): Promise<string> {
  await cleanUpStaleCaptures();
  const directory = await mkdtemp(join(tmpdir(), 'kimi-computer-use-'));
  const path = join(directory, `${sanitizeFileName(label)}.png`);
  await runner.run('/usr/sbin/screencapture', ['-x', path]);
  return path;
}

const staleCaptureAgeMs = 24 * 60 * 60 * 1000;

async function cleanUpStaleCaptures(): Promise<void> {
  const tmp = tmpdir();
  try {
    const entries = await readdir(tmp, { withFileTypes: true });
    const now = Date.now();
    for (const entry of entries) {
      if (!entry.isDirectory() || !entry.name.startsWith('kimi-computer-use-')) continue;
      const candidate = join(tmp, entry.name);
      try {
        const stats = await stat(candidate);
        if (now - stats.mtimeMs > staleCaptureAgeMs) {
          await rm(candidate, { recursive: true, force: true });
        }
      } catch {
        // 并发清理或已删除的目录可直接跳过。
      }
    }
  } catch {
    // 清理失败不应影响截图本身。
  }
}

async function runWithRetry<T>(runner: ScriptRunner, operation: () => Promise<T>, attempts = 2): Promise<{ value: T; attempts: number }> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return { value: await operation(), attempts: attempt };
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError ?? 'Computer Use action failed'));
}

function buildActionResult(action: string, message: string, details: Record<string, unknown>): ToolResult {
  const attempts = typeof details.attempts === 'number' ? details.attempts : undefined;
  return {
    output: JSON.stringify({ ok: true, action, ...details }),
    message: attempts && attempts > 1 ? `${message}（第 ${attempts} 次）` : message
  };
}

function centerCoordinate(origin: number | undefined, size: number | undefined): number | undefined {
  if (origin === undefined || size === undefined) return undefined;
  return Math.round(origin + size / 2);
}

function findTargetElement(
  snapshot: ComputerUseSnapshot,
  path?: string,
  name?: string,
  role?: string
): ComputerUseElement | undefined {
  if (path) {
    return snapshot.elements.find(element => element.path === path);
  }
  if (name) {
    return snapshot.elements.find(element => element.name === name);
  }
  if (role) {
    return snapshot.elements.find(element => element.role === role);
  }
  return snapshot.elements[0];
}

function buildInspectScript(maxDepth: number, maxItems: number): string {
  return `
ObjC.import('Foundation');
ObjC.import('ApplicationServices');
const app = Application('System Events');
const process = app.processes.whose({ frontmost: true })[0];

function safe(fn, fallback) {
  try {
    const value = fn();
    return value === undefined || value === null ? fallback : value;
  } catch (error) {
    return fallback;
  }
}

function asNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

function pointText(point) {
  if (!point) return undefined;
  const x = asNumber(point.x);
  const y = asNumber(point.y);
  if (x === undefined || y === undefined) return undefined;
  return { x, y };
}

function sizeText(size) {
  if (!size) return undefined;
  const width = asNumber(size.width);
  const height = asNumber(size.height);
  if (width === undefined || height === undefined) return undefined;
  return { width, height };
}

function isInteresting(role, name, value) {
  if (name || value) return true;
  return /Button|TextField|TextArea|Menu|MenuItem|CheckBox|RadioButton|Slider|Link|Tab|Row|Cell|StaticText|Image|SearchField|PopUpButton|ComboBox|ScrollArea|Outline|SplitGroup/i.test(role);
}

function walk(element, path, depth, results) {
  if (results.length >= ${maxItems}) return;
  const role = String(safe(() => element.role(), 'AXUnknown'));
  const name = safe(() => String(element.name()), '');
  const value = safe(() => String(element.value()), '');
  const description = safe(() => String(element.description()), '');
  const position = pointText(safe(() => element.position(), null));
  const size = sizeText(safe(() => element.size(), null));
  if (isInteresting(role, name, value)) {
    results.push({
      path,
      role,
      name: name || undefined,
      value: value || undefined,
      description: description || undefined,
      x: position?.x,
      y: position?.y,
      width: size?.width,
      height: size?.height
    });
  }
  if (depth >= ${maxDepth}) return;
  const children = safe(() => element.uiElements(), []);
  for (let index = 0; index < children.length && results.length < ${maxItems}; index++) {
    walk(children[index], path + '.' + index, depth + 1, results);
  }
}

const windows = safe(() => process.windows, []);
const frontWindow = windows.length > 0 ? windows[0] : null;
const elements = [];
if (frontWindow) {
  walk(frontWindow, '0', 0, elements);
}

const snapshot = {
  frontmostApp: safe(() => process.name(), 'unknown'),
  frontmostWindow: frontWindow ? safe(() => String(frontWindow.name()), '') : undefined,
  windowBounds: frontWindow
    ? (() => {
        const position = pointText(safe(() => frontWindow.position(), null));
        const size = sizeText(safe(() => frontWindow.size(), null));
        if (!position || !size) return undefined;
        return { x: position.x, y: position.y, width: size.width, height: size.height };
      })()
    : undefined,
  elements
};

console.log(JSON.stringify(snapshot));
`;
}

function buildKeyScript(rawKey: string): string {
  const parts = rawKey.split(/[+-]/).map(part => part.trim()).filter(Boolean);
  const key = parts.pop()?.toLowerCase() ?? rawKey.toLowerCase();
  const modifiers = parts.map(part => normalizeModifier(part)).filter(Boolean) as string[];
  const special = specialKeyCode(key);

  if (special !== undefined) {
    const modifierSuffix = modifiers.length > 0 ? ` using {${modifiers.map(m => `${m} down`).join(', ')}}` : '';
    return `tell application "System Events" to key code ${special}${modifierSuffix}`;
  }

  const modifierSuffix = modifiers.length > 0 ? ` using {${modifiers.map(m => `${m} down`).join(', ')}}` : '';
  return `tell application "System Events" to keystroke "${escapeAppleScriptString(key)}"${modifierSuffix}`;
}

function normalizeModifier(value: string): string | undefined {
  switch (value.toLowerCase()) {
    case 'command':
    case 'cmd':
    case 'super':
      return 'command';
    case 'option':
    case 'alt':
      return 'option';
    case 'shift':
      return 'shift';
    case 'control':
    case 'ctrl':
      return 'control';
    default:
      return undefined;
  }
}

function specialKeyCode(key: string): number | undefined {
  switch (key) {
    case 'enter':
    case 'return':
      return 36;
    case 'tab':
      return 48;
    case 'space':
      return 49;
    case 'backspace':
    case 'delete':
      return 51;
    case 'escape':
    case 'esc':
      return 53;
    case 'left':
      return 123;
    case 'right':
      return 124;
    case 'down':
      return 125;
    case 'up':
      return 126;
    case 'home':
      return 115;
    case 'end':
      return 119;
    case 'pageup':
      return 116;
    case 'pagedown':
      return 121;
    default:
      return undefined;
  }
}

function escapeAppleScriptString(value: string): string {
  return value
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r');
}

function frameText(element: ComputerUseElement): string | undefined {
  if (
    element.x === undefined ||
    element.y === undefined ||
    element.width === undefined ||
    element.height === undefined
  ) {
    return undefined;
  }
  return `@ ${Math.round(element.x)},${Math.round(element.y)} ${Math.round(element.width)}×${Math.round(element.height)}`;
}

function sanitizeFileName(value: string): string {
  const trimmed = value.trim().toLowerCase();
  const base = trimmed.length > 0 ? trimmed : 'capture';
  return base.replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'capture';
}
