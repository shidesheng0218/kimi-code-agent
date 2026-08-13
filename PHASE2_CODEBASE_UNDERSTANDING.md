# Phase 2: 代码库上下文理解实现方案

## 问题分析

Claude Code 的强大之处在于它能"理解"整个代码库：
- 自动发现关键文件和模块
- 语义检索（而不仅是文本匹配）
- 理解代码依赖关系
- 记住项目约定和模式

当前项目只有基础的 token 压缩（ContextProjector），不足以处理大型代码库。

## 解决方案

### 2.1 轻量级代码库索引

**不使用向量数据库**（保持本地优先），而是构建结构化索引：

```typescript
// src/core/codebaseIndex.ts

export interface FileMetadata {
  path: string;
  type: 'source' | 'test' | 'config' | 'doc' | 'asset';
  language?: string;
  exports?: string[];  // 导出的函数、类、类型
  imports?: string[];  // 导入的模块
  size: number;
  lastModified: Date;
}

export interface CodebaseIndex {
  rootPath: string;
  files: FileMetadata[];
  entryPoints: string[];  // package.json main, index.ts 等
  testFiles: string[];
  configFiles: string[];
  dependencies: Map<string, string[]>;  // 文件依赖图
  symbols: Map<string, string[]>;  // 符号 → 文件映射
  lastIndexed: Date;
}

/**
 * 构建代码库索引（增量更新）
 */
export async function buildCodebaseIndex(
  rootPath: string,
  existingIndex?: CodebaseIndex
): Promise<CodebaseIndex> {
  // 1. 扫描文件树
  const files = await scanFiles(rootPath);
  
  // 2. 解析关键文件（package.json, tsconfig.json 等）
  const projectMeta = await parseProjectMetadata(rootPath);
  
  // 3. 提取符号（函数、类、类型等）
  const symbols = await extractSymbols(files);
  
  // 4. 构建依赖图
  const dependencies = await buildDependencyGraph(files);
  
  return {
    rootPath,
    files,
    entryPoints: projectMeta.entryPoints,
    testFiles: files.filter(f => f.type === 'test').map(f => f.path),
    configFiles: files.filter(f => f.type === 'config').map(f => f.path),
    dependencies,
    symbols,
    lastIndexed: new Date()
  };
}

/**
 * 智能文件选择：给定用户目标，返回最相关的文件
 */
export function selectRelevantFiles(
  index: CodebaseIndex,
  userGoal: string,
  maxFiles: number = 10
): string[] {
  const scores = new Map<string, number>();
  
  // 1. 关键词匹配
  const keywords = extractKeywords(userGoal);
  for (const file of index.files) {
    let score = 0;
    for (const keyword of keywords) {
      if (file.path.toLowerCase().includes(keyword.toLowerCase())) {
        score += 3;
      }
      if (file.exports?.some(exp => exp.toLowerCase().includes(keyword.toLowerCase()))) {
        score += 5;
      }
    }
    scores.set(file.path, score);
  }
  
  // 2. 最近修改的文件（可能相关）
  const recentFiles = [...index.files]
    .sort((a, b) => b.lastModified.getTime() - a.lastModified.getTime())
    .slice(0, 5);
  for (const file of recentFiles) {
    scores.set(file.path, (scores.get(file.path) ?? 0) + 2);
  }
  
  // 3. 入口文件和配置文件（重要）
  for (const entry of index.entryPoints) {
    scores.set(entry, (scores.get(entry) ?? 0) + 4);
  }
  
  // 4. 排序并返回 top-k
  return [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, maxFiles)
    .map(([path]) => path);
}

/**
 * 生成项目摘要（用于 Plan Agent）
 */
export function generateProjectSummary(index: CodebaseIndex): string {
  const parts: string[] = [];
  
  // 项目类型
  const hasPackageJson = index.files.some(f => f.path.endsWith('package.json'));
  const hasPomXml = index.files.some(f => f.path.endsWith('pom.xml'));
  if (hasPackageJson) parts.push('Node.js/TypeScript 项目');
  else if (hasPomXml) parts.push('Java/Maven 项目');
  
  // 框架检测
  const packageJson = index.files.find(f => f.path.endsWith('package.json'));
  if (packageJson) {
    // 读取 dependencies（需要实际实现）
    // 检测 React、Vue、Express 等
  }
  
  // 目录结构
  parts.push(`\n文件结构：`);
  parts.push(`- 源码文件：${index.files.filter(f => f.type === 'source').length} 个`);
  parts.push(`- 测试文件：${index.testFiles.length} 个`);
  parts.push(`- 配置文件：${index.configFiles.length} 个`);
  
  // 入口点
  if (index.entryPoints.length > 0) {
    parts.push(`\n入口文件：${index.entryPoints.join(', ')}`);
  }
  
  return parts.join('\n');
}

function extractKeywords(text: string): string[] {
  // 简单的关键词提取（可以用更复杂的 NLP）
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, ' ')
    .split(/\s+/)
    .filter(word => word.length > 3)
    .filter(word => !['the', 'and', 'for', 'with', 'this', 'that'].includes(word));
}
```

