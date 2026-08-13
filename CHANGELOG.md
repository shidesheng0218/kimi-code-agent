# Changelog

## 0.4.0 - 2026-08-10

- 增加 SessionKernel：SessionRecord、MessagePart、RuntimeEvent、SessionEventStore 和 SessionProjector。
- 新任务与桌面事件追加到本地 `session-events.jsonl`，支持序号校验和回放。
- 增加 ChildSessionCoordinator，为真实独立 Kimi 子会话、前台/后台执行和恢复提供统一接口。
- 增加 ToolRegistry / ToolCatalog，统一工具元数据、Agent 工具过滤和 Prompt 工具清单。
- 增加可持久化 Agent Run 编排图：Explore、Plan、Implement、Test、Review 与自定义 Agent。
- 任务创建、暂停、取消、失败、验证和合并会同步更新 Agent Run 状态，重启后恢复中断节点。
- 增加项目级 `AGENTS.md` / `.kimi-agent/rules.md` 规则发现，并注入真实 Runtime Prompt。
- 增加 Kimi Plugin 清单发现、能力预览和插件内 Skills 发现。
- 增加会话级 Workspace Layout 持久化与可恢复 Pane 配置。
- 增加可持久化 Capability Grant 模型，为 Agent、插件和扩展的最小权限授权提供统一边界。
- 主对话和 Inspector 增加 Agent 执行阶段、状态和布局信息。

## 0.1.0 - 2026-08-06

- 建立 Kimi Agent Desktop 核心扩展。
- 增加任务工作台、任务模式和持久状态。
- 接入 Kimi Agent SDK 和内置 Kimi Code CLI。
- 增加 OAuth 登录、运行时诊断、审批和停止。
- 增加 Git worktree 隔离和会话恢复元数据。
- 增加分级权限、预算和 Supervisor 调度核心。
- 增加 40 个自动化测试及受管运行时烟雾测试。
