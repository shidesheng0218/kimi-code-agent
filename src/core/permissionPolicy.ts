import path from 'node:path';

export type PermissionActionKind =
  | 'file-read'
  | 'file-write'
  | 'shell'
  | 'network'
  | 'credential'
  | 'extension-install';

export interface PermissionAction {
  kind: PermissionActionKind;
  workspaceRoot: string;
  path?: string;
  command?: string;
}

export interface PermissionEvaluation {
  decision: 'allow' | 'prompt' | 'deny';
  risk: 'low' | 'medium' | 'high' | 'critical';
  remember: 'task' | 'never';
  reason: string;
}

const rootDeletePattern = /^(?:sudo\s+)?rm\s+-[a-z]*r[a-z]*f[a-z]*\s+\/$/i;
const destructivePatterns = [
  /\bgit\s+reset\s+--hard\b/i,
  /\bgit\s+clean\s+-[^\s]*f/i,
  /\brm\s+-[^\s]*r[^\s]*f/i,
  /\bdiskutil\s+erase/i,
  /\bmkfs(?:\.|\s)/i,
  /\bdd\s+if=/i
];
const externalSideEffectPatterns = [
  /\bgit\s+push\b/i,
  /\bnpm\s+publish\b/i,
  /\bpnpm\s+publish\b/i,
  /\byarn\s+npm\s+publish\b/i,
  /\bkubectl\s+(?:apply|delete|replace)\b/i,
  /\bterraform\s+apply\b/i,
  /\bvercel\s+(?:deploy|--prod)\b/i
];

export function isPathInsideWorkspace(workspaceRoot: string, targetPath: string): boolean {
  const root = path.resolve(workspaceRoot);
  const target = path.resolve(targetPath);
  const relative = path.relative(root, target);

  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

export function evaluatePermission(action: PermissionAction): PermissionEvaluation {
  if (action.kind === 'file-read') {
    const inside = action.path ? isPathInsideWorkspace(action.workspaceRoot, action.path) : false;
    return inside
      ? { decision: 'allow', risk: 'low', remember: 'task', reason: '读取受信任工作区内的文件。' }
      : { decision: 'prompt', risk: 'critical', remember: 'never', reason: '读取工作区外文件或潜在凭据。' };
  }

  if (action.kind === 'file-write') {
    const inside = action.path ? isPathInsideWorkspace(action.workspaceRoot, action.path) : false;
    return inside
      ? { decision: 'prompt', risk: 'medium', remember: 'task', reason: '修改受信任工作区内的文件。' }
      : { decision: 'prompt', risk: 'critical', remember: 'never', reason: '准备向工作区外写入文件。' };
  }

  if (action.kind === 'credential') {
    return { decision: 'prompt', risk: 'critical', remember: 'never', reason: '请求访问敏感凭据。' };
  }

  if (action.kind === 'network') {
    return { decision: 'prompt', risk: 'high', remember: 'never', reason: '请求访问外部网络服务。' };
  }

  if (action.kind === 'extension-install') {
    return { decision: 'prompt', risk: 'high', remember: 'never', reason: '扩展可能执行本地代码。' };
  }

  const command = action.command?.trim() ?? '';
  if (rootDeletePattern.test(command)) {
    return { decision: 'deny', risk: 'critical', remember: 'never', reason: '拒绝递归删除文件系统根目录。' };
  }

  if (externalSideEffectPatterns.some(pattern => pattern.test(command))) {
    return { decision: 'prompt', risk: 'critical', remember: 'never', reason: '命令会产生远程或外部副作用。' };
  }

  if (destructivePatterns.some(pattern => pattern.test(command)) || /\bsudo\b/i.test(command)) {
    return { decision: 'prompt', risk: 'critical', remember: 'never', reason: '命令可能造成不可恢复的本地修改。' };
  }

  return { decision: 'prompt', risk: 'medium', remember: 'task', reason: '运行本地命令。' };
}
