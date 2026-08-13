# Kimi Agent CLI 提案

## 目标
对标 Claude Code CLI，提供跨平台命令行工具。

## 使用场景

```bash
# 快速任务
kimi "修复登录页面的 TypeScript 错误"

# 交互模式
kimi chat

# 指定模式
kimi --mode=plan "重构用户认证模块"
kimi --mode=edit "将所有 var 改为 const"

# 项目上下文
kimi --cwd=/path/to/project "添加用户头像上传功能"

# 会话管理
kimi sessions list
kimi sessions resume <session-id>
```

## 技术实现

### 架构
```
kimi (CLI 入口)
  ↓
src/cli/
  ├── index.ts           # 命令行解析（使用 commander.js）
  ├── interactive.ts      # 交互模式（使用 inquirer）
  └── taskRunner.ts      # 任务执行器
      ↓
src/runtime/
  ├── nativeAgentHost.ts  # 已有的 ACP 宿主
  └── kimiRuntimeAdapter.ts # 已有的 Kimi SDK 适配器
```

### 依赖
- `commander`: CLI 框架
- `inquirer`: 交互式提示
- `chalk`: 终端颜色输出
- `ora`: 加载动画

### 发布
```bash
npm install -g @moonshot-ai/kimi-agent-cli
# 或
brew install kimi-agent
```

## 与桌面版的关系
- CLI 和桌面版**共享同一个运行时层**
- 会话数据兼容（都使用 `session-events.jsonl`）
- 桌面版可以打开 CLI 创建的会话，反之亦然

## 实现路线

### Phase 1: 基础 CLI（2 周）
- [x] 已有运行时层
- [ ] CLI 入口和参数解析
- [ ] 一次性任务执行
- [ ] 基础输出格式化

### Phase 2: 交互模式（1 周）
- [ ] `kimi chat` 交互式对话
- [ ] 实时输出流
- [ ] 审批流程（工具调用确认）

### Phase 3: 会话管理（1 周）
- [ ] 会话列表、恢复、删除
- [ ] 与桌面版会话互通

### Phase 4: 高级功能（2 周）
- [ ] 配置文件 `~/.kimi/config.json`
- [ ] 自定义 Agent/Skills
- [ ] 日志和调试模式
