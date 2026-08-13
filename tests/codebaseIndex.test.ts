// tests/codebaseIndex.test.ts

import { describe, it, expect } from 'vitest';
import { selectRelevantFiles, generateProjectSummary } from '../src/core/codebaseIndex.js';
import type { CodebaseIndex } from '../src/core/codebaseIndex.js';

describe('CodebaseIndex', () => {
  const mockIndex: CodebaseIndex = {
    rootPath: '/test/project',
    files: [
      {
        path: 'src/auth/login.ts',
        type: 'source',
        language: 'typescript',
        size: 1000,
        lastModified: new Date('2024-01-01')
      },
      {
        path: 'src/auth/register.ts',
        type: 'source',
        language: 'typescript',
        size: 1200,
        lastModified: new Date('2024-01-02')
      },
      {
        path: 'src/utils/helper.ts',
        type: 'source',
        language: 'typescript',
        size: 500,
        lastModified: new Date('2024-01-03')
      }
    ],
    entryPoints: ['src/index.ts'],
    testFiles: [],
    configFiles: ['package.json'],
    dependencies: new Map(),
    symbols: new Map([
      ['file:src/auth/login.ts', ['login', 'validateCredentials']],
      ['file:src/auth/register.ts', ['register', 'createUser']]
    ]),
    lastIndexed: new Date()
  };

  it('should select relevant files based on keywords', () => {
    const files = selectRelevantFiles(mockIndex, '修复登录功能', 5);

    expect(files).toContain('src/auth/login.ts');
    expect(files.length).toBeLessThanOrEqual(5);
  });

  it('should generate project summary', () => {
    const summary = generateProjectSummary(mockIndex);

    expect(summary).toContain('Node.js/TypeScript 项目');
    expect(summary).toContain('源码文件：3 个');
  });
});
