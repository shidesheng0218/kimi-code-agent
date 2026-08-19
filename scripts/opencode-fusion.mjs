import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const rootDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const foundationDirectory = path.join(rootDirectory, 'vendor', 'opencode');
const applicationSupportDirectory = process.env.KIMI_APPLICATION_SUPPORT_DIR
  ?? path.join(process.env.HOME ?? '', 'Library', 'Application Support', 'Kimi Code Agent');
const bunVersion = '1.3.14';

function requireFoundation() {
  const packageFile = path.join(foundationDirectory, 'packages', 'opencode', 'package.json');
  const kimiPrompt = path.join(foundationDirectory, 'packages', 'opencode', 'src', 'session', 'prompt', 'kimi.txt');
  if (!existsSync(packageFile) || !existsSync(kimiPrompt)) {
    throw new Error('OpenCode 运行时不完整。请重新拉取包含 vendor/opencode 的项目源码。');
  }
}

async function prepareProfile() {
  const moduleURL = pathToFileURL(path.join(rootDirectory, 'dist', 'src', 'opencode', 'prepareFusion.js')).href;
  const { prepareOpenCodeFusionConfig } = await import(moduleURL);
  const prepared = await prepareOpenCodeFusionConfig({
    applicationSupportDirectory,
    baseURL: process.env.KIMI_BASE_URL,
    modelID: process.env.KIMI_MODEL ?? 'kimi-k2.7-code'
  });
  return prepared;
}

function readKimiAPIKey() {
  const fromEnvironment = process.env.KIMI_API_KEY?.trim();
  if (fromEnvironment) return fromEnvironment;

  try {
    const value = execFileSync(
      '/usr/bin/security',
      ['find-generic-password', '-s', 'com.kimicode.agent.native', '-a', 'kimi.runtime.identity.apiKey', '-w'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    ).trim();
    if (value) return value;
  } catch {}

  throw new Error('没有可用的 Kimi API Key。请在 Kimi Code Agent 保存 Key，或仅对本次启动设置 KIMI_API_KEY。');
}

async function launchEnvironment(requireAPIKey) {
  const { createOpenCodeLaunchEnvironment, resolveOpenCodeFoundationPaths } = await import(
    pathToFileURL(path.join(rootDirectory, 'dist', 'src', 'opencode', 'openCodeFusion.js')).href
  );
  const paths = resolveOpenCodeFoundationPaths(rootDirectory);
  if (!existsSync(paths.nativePluginFile)) {
    throw new Error('Kimi OpenCode 原生插件缺失。请重新拉取完整项目源码。');
  }
  const environment = createOpenCodeLaunchEnvironment(process.env, applicationSupportDirectory);
  environment.KIMI_OPENCODE_PLUGIN = pathToFileURL(paths.nativePluginFile).href;
  if (requireAPIKey) environment.KIMI_API_KEY = readKimiAPIKey();
  return environment;
}

function run(command, args, environment = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: rootDirectory, env: environment, stdio: 'inherit' });
    child.once('error', reject);
    child.once('exit', code => {
      if (code === 0) return resolve();
      reject(new Error(`${command} exited with ${code ?? 'unknown'}`));
    });
  });
}

async function nativeBridgePath() {
  const configured = process.env.KIMI_NATIVE_BRIDGE?.trim();
  if (configured && existsSync(configured)) return configured;
  await run('swift', ['build', '--package-path', 'macos', '--product', 'KimiNativeBridge']);
  const binaryDirectory = execFileSync('swift', ['build', '--package-path', 'macos', '--show-bin-path'], {
    cwd: rootDirectory,
    encoding: 'utf8',
  }).trim();
  const bridge = path.join(binaryDirectory, 'KimiNativeBridge');
  if (!existsSync(bridge)) throw new Error('KimiNativeBridge build completed without producing an executable.');
  return bridge;
}

function runBun(args, environment) {
  return new Promise((resolve, reject) => {
    const child = spawn('npx', ['--yes', `bun@${bunVersion}`, ...args], {
      cwd: foundationDirectory,
      env: environment,
      stdio: 'inherit'
    });
    child.once('error', reject);
    child.once('exit', code => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`OpenCode 命令退出，状态码：${code ?? 'unknown'}`));
    });
  });
}

async function main() {
  const command = process.argv[2] ?? 'help';
  requireFoundation();

  if (command === 'install') {
    await runBun(['install', '--frozen-lockfile'], await launchEnvironment(false));
    return;
  }

  if (command === 'prepare') {
    const prepared = await prepareProfile();
    process.stdout.write(`OpenCode Kimi 配置已写入：${prepared.configFile}\n`);
    return;
  }

  if (command === 'dev' || command === 'package') {
    throw new Error('OpenCode Desktop / Electron 已退出生产路径。请使用 SwiftUI 的 npm run native:build 或 npm run native:package。');
  }

  throw new Error('用法：node scripts/opencode-fusion.mjs <install|prepare|dev|package>');
}

main().catch(error => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
