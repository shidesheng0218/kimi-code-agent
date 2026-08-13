# Implementation Status

更新日期：2026-08-09

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
