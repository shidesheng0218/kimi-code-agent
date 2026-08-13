// src/core/codebaseIndex.ts

import { readdir, stat, readFile } from 'node:fs/promises';
import { join, relative, extname, sep } from 'node:path';

export interface FileMetadata {
  path: string;
  type: 'source' | 'test' | 'config' | 'doc' | 'asset';
  language?: string;
  exports?: string[];
  imports?: string[];
  size: number;
  lastModified: Date;
}

export interface CodebaseIndex {
  rootPath: string;
  files: FileMetadata[];
  entryPoints: string[];
  testFiles: string[];
  configFiles: string[];
  dependencies: Map<string, string[]>;
  symbols: Map<string, string[]>;
  lastIndexed: Date;
}

const IGNORE_PATTERNS = [
  'node_modules',
  '.git',
  'dist',
  'build',
  'coverage',
  '.next',
  '.nuxt',
  'target',
  'out',
  '.DS_Store'
];

function isIgnoredPath(relativePath: string): boolean {
  const segments = relativePath.split(sep).filter(Boolean);
  return segments.some(segment => IGNORE_PATTERNS.includes(segment));
}

const SOURCE_EXTENSIONS = ['.ts', '.tsx', '.js', '.jsx', '.py', '.java', '.go', '.rs', '.c', '.cpp', '.h'];
const TEST_PATTERNS = ['.test.', '.spec.', '__tests__', '__test__'];
const CONFIG_FILES = ['package.json', 'tsconfig.json', 'vite.config', 'webpack.config', 'rollup.config'];

/**
 * 扫描目录中的所有文件
 */
async function scanFiles(rootPath: string): Promise<FileMetadata[]> {
  const files: FileMetadata[] = [];

  async function scan(dir: string): Promise<void> {
    try {
      const entries = await readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = join(dir, entry.name);
        const relativePath = relative(rootPath, fullPath);

        // 跳过忽略的目录（按路径段精确匹配，避免误伤同名文件）
        if (isIgnoredPath(relativePath)) {
          continue;
        }

        if (entry.isDirectory()) {
          await scan(fullPath);
        } else if (entry.isFile()) {
          const stats = await stat(fullPath);
          const ext = extname(entry.name);

          // 分类文件
          let type: FileMetadata['type'] = 'asset';
          let language: string | undefined;

          if (SOURCE_EXTENSIONS.includes(ext)) {
            type = TEST_PATTERNS.some(p => entry.name.includes(p)) ? 'test' : 'source';
            language = inferLanguage(ext);
          } else if (CONFIG_FILES.some(c => entry.name.includes(c))) {
            type = 'config';
          } else if (['.md', '.txt', '.pdf'].includes(ext)) {
            type = 'doc';
          }

          files.push({
            path: relativePath,
            type,
            language,
            size: stats.size,
            lastModified: stats.mtime
          });
        }
      }
    } catch (error) {
      // 忽略访问错误（权限问题等）
    }
  }

  await scan(rootPath);
  return files;
}

function inferLanguage(ext: string): string {
  const map: Record<string, string> = {
    '.ts': 'typescript',
    '.tsx': 'typescript',
    '.js': 'javascript',
    '.jsx': 'javascript',
    '.py': 'python',
    '.java': 'java',
    '.go': 'go',
    '.rs': 'rust',
    '.c': 'c',
    '.cpp': 'cpp'
  };
  return map[ext] || 'unknown';
}

/**
 * 解析项目元数据
 */
async function parseProjectMetadata(rootPath: string): Promise<{
  entryPoints: string[];
  projectType?: string;
}> {
  const entryPoints: string[] = [];
  let projectType: string | undefined;

  try {
    // 尝试读取 package.json
    const packageJsonPath = join(rootPath, 'package.json');
    const packageJson = JSON.parse(await readFile(packageJsonPath, 'utf-8'));

    projectType = 'node';

    // 提取入口点
    if (packageJson.main) {
      entryPoints.push(packageJson.main);
    }
    if (packageJson.module) {
      entryPoints.push(packageJson.module);
    }
  } catch {
    // package.json 不存在
  }

  // 通用入口点
  const commonEntries = ['index.ts', 'index.js', 'src/index.ts', 'src/main.ts', 'main.ts'];
  for (const entry of commonEntries) {
    try {
      await stat(join(rootPath, entry));
      if (!entryPoints.includes(entry)) {
        entryPoints.push(entry);
      }
    } catch {
      // 文件不存在
    }
  }

  return { entryPoints, projectType };
}

/**
 * 提取符号（函数、类、类型等）
 */
async function extractSymbols(files: FileMetadata[], rootPath: string): Promise<Map<string, string[]>> {
  const symbols = new Map<string, string[]>();

  for (const file of files) {
    if (file.type !== 'source') continue;
    if (!file.language || !['typescript', 'javascript'].includes(file.language)) continue;

    try {
      const content = await readFile(join(rootPath, file.path), 'utf-8');
      const fileSymbols = extractTSSymbols(content);

      for (const symbol of fileSymbols) {
        const files = symbols.get(symbol) || [];
        files.push(file.path);
        symbols.set(symbol, files);
      }

      // 反向索引：文件 → 符号
      if (fileSymbols.length > 0) {
        symbols.set(`file:${file.path}`, fileSymbols);
      }
    } catch {
      // 读取失败，跳过
    }
  }

  return symbols;
}

/**
 * 简单的 TypeScript/JavaScript 符号提取
 */
