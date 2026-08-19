# Implementation Status

更新日期：2026-08-15

## 当前产品线

项目现在只保留 **原生 macOS SwiftUI 版本**。

已移除并停止维护：

- Electron 独立桌面版；
- VS Code / Code - OSS 扩展版；
- WebView Dashboard 壳层；
- VSIX 打包链路；
- Electron 打包链路；
- 旧 Electron 发布产物；
- 额外优化路线文档。

## macOS 原生版能力

已保留：

- SwiftUI 原生三栏工作台、工具栏、快捷键和系统文件夹选择器；
- Plan / Edit / Agent 三种模式；
- Kimi Code 登录模式与 Moonshot / Kimi API Key 模式；
- Keychain 凭据保存；
- 本地任务、事件、项目状态持久化；
- Native Agent Host 与 CLI 回退链路；
- Worktree 隔离、Diff Review、验证、人工合并；
- Web Search / Fetch；
- Skills / Hooks / MCP；
- Agent Run 编排图、项目规则发现和 Plugin / 自定义 Agent 注册表；
- 会话级 Workspace Layout 持久化和 Agent 阶段状态回流；
- GitHub / GitLab 管理入口；
- WKWebView 浏览器验证；
- 内置 Kimi Runtime 与 macOS Node Runtime；
- arm64 / x86_64 / universal 原生发布路径。

## 当前维护原则

- 只维护 macOS 原生应用；
- 不再新增或优化 Electron / VS Code / WebView 兼容版本；
- 不再把旧壳层作为产品目标；
- 后续改动只服务于 macOS 原生版的稳定性和可用性。

## 2026-08-10 真实闭环更新

- 新增 SessionKernel：追加式 Session Event Store、MessagePart 和 Projector 回放；桌面新任务开始写入 `session-events.jsonl`。
- 新增 ChildSessionCoordinator 和 ToolRegistry，作为后续真实独立 Kimi Child Runtime 与统一工具执行层的接口。
- 新任务不再只有旧的 `WorkItem` 列表，同时生成独立 `AgentRun` 图并写入任务状态。
- 旧任务启动时会迁移到默认 Agent 图；运行中的节点在应用重启后标记为 `interrupted`，可从会话继续。
- `AGENTS.md`、`.kimi-agent/rules.md` 和 `.kimi/rules.md` 会被发现，并作为项目规则注入每次 Runtime Prompt。
- `.kimi-agent/plugins` / `.kimi/plugins` 下的 `plugin.json` 会被发现；插件内 `skills/` 目录会进入统一 Skill Registry。
- 扩展 Inspector 现在包含 Plugins 区块，任务主区域显示 Agent 阶段活动和状态。
- 权限层新增 `CapabilityGrant`，用于按 Agent / 资源 / 操作范围记录最小授权；现有审批策略继续作为执行门禁。

## 2026-08-14 Harness 可靠性更新

- 新增 JSON 原生 ToolCallEnvelope 与严格 Schema 校验；无效参数会在 Hook、权限审批、Intent 和执行器之前被拒绝。
- Tool Intent 增加输入摘要，Receipt 增加输出摘要、Artifact ID、重试语义；成功 Tool Result 会回传真实 effectID，供 Child Agent 和最终答案核验。
- Kimi SSE 增加持久化 ProviderTraceRecorder 与离线 ProviderReplayRunner：可回放 name-only、index-only、空参数、碎片化参数和中断流，不记录 API Key。
- Native Kimi Provider 与主会话/Child Session 都写入本地 harness-v3/provider-traces.jsonl。
- 公网只读 Web Research 在策略层不再被标记为预审批操作；实际执行仍由公网/私网、协议、URL 和域名策略二次约束。
- 同一 Worktree 的 Implement / Debug 等写入阶段由 DAG Scheduler 串行调度，避免并行 Child Agent 改写同一隔离工作区。
- 记忆增加语义键、作用域优先级和冲突审计；同键 Task/Project 记忆覆盖 User 记忆，自动推导记忆不提升权限。
- Context Projector 现在可注入规则、已验证结果和未解决问题；Final Answer Gate 可要求专用工具具有成功 Receipt。
- 用量账本区分“已计算成本”和“价格未配置”，不再把未知价格的 0 伪装为真实成本；可通过 KIMI_AGENT_PRICE_* 环境变量配置每百万 Token 价格，并在 80%/100% 预算处预警/阻断。

