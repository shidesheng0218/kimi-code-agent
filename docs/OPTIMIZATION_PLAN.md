# Kimi Code Agent 优化实施方案

更新日期：2026-09-30
适用版本：0.4.0

## 1. 产品判断

Kimi Code Agent 已具备 macOS 原生、本地优先 Coding Agent 工作台的核心骨架：会话、终端、Diff、权限模式、附件、Worktree、PR/CI、MCP、浏览器验证、Computer Use、子会话与重启恢复。

下一阶段不以继续堆叠功能为主，而是将已有能力收敛为一条可信的任务闭环：

> **Plan → Execute → Verify → Review → Deliver**

产品不应短期定位为“另一个 Cursor”，而应突出：

> **本地优先、可扩展、可审计、可恢复的 Agent 工作台。**

## 2. 优先级

### P0：可靠性、信任与首次成功

- 真实 Kimi API、MCP、Git/Worktree、浏览器与 Computer Use 验收。
- 统一任务状态、失败分类与恢复动作。
- 完善权限分级、Diff 预览、回滚和磁盘冲突处理。
- 对 Endpoint、API Key、Web Search、MCP、gh 等依赖提供可操作诊断。

### P1：任务闭环与开发者效率

- 自动生成验证计划并关联测试、构建、Lint、Diff 与 CI。
- 让 Files、Diff、Terminal、PR/CI 和最终摘要共享同一任务上下文。
- 增加修复测试、代码审查、重构、文档生成和创建 PR 等任务模板。

### P2：生态、自动化与团队能力

- 插件/MCP/Skill 的健康、权限与版本管理。
- 多 Agent 编排、预算控制、团队共享 Skill 和审计日志。
- 远程 MCP OAuth 与本地/云端混合执行。

## 3. 统一任务模型

建议在现有状态、Intent、Receipt 和恢复机制上扩展，不新建平行运行时：

- TaskRun：一次用户目标的完整运行。
- TaskStep：可重试、可审计的最小步骤，包含稳定 ID 和幂等键。
- TaskArtifact：Diff、截图、日志、报告、PR 等产物。
- VerificationResult：测试、构建、Lint、CI 或人工确认结果。
- RecoveryAction：继续、重试当前步骤、回滚、清理或放弃。

统一阶段：

planned → awaitingApproval → executing → verifying → reviewing → completed

异常状态：failedRecoverable、suspended、cancelled。

每个任务结束必须回答五个问题：

1. Agent 做了什么？
2. 哪些文件发生了变化？
3. 验证做了什么、结果如何？
4. 还有哪些风险或未完成项？
5. 用户下一步可以做什么？

## 4. 安全与权限

权限分为四级：

1. **只读**：搜索、读取、分析。
2. **工作区写入**：仅修改授权目录内文件。
3. **外部副作用**：安装依赖、网络发布、Git push、PR 操作。
4. **系统级**：屏幕控制、辅助功能和系统设置。

高风险操作必须显示：动作、原因、影响范围、预计变更、撤销方式。所有写入均应关联任务、步骤和授权记录；拒绝权限应进入可继续状态，不应被归类为普通失败。

## 5. 迭代顺序

### Phase 0：基线与问题收敛（3–5 天）

- 冻结当前版本行为。
- 运行现有 TypeScript、Swift CoreChecks、单元测试和打包检查。
- 建立黄金任务并记录完成率、耗时、人工干预、验证通过率和失败类型。
- 盘点任务状态、权限决策、Receipt/Intent、错误类型和 UI 展示路径。

### Phase 1：可靠性与信任（1–2 周）

- 统一状态和恢复 UI。
- 完成权限分级、变更批次、回滚和冲突处理。
- 增加 Provider、Endpoint、Web Search、MCP 和 GitHub 依赖诊断。
- 完成真实 API 与故障注入验收。

### Phase 2：任务闭环（1–2 周）

- 打通验证计划、测试反馈、Diff Review、PR/CI 和交付摘要。
- 增加一键继续、修复、验证、创建 PR、导出报告。
- 完善 Files、Diff、Terminal 之间的上下文联动。

### Phase 3：首次体验与生态... (line truncated to 2000 chars)