# 动态任务规划功能使用指南

## 概述

动态任务规划是 Kimi Agent Desktop 的高级特性，使用 AI 智能分解复杂任务为可执行的子任务序列，类似于 Claude Code 的规划执行能力。

## 功能特点

- ✅ **AI 驱动分解**：自动将高层次目标拆分为具体步骤
- ✅ **依赖关系管理**：子任务按依赖顺序执行
- ✅ **隔离级别配置**：只读快照、共享工作区、独立 Worktree
- ✅ **失败回退**：动态规划失败时自动使用默认计划

## 启用方法

### 1. 配置 API 密钥

在应用中配置你的 Kimi API 密钥：
1. 打开 Kimi Agent Desktop
2. 进入设置（Cmd + ,）
3. 输入 Moonshot API Key
4. 保存

### 2. 启用动态规划

运行启用脚本：
```bash
cd /path/to/kimi-agent-desktop
./scripts/enable-dynamic-planning.sh
```

这会设置环境变量 `KIMI_DYNAMIC_PLANNING=1` 到系统全局环境。

### 3. 重启应用

完全退出应用（Cmd + Q），然后重新打开。

## 使用示例

### 示例 1：代码重构

**输入任务：**
```
重构 src/utils 目录下的工具函数，使用 TypeScript 严格类型
```

**动态规划可能生成：**
1. **explore-utils**: 分析现有工具函数结构（只读）
2. **plan-refactor**: 设计重构方案（只读）
3. **refactor-types**: 添加 TypeScript 类型定义（Worktree）
4. **test-refactor**: 验证重构后功能等价（只读）
5. **review-quality**: 代码质量审查（只读）

### 示例 2：新功能开发

**输入任务：**
```
实现用户登录功能，包括表单验证和 JWT 认证
```

**动态规划可能生成：**
1. **explore-auth**: 了解现有认证系统（只读）
2. **implement-backend**: 实现登录 API（Worktree）
3. **implement-frontend**: 实现登录表单（Worktree）
4. **test-integration**: 集成测试（只读）
5. **review-security**: 安全审查（只读）

### 示例 3：Bug 修复

**输入任务：**
```
修复用户无法上传大文件的问题
```

**动态规划可能生成：**
1. **explore-root-cause**: 定位 bug 根因（只读）
2. **implement-fix**: 实现修复（Worktree）
3. **test-regression**: 回归测试（只读）
4. **review-changes**: 审查变更（只读）

## 工作原理

```
用户输入任务
    ↓
检测 KIMI_DYNAMIC_PLANNING=1
    ↓
调用 DynamicPlanningBridge (Swift)
    ↓
启动 Node.js CLI 进程
    ↓
调用 Kimi API 生成结构化计划
    ↓
验证 JSON Schema
    ↓
转换为 AgentRun 列表
    ↓
按依赖顺序执行子任务
    ↓
显示执行结果
```

## 计划结构

动态生成的计划符合以下 JSON Schema：

```typescript
{
  summary: string,              // 一句话总结
  rationale: string,            // 为什么这样规划
  subtasks: [                   // 子任务列表
    {
      id: string,               // 唯一标识符
      title: string,            // 简短标题
      description: string,      // 详细描述
      agentKind: "explore" | "implement" | "test" | "review" | ...,
      dependencies: string[],   // 依赖的子任务 ID
      estimatedComplexity: "low" | "medium" | "high",
      toolsRequired: string[],  // 需要的工具
      isolation: "readOnlySnapshot" | "sharedWorkspace" | "worktree",
      acceptanceCriteria: string[],    // 验收标准
      verificationSteps: string[]      // 验证步骤
    }
  ],
  risks: string[],              // 潜在风险
  assumptions: string[]         // 假设前提
}
```

## 故障排查

### 问题 1：提示 "KIMI_API_KEY environment variable is required"

**原因**：API 密钥未配置或未正确读取

**解决方案**：
1. 检查应用设置中是否配置了 API 密钥
2. 重启应用使配置生效
3. 查看错误日志：`~/Library/Logs/Kimi Agent Desktop/app.log`

### 问题 2：动态规划失败，使用默认计划

**原因**：API 调用失败或返回格式错误

**解决方案**：
1. 检查网络连接
2. 确认 API 密钥有效
3. 查看错误详情（应用会显示具体错误信息）

### 问题 3：环境变量未生效

**原因**：未重启应用或 launchctl 设置失败

**解决方案**：
```bash
# 检查环境变量是否设置
launchctl getenv KIMI_DYNAMIC_PLANNING

# 手动设置
launchctl setenv KIMI_DYNAMIC_PLANNING 1

# 完全退出应用并重启
pkill -9 "Kimi Agent Desktop"
open "/Applications/Kimi Agent Desktop.app"
```

### 问题 4：CLI 进程错误

**原因**：打包文件损坏或路径错误

**解决方案**：
```bash
# 检查 CLI 文件是否存在
ls -lh "release-native/mac-arm64/Kimi Agent Desktop.app/Contents/Resources/KimiAgentDesktop_KimiAgentDesktop.bundle/Resources/dynamicPlanningCLI.bundle.cjs"

# 重新打包
npm run build:full
npm run native:package
```

## 禁用动态规划

如果需要禁用动态规划功能：

```bash
# 移除环境变量
launchctl unsetenv KIMI_DYNAMIC_PLANNING

# 重启应用
```

应用将回退到使用默认的 5 阶段固定计划。

## 性能影响

- **额外延迟**：约 2-5 秒（API 调用生成计划）
- **额外成本**：每次规划约消耗 1000-3000 tokens
- **内存开销**：约 50MB（Node.js 进程）

## 当前限制

⚠️ **注意**：此功能仍在开发中，存在以下限制：

1. **串行执行**：子任务按依赖顺序逐个执行，暂不支持并行
2. **手动验证**：需要用户手动检查执行结果
3. **基础错误处理**：失败后回退到默认计划，无自动重试
4. **macOS 专用**：仅支持 macOS 平台

## 未来改进

计划在后续版本中添加：

- [ ] 并行执行器（提升效率 2-3x）
- [ ] 自动验证（编译、测试、lint）
- [ ] 错误分析和自动重试
- [ ] 执行计划可视化
- [ ] Windows/Linux 支持

## 反馈和支持

遇到问题或有建议？

- 提交 Issue：https://github.com/your-repo/issues
- 查看日志：`~/Library/Logs/Kimi Agent Desktop/app.log`
- 社区讨论：（待建立）

## 参考资料

- [Claude Code 对比分析](./CLAUDE_CODE_COMPARISON.md)
- [实现状态文档](./DYNAMIC_PLANNING_STATUS.md)
- [技术架构](./docs/architecture.md)