## 2026-08-14 Supervisor 闭环更新

- 新增 Core-owned `AgentGraphSupervisor`：DAG 节点选择、依赖释放、Child Session 创建、结果回流和快照事件均由 Core actor 负责；SwiftUI 只投影 `AgentGraphSupervisorEvent`。
- 移除桌面层 120ms `scheduleReady()` 轮询和手写 Child Agent 成功/失败回填；图驱动现在只有一个 Supervisor execution authority。
- `AgentRunScheduler` 支持 `childSessionID` 关联、调度/结算快照、单节点 retry 和明确的 Worktree 冲突串行规则。
- `ChildSessionCoordinator` 为每次执行创建可取消 Task；暂停/取消会传播到正在运行的 Provider/Tool executor，不再只修改 UI 状态。
- 应用启动会从持久化 `AgentRun` 重建 Supervisor；未结算节点转为 `interrupted`，只有用户明确继续后才进入下一次执行。
- 重启恢复会先通过 `AgentGraphRecoveryPolicy` 校验任务意图；迁移产生的普通聊天 AgentRun 不会误恢复成 Explore/Plan 图。
- Graph 的事件投影保持最新单链：阶段结果、Child Session ID 和最终汇总都从 Core snapshot 回流，不由 UI 猜测完成状态。
- MCP Harness executor 现接入 Worker health：成功调用记录 `healthy`；失败记录 `reconnecting` / `unavailable` 并尝试重连 Worker，但绝不自动重放当前 MCP tool call，避免未知的外部副作用被重复执行。

## 尚需真实环境验收

已通过的真实验收（本机，含证据产物）：

- Browser 真实闭环：`BrowserSmokeCheck` 通过本地 loopback HTTP + 生产 `BrowserVerificationController`（离屏 WKWebView）完成 open → inspect h1 → screenshot → collectConsole，截图产物真实落盘且可读（`BROWSER_SMOKE_OK`，截图 91KB）。
- Computer Use 真实闭环：`ComputerUseSmokeCheck` 驱动生产 `ComputerUseController.executeHarnessRequest` 完成 inspect、真实屏幕捕获（303KB PNG，目视确认）、参数校验、辅助功能/屏幕录制权限门与结构化错误路径（`COMPUTER_USE_SMOKE_OK screenGranted=true accessibilityGranted=true`）。
- MCP 真实第三方 Server：`MCPSmokeCheck` 驱动生产 `MCPStdioClient` 连接 `@modelcontextprotocol/server-everything@2.0.0`，完成 initialize 握手、tools/list（12 个工具）、echo 真实回环、resources/list + read、prompts/list + get，以及 `kill -9` 崩溃注入后结构化 `notConnected`（无挂起、无崩溃）和 close 后守卫（`MCP_SMOKE_OK`）。
- 重启恢复进程级闭环：`RestartRecoveryCheck` 以两个独立进程共享同一状态目录模拟应用被杀后重启。已结算 op 保持 completed 且成功 Receipt 保留（零重放）；中途被杀的 op 恢复为 suspended，未结算写入 Intent 保留但绝不伪造 Receipt，未应答 tool call 写入合成中断结果；restore 实测 0.001s（预算 2s）；会话列表、活跃会话和消息历史经生产 `KimiAppKernel` 恢复（`RESTART_RECOVERY_OK`）。

仍需真实环境验收：

- 真实 Kimi API 端到端对话、真实 MCP OAuth/远程 Transport 和 100 仓库对标基准必须在已配置凭据与用户授权的 macOS 环境中执行。
- 这些外部验收在通过前不应标记为“超过 Claude Code”；本地 CoreChecks、构建和打包只证明可回放的本地闭环。