### 2.2 集成到 Explore Agent

```typescript
// src/runtime/exploreAgent.ts

import { buildCodebaseIndex, selectRelevantFiles, generateProjectSummary } from '../core/codebaseIndex.js';

/**
 * Explore Agent 的增强提示词
 */
export async function buildExplorePrompt(
  userGoal: string,
  projectPath: string
): Promise<string> {
  // 1. 构建或加载索引
  const index = await buildCodebaseIndex(projectPath);
  
  // 2. 生成项目摘要
  const summary = generateProjectSummary(index);
  
  // 3. 选择相关文件
  const relevantFiles = selectRelevantFiles(index, userGoal, 10);
  
  return `
你是一个代码库探索 Agent。你的任务是帮助后续 Agent 理解项目结构和相关代码。

## 项目概览
${summary}

## 用户目标
${userGoal}

## 建议优先查看的文件
${relevantFiles.map(f => `- ${f}`).join('\n')}

## 你的任务
1. 使用 Read 工具读取最相关的 3-5 个文件
2. 总结现有实现模式和约定
3. 识别需要修改或扩展的关键模块
4. 标注潜在的依赖和风险点

请输出结构化的探索报告：
\`\`\`json
{
  "keyFiles": ["path/to/file1.ts", "path/to/file2.ts"],
  "existingPatterns": ["描述现有的代码模式"],
  "modulesToModify": ["需要修改的模块"],
  "dependencies": ["相关依赖"],
  "risks": ["潜在风险"],
  "recommendations": ["给后续 Agent 的建议"]
}
\`\`\`
`;
}
```

### 2.3 持久化索引

```typescript
// src/core/indexStore.ts

import { writeFile, readFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { CodebaseIndex } from './codebaseIndex.js';

const INDEX_DIR = '.kimi-agent/index';
const INDEX_FILE = 'codebase-index.json';

export async function saveIndex(
  projectPath: string,
  index: CodebaseIndex
): Promise<void> {
  const indexDir = join(projectPath, INDEX_DIR);
  if (!existsSync(indexDir)) {
    await mkdir(indexDir, { recursive: true });
  }
  
  const indexPath = join(indexDir, INDEX_FILE);
  await writeFile(indexPath, JSON.stringify(index, null, 2), 'utf-8');
}

export async function loadIndex(
  projectPath: string
): Promise<CodebaseIndex | null> {
  const indexPath = join(projectPath, INDEX_DIR, INDEX_FILE);
  if (!existsSync(indexPath)) {
    return null;
  }
  
  try {
    const content = await readFile(indexPath, 'utf-8');
    return JSON.parse(content) as CodebaseIndex;
  } catch {
    return null;
  }
}

/**
 * 增量更新索引（只重新扫描修改的文件）
 */
export async function updateIndex(
  projectPath: string,
  changedFiles?: string[]
): Promise<CodebaseIndex> {
  const existing = await loadIndex(projectPath);
  
  if (!existing || !changedFiles) {
    // 全量重建
    const index = await buildCodebaseIndex(projectPath);
    await saveIndex(projectPath, index);
    return index;
  }
  
  // 增量更新（实现细节省略）
  // ...
  
  return existing;
}
```

## 使用示例

```typescript
// 在任务开始时
const index = await buildCodebaseIndex('/path/to/project');
await saveIndex('/path/to/project', index);

// Explore Agent 运行时
const explorePrompt = await buildExplorePrompt(
  '添加用户认证功能',
  '/path/to/project'
);

// 后续 Agent 可以复用索引
const relevantFiles = selectRelevantFiles(index, '修改登录逻辑', 5);
```

## 性能指标

- **索引构建时间**：< 5s（10,000 文件）
- **增量更新**：< 500ms（100 个文件变更）
- **文件选择**：< 50ms
- **索引大小**：< 5MB（10,000 文件）

## 后续优化

1. **语义检索**：集成轻量级嵌入模型（如 ONNX 版本的 MiniLM）
2. **AST 解析**：更准确的符号提取
3. **Git 历史分析**：识别频繁修改的文件（热点文件）
4. **智能缓存**：基于 Git commit hash 的缓存失效
