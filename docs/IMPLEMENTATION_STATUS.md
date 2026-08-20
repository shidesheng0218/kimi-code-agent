# Implementation Status

更新日期：2026-08-19

## 2026-08-19 断链补全（Claude Code 交互对齐）

本期把已实现但未接线的链路全部接通，并把引擎已支持的能力上浮到 UI。架构决策：内置引擎（opencode 派生）是唯一执行链；Swift 侧 Supervisor/DAG 编排（AgentKernel/AgentGraphSupervisor/AgentRunScheduler 等）保持仅测试接线，不再追求生产化。

### 真实环境验收（2026-08-19，本机 + 真实 Kimi API）

以发布包内真实引擎二进制（生产配置镜像）+ 真实 API Key 完成两级验收：

1. **引擎级（curl 驱动）**：会话创建/目录路由、模型目录、edit/bash 权限 ask→once/always、流式 delta、agentic 全循环（写文件→跑测试→测试通过）、steer 插队被运行中 turn 拾起、abort、revert/unrevert 文件回滚与还原。
2. **内核级（生产 KimiAppKernel + URLSessionRuntimeClient 驱动真实引擎，27 项断言全过）**：建会话→忙态→审批卡（patterns 保留）→always 应答→turn 完成→单气泡合并→无用户消息回显→Harness 回执→steer→历史重建→abort→revert→模型目录/todo/command/mcp 端点。

验收中发现并修复的四个存量深层缺陷（全部有回归断言）：

- **SSE 帧解析失效**：`URLSession.bytes.lines` 不上送空白分隔行，原实现等空行成帧导致事件流实际从未产出任何事件（长 turn 后 UI 与引擎脱节）。改为单行 JSON 完整即解码。
- **SSE 请求 60 秒默认超时**：`URLRequest` 默认 timeoutInterval 会在长权限等待后掐断流。显式放宽并按心跳维持活性；断流重连后新增 `GET /session/status` 状态对账。
- **`"replied"` 不含子串 `"reply"`**：`mapKind` 用 `contains("reply")` 判定 `permission.replied`，永远落空导致 replied 被误判为 permissionAsked——审批完成后引擎的结算事件变成第二张不可应答的僵尸审批卡。改判 `replied`/`resolved`，审批卡按引擎 requestID 去重，`permission.replied`/`question.replied` 到达即按 requestID 结算移除。
- **用户消息回显**：用户消息的 text part 快照/delta 被当作助手文本（出现"自己的消息变成助手气泡"）。解码器新增 messageID→role 注册表，用户消息的 part 一律过滤。

对话闭环修复：

- 修复 directory 误放 POST body 的缺陷（引擎只认 query 参数；此前所有会话都跑在引擎进程 cwd）；全部端点统一 query 路由并用 URLComponents 正确转义。
- 流式回复按 partID 合并为单条气泡（delta 追加 / snapshot 替换 / idle 封口），不再裂成碎片；reasoning 内容隔离为可折叠“思考过程”卡片。
- session.status/session.idle 驱动运行态；执行中显示停止按钮（引擎 abort + Harness abort 一致）。
- 权限审批迁移到 `/permission/{id}/reply`：拒绝 / 允许一次 / 总是允许三按钮，展示引擎下发的 patterns；审批失败可见不静默；重启后过期审批卡自动清理。
- SSE 断流指数退避重连（上限 12 次）；引擎意外重启后 supervisor 重新等待就绪并通知内核重新订阅全部会话。
- Driver 超时放宽到 30 分钟且超时后主动 abort 引擎会话保持两侧一致；审计 turn 记录真实所选模型；补记 assistantMessage 让首页模型统计有数据。

会话与项目：

- 新建会话强制 NSOpenPanel 选择项目目录；会话与项目绑定，最近项目持久化；隐式建会话用最近项目，无项目时明确报错引导。
- 切换会话/重启后从 `GET /session/{id}/message` 重建消息与工具活动；Todo 从 `/todo` 恢复。
- 模型切换真生效：`prompt_async` 携带 per-prompt ModelRef（免重启）；启动时 `GET /provider` 拉取目录；目录变更时带原 endpoint 就地 reconfigure（端口/token 保持稳定）。

Claude Code 交互：

- Steer：Driver 轮询 Harness steering 队列并转发运行中的引擎会话（引擎 busy 时自动在循环边界拾起）。
- Follow-up：忙时可排队，本轮结束自动开新轮（Harness 队列语义）。
- Todo 清单（todo.updated → 会话顶部清单）、结构化问答卡（question.asked → 选项/自定义回答 → reply/reject）、消息级 revert/unrevert、Slash 命令（`/` 补全 → `/session/{id}/command`）、compact（summarize 端点）。

面板实体化（原五个占位面板全部落地）：

- Diff：项目工作区真实 git diff（DiffEngine 解析，文件/hunk 渲染）；
- Files：项目目录树 + 文本预览；
- Browser：截图产物与浏览器活动展示（活动卡内联图片）；
- 验证：Harness Intent/Receipt 审计视图；
- 集成：引擎 MCP 状态与 Skills 列表。

文档对齐：README 执行闭环/能力地图/权限表/会话语义改写为引擎原生架构的真实描述；ClaudeParityCatalog 更新为真实实现状态（worktreeIsolation、planMode、hooks、githubAutomation、gitlabIntegration、memory 标记为未实现）。

验收：KimiAgentCoreChecks 新增约 40 条断言（directory query 转义、流式合并、reasoning 分类、忙态映射、always 应答、steer 泵送、超时一致性、历史解析/重建、模型目录、工厂 reconfigure 保端点、todo/question 解码、revert/command/summarize/todo/command 端点、MCP/Skills 解析、验证回执聚合、图片产物提取），全部通过；`swift build` 两个产品全绿。

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
- arm64 原生发布路径（GitHub Releases 直接分发，ad-hoc 签名、不公证）。

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
