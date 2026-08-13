import { chmodSync, existsSync } from 'node:fs';
import path from 'node:path';

export type FileExists = (candidate: string) => boolean;

export function resolveKimiExecutable(
  configuredPath: string,
  extensionPath: string,
  fileExists: FileExists = existsSync
): string {
  const configured = configuredPath.trim();
  if (configured && configured !== 'managed') {
    return configured;
  }

  const managedPath = path.join(extensionPath, 'dist', 'runtime', 'kimi.mjs');
  return fileExists(managedPath) ? managedPath : 'kimi';
}

export function ensureExecutablePermissions(executablePath: string): void {
  if (process.platform !== 'win32' && path.isAbsolute(executablePath)) {
    chmodSync(executablePath, 0o755);
  }
}
