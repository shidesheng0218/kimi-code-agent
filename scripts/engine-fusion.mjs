#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const rootDirectory = path.resolve(scriptDirectory, '..');

async function loadEngineFusionModule() {
  const moduleURL = pathToFileURL(path.join(rootDirectory, 'dist', 'src', 'engine', 'engineFusion.js')).href;
  return import(moduleURL);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? rootDirectory,
    env: options.env ?? process.env,
    stdio: 'inherit',
    shell: false
  });

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} exited with ${result.status ?? 'unknown status'}`);
  }
}

function launchEnvironment(paths, inheritEnvironment = true) {
  const base = inheritEnvironment ? process.env : {};
  return {
    ...base,
    OPENCODE_CLIENT: 'kimi-code-agent',
    KIMI_RUNTIME_PLUGIN: pathToFileURL(paths.nativePluginFile).href
  };
}

async function installFoundation(paths) {
  if (!fs.existsSync(paths.nativePluginFile)) {
    throw new Error(`Missing Kimi native adapter plugin at ${paths.nativePluginFile}`);
  }
  run('bun', ['install', '--frozen-lockfile'], {
    cwd: paths.foundationDirectory,
    env: launchEnvironment(paths)
  });
}

async function main() {
  const { resolveEngineFoundationPaths } = await loadEngineFusionModule();
  const command = process.argv[2] ?? 'install';
  const paths = resolveEngineFoundationPaths(rootDirectory);

  if (command === 'install') {
    await installFoundation(paths);
    return;
  }

  if (command === 'dev' || command === 'package') {
    throw new Error('Legacy desktop fusion is retired: the engine is served by the KimiCodeAgent SwiftUI shell. Use `npm run native:build` or `npm run native:package`.');
  }

  throw new Error(`Unknown command "${command}". Usage: node scripts/engine-fusion.mjs <install>`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
