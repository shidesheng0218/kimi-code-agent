# Changelog

## Unreleased - 2026-08-19

- 接通全部断链链路并对齐 Claude Code 交互：停止按钮、Steer 插队、Follow-up 排队、流式合并、reasoning 折叠、三键权限审批（含“总是允许”与 patterns 展示）、SSE 断线重连、会话历史重建、Todo 清单、结构化问答卡、消息级 revert/unrevert、Slash 命令、compact。
- 真实引擎 + 真实 Kimi API 验收（内核级 27 项断言）中修复四个存量深层缺陷：SSE 帧解析失效（事件流此前从未产出事件）、SSE 60 秒默认超时掐断长 turn、permission.replied 被误判为 asked 产生僵尸审批卡、用户消息 text part 被回显为助手气泡。
- 修复会话目录缺陷：directory 从 POST body 迁移到引擎实际读取的 query 参数；新建会话强制选择项目文件夹，侧栏按项目分组。
- 模型切换真生效：per-prompt ModelRef 免重启切换；启动拉取 /provider 目录；reconfigure 保留 loopback 端口与 token。
- 五个占位面板全部实体化：Diff（真实 git diff）、Files（目录树+预览）、Browser（截图产物）、验证（Intent/Receipt 审计）、集成（MCP/Skills）。
- Driver 超时放宽至 30 分钟且超时后主动 abort 引擎会话；审计 turn 记录真实模型；首页模型统计补数。
- 文档真实化：README 执行闭环/能力地图/权限表按引擎原生架构改写；ClaudeParityCatalog 标记真实实现状态；Swift Supervisor/DAG 编排标记为仅测试接线的实验层。

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
