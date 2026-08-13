# Kimi Agent Desktop for macOS

Kimi Agent Desktop 现在只保留 **原生 macOS SwiftUI 版本**。

本项目不再维护 Electron 桌面版、VS Code 扩展版或其他兼容壳。后续开发只围绕 macOS 原生应用本身进行，避免多套界面和多条运行链路继续造成体验割裂。

## 产品范围

- 原生 SwiftUI / AppKit macOS 工作台
- 本地优先任务、会话、事件和项目状态持久化
- Kimi Code 登录模式与 Moonshot / Kimi API Key 模式
- Plan / Edit / Agent 三种任务模式
- Worktree 隔离、Diff Review、验证和人工合并
- Web Search / Fetch、Skills、Hooks、MCP、GitHub / GitLab、浏览器验证等能力均只在 macOS 原生版中承载
- 内置 Kimi Runtime 和 macOS Node Runtime，不要求用户手动安装 Node

## 已移除范围

- Electron 独立桌面壳
- VS Code / Code - OSS 扩展壳
- WebView Dashboard 壳层
- VSIX 打包链路
- Electron 打包链路
- 旧 Electron 发布产物

## 使用安装包

请从 GitHub 仓库的 **Releases** 页面下载对应架构的 DMG 或 ZIP，再将应用拖入“应用程序”。
2. 打开 **Kimi Agent Desktop**。
3. 在“Kimi 连接设置”里选择：
   - **API Key 模式**：填写 Moonshot / Kimi API Key、Base URL 和默认模型；
   - **Kimi Code 登录模式**：按网页登录指引完成授权。
4. 选择项目文件夹，创建任务并运行。

Kimi 官方 API Base URL：

```text
https://api.moonshot.ai/v1
```

## 开发与验证

```bash
npm install
npm run check
npm test
npm run native:check
npm run native:package
npm run verify
```

原生产物位于 `release-native/`。

## 当前状态与分发说明

- 最低支持 macOS 14；当前只维护原生 macOS 版本。
- API Key、SSH 凭据和授权记录只保存在本机凭据存储中，不会写入仓库或普通状态文件。
- Web Search / Fetch 需要网络访问与有效的 Kimi API 配置；公开只读搜索会复用当前任务的授权范围。
- Computer Use 需要在 macOS“隐私与安全性”中授予辅助功能与屏幕录制权限。
- 本地开发包使用 ad-hoc 签名；正式 GitHub Release 需要配置 Developer ID 签名和 Apple 公证，详见 `docs/GITHUB_RELEASES.md`。

## 架构

```text
macOS SwiftUI / AppKit
        │
DesktopAppModel
        ├── KimiAgentCore
        ├── TaskRepository（Application Support）
        ├── KimiAgentHostRunner
        ├── Worktree / Diff / Verification
        └── Bundled Node + Kimi Runtime Resources
```

## 维护原则

- 只做 macOS 原生版；
- 不再新增 Electron / VS Code / WebView 兼容版本；
- 不再保留额外优化路线文档；
- 优先保证现有 macOS 功能闭环、稳定、可运行。