function extractTSSymbols(content: string): string[] {
  const symbols: string[] = [];

  // 函数声明
  const functionRegex = /(?:export\s+)?(?:async\s+)?function\s+(\w+)/g;
  let match;
  while ((match = functionRegex.exec(content)) !== null) {
    symbols.push(match[1]);
  }

  // 类声明
  const classRegex = /(?:export\s+)?class\s+(\w+)/g;
  while ((match = classRegex.exec(content)) !== null) {
    symbols.push(match[1]);
  }

  // 接口/类型声明
  const typeRegex = /(?:export\s+)?(?:interface|type)\s+(\w+)/g;
  while ((match = typeRegex.exec(content)) !== null) {
    symbols.push(match[1]);
  }

  // const/let 导出
  const constRegex = /export\s+(?:const|let)\s+(\w+)/g;
  while ((match = constRegex.exec(content)) !== null) {
    symbols.push(match[1]);
  }

  return symbols;
}

/**
 * 构建依赖图
 */
async function buildDependencyGraph(files: FileMetadata[], rootPath: string): Promise<Map<string, string[]>> {
  const graph = new Map<string, string[]>();

  for (const file of files) {
    if (file.type !== 'source') continue;
    if (!file.language || !['typescript', 'javascript'].includes(file.language)) continue;

    try {
      const content = await readFile(join(rootPath, file.path), 'utf-8');
      const imports = extractImports(content);

      if (imports.length > 0) {
        graph.set(file.path, imports);
      }
    } catch {
      // 读取失败，跳过
    }
  }

  return graph;
}

/**
 * 提取 import 语句
 */
function extractImports(content: string): string[] {
  const imports: string[] = [];

  // ES6 imports
  const importRegex = /import\s+.*?\s+from\s+['"]([^'"]+)['"]/g;
  let match;
  while ((match = importRegex.exec(content)) !== null) {
    imports.push(match[1]);
  }

  // require
  const requireRegex = /require\s*\(\s*['"]([^'"]+)['"]\s*\)/g;
  while ((match = requireRegex.exec(content)) !== null) {
    imports.push(match[1]);
  }

  return imports;
}

/**
 * 构建完整的代码库索引
 */
export async function buildCodebaseIndex(
  rootPath: string,
  existingIndex?: CodebaseIndex
): Promise<CodebaseIndex> {
  console.log(`Building codebase index for: ${rootPath}`);

  // 1. 扫描文件树
  const files = await scanFiles(rootPath);
  console.log(`Found ${files.length} files`);

  // 2. 解析项目元数据
  const projectMeta = await parseProjectMetadata(rootPath);

  // 3. 提取符号
  const symbols = await extractSymbols(files, rootPath);
  console.log(`Extracted ${symbols.size} symbols`);

  // 4. 构建依赖图
  const dependencies = await buildDependencyGraph(files, rootPath);
  console.log(`Built dependency graph with ${dependencies.size} nodes`);

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
 * 智能文件选择
 */
export function selectRelevantFiles(
  index: CodebaseIndex,
  userGoal: string,
  maxFiles: number = 10
): string[] {
  const scores = new Map<string, number>();

  // 提取关键词
  const keywords = extractKeywords(userGoal);

  for (const file of index.files) {
    if (file.type === 'asset') continue;

    let score = 0;

    // 1. 路径匹配
    for (const keyword of keywords) {
      if (file.path.toLowerCase().includes(keyword.toLowerCase())) {
        score += 3;
      }
    }

    // 2. 符号匹配
    const fileSymbols = index.symbols.get(`file:${file.path}`) || [];
    for (const keyword of keywords) {
      for (const symbol of fileSymbols) {
        if (symbol.toLowerCase().includes(keyword.toLowerCase())) {
          score += 5;
        }
      }
    }

    // 3. 最近修改的文件
    const daysSinceModified = (Date.now() - file.lastModified.getTime()) / (1000 * 60 * 60 * 24);
    if (daysSinceModified < 7) {
      score += 2;
    }

    // 4. 入口文件
    if (index.entryPoints.includes(file.path)) {
      score += 4;
    }

    // 5. 配置文件（重要）
    if (file.type === 'config') {
      score += 3;
    }

    if (score > 0) {
      scores.set(file.path, score);
    }
  }

  // 排序并返回 top-k
  return [...scores.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, maxFiles)
    .map(([path]) => path);
}

function extractKeywords(text: string): string[] {
  const stopWords = ['the', 'and', 'for', 'with', 'this', 'that', 'from', 'to', 'in', 'on', 'at'];

  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, ' ')
    .split(/\s+/)
    .filter(word => word.length > 2)
    .filter(word => !stopWords.includes(word));
}

/**
 * 生成项目摘要
 */
export function generateProjectSummary(index: CodebaseIndex): string {
  const parts: string[] = [];

  // 项目类型检测
  const hasPackageJson = index.files.some(f => f.path.endsWith('package.json'));
  if (hasPackageJson) {
    parts.push('📦 Node.js/TypeScript 项目');
  }

  // 统计信息
  const sourceCount = index.files.filter(f => f.type === 'source').length;
  const testCount = index.testFiles.length;
  const configCount = index.configFiles.length;

  parts.push(`\n📊 文件统计：`);
  parts.push(`  - 源码文件：${sourceCount} 个`);
  parts.push(`  - 测试文件：${testCount} 个`);
  parts.push(`  - 配置文件：${configCount} 个`);

  // 入口点
  if (index.entryPoints.length > 0) {
    parts.push(`\n🚀 入口文件：${index.entryPoints.join(', ')}`);
  }

  // 最近修改
  const recentFiles = [...index.files]
    .sort((a, b) => b.lastModified.getTime() - a.lastModified.getTime())
    .slice(0, 5)
    .map(f => f.path);

  if (recentFiles.length > 0) {
    parts.push(`\n🕒 最近修改：`);
    recentFiles.forEach(f => parts.push(`  - ${f}`));
  }

  return parts.join('\n');
}
