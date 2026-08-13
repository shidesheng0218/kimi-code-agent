# 🚀 快速启动指南 - Kimi Agent Desktop 动态规划

## 30 秒启动

```bash
# 1. 启用动态规划
export KIMI_DYNAMIC_PLANNING=1

# 2. 构建项目
npm run build
cd macos && swift build

# 3. 启动应用
swift run KimiAgentDesktop
```

## 第一次使用

### 步骤 1: 配置 API Key

在应用中：
1. 点击 "设置" → "Kimi 连接"
2. 输入你的 Kimi API Key
3. 保存

### 步骤 2: 创建任务

1. 选择项目文件夹
2. 输入任务描述，例如：
   ```
   修复登录页面的按钮样式，使其在移动端正确显示
   ```
3. 点击 "创建任务"

### 步骤 3: 观察魔法 ✨

系统会自动：
- 🧠 分析项目结构
- 📝 生成 3-8 个子任务
- 🔗 构建依赖关系图
- ⚡ 并行执行任务（最多 8 个）

## 示例输出

```
✅ 动态计划已生成，共 4 个子任务：

1. [explore-login-ui] 定位登录页面和样式文件
   依赖: 无
   状态: ✅ 已完成

2. [implement-mobile-fix] 修复移动端样式
   依赖: explore-login-ui
   状态: 🔄 进行中

3. [test-responsive] 在不同设备测试响应式布局
   依赖: implement-mobile-fix
   状态: ⏳ 等待中

4. [review-accessibility] 审查无障碍性合规
   依赖: implement-mobile-fix
   状态: ⏳ 等待中
```

## 关闭动态规划

```bash
unset KIMI_DYNAMIC_PLANNING
```

## 故障排除

### 问题: "未找到 Node.js"

```bash
# 检查 Node.js
which node

# 如果没有，安装 Node.js
brew install node@22
```

### 问题: "动态规划失败"

1. 检查 API Key 是否有效
2. 查看错误日志
3. 系统会自动回退到固定流程

### 问题: "编译失败"

```bash
# 清理并重新构建
npm run build
cd macos && swift build --clean
```

## 更多信息

- 完整文档: [INTEGRATION_COMPLETE.md](INTEGRATION_COMPLETE.md)
- 测试脚本: `./scripts/test-dynamic-planning.sh`
- 实现细节: [docs/](docs/)

## 对比

### 传统模式 (固定 5 步)
```
任务: 修复按钮样式
→ Explore (2分钟)
→ Plan (1分钟)
→ Implement (3分钟)
→ Test (2分钟)
→ Review (1分钟)
总计: 9分钟，串行执行
```

### 动态模式 (AI 生成)
```
任务: 修复按钮样式
→ AI 分析 (5秒)
→ 生成 3 个子任务
   - explore-button (1分钟) ───┐
   - implement-fix (2分钟) ────┤→ 并行
   - test-mobile (1分钟) ──────┘
总计: 3分钟，并行执行
```

**节省 67% 时间！** ⚡

---

**立即体验 Claude Code 级别的 Agent 模式！** 🎉
