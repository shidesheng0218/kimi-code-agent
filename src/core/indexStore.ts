// src/core/indexStore.ts

import { writeFile, readFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { CodebaseIndex } from './codebaseIndex.js';

const INDEX_DIR = '.kimi-agent/index';
const INDEX_FILE = 'codebase-index.json';

/**
 * 保存索引到磁盘
 */
export async function saveIndex(
  projectPath: string,
  index: CodebaseIndex
): Promise<void> {
  const indexDir = join(projectPath, INDEX_DIR);
  if (!existsSync(indexDir)) {
    await mkdir(indexDir, { recursive: true });
  }

  const indexPath = join(indexDir, INDEX_FILE);

  // 转换 Map 为普通对象以便序列化
  const serializable = {
    ...index,
    dependencies: Array.from(index.dependencies.entries()),
    symbols: Array.from(index.symbols.entries())
  };

  await writeFile(indexPath, JSON.stringify(serializable, null, 2), 'utf-8');
}

/**
 * 从磁盘加载索引
 */
export async function loadIndex(
  projectPath: string
): Promise<CodebaseIndex | null> {
  const indexPath = join(projectPath, INDEX_DIR, INDEX_FILE);

  if (!existsSync(indexPath)) {
    return null;
  }

  try {
    const content = await readFile(indexPath, 'utf-8');
    const data = JSON.parse(content);

    // 恢复 Map 对象
    return {
      ...data,
      dependencies: new Map(data.dependencies),
      symbols: new Map(data.symbols),
      lastIndexed: new Date(data.lastIndexed)
    };
  } catch (error) {
    console.error('Failed to load index:', error);
    return null;
  }
}

/**
 * 检查索引是否过期
 */
export function isIndexStale(index: CodebaseIndex, maxAgeHours: number = 24): boolean {
  const ageHours = (Date.now() - index.lastIndexed.getTime()) / (1000 * 60 * 60);
  return ageHours > maxAgeHours;
}
