# Git Push 前检查清单

## ✅ 已完成
- [x] 动态规划核心代码实现
- [x] CLI 打包脚本
- [x] Swift 桥接层
- [x] 环境配置脚本
- [x] 对比分析文档

## 📝 需要添加的文档
- [ ] DYNAMIC_PLANNING_README.md（使用说明）
- [ ] CHANGELOG.md（记录本次更新）
- [ ] 更新主 README.md（添加动态规划说明）

## 🧹 代码清理
- [ ] 移除未使用的变量（kimiScriptPath 警告）
- [ ] 移除 default 分支警告
- [ ] 添加注释说明关键设计决策

## 🧪 测试
- [ ] 端到端测试（用真实 API）
- [ ] 错误场景测试（无 API 密钥、网络错误等）
- [ ] 更新测试文档

## 📦 文件组织
```
新增文件：
├── src/cli/dynamicPlanningCLI.ts
├── scripts/bundle-cli.mjs
├── scripts/enable-dynamic-planning.sh
├── CLAUDE_CODE_COMPARISON.md (更新)
├── DYNAMIC_PLANNING_STATUS.md
└── DYNAMIC_PLANNING_README.md (待创建)

修改文件：
├── src/runtime/dynamicPlanningAdapter.ts
├── src/runtime/kimiRuntimeAdapter.ts
├── macos/Sources/KimiAgentCore/DynamicPlanningBridge.swift
├── macos/Sources/KimiAgentCore/AgentOrchestration.swift
├── macos/Sources/KimiAgentDesktop/DesktopAppModel.swift
├── scripts/package-native-macos.mjs
└── package.json
```

## 🚀 Git 操作建议

### 方案 1：单个大 commit（不推荐）
```bash
git add .
git commit -m "feat: 实现动态任务规划功能"
git push origin master
```

### 方案 2：分阶段提交（推荐）
```bash
# Commit 1: 核心逻辑
git add src/core/dynamicPlanner.ts src/runtime/dynamicPlanningAdapter.ts src/runtime/kimiRuntimeAdapter.ts
git commit -m "feat: 添加动态规划核心逻辑和 Kimi SDK 集成"

# Commit 2: CLI 工具
git add src/cli/dynamicPlanningCLI.ts scripts/bundle-cli.mjs
git commit -m "feat: 实现动态规划 CLI 和打包脚本"

# Commit 3: Swift 集成
git add macos/Sources/KimiAgentCore/DynamicPlanningBridge.swift \
        macos/Sources/KimiAgentCore/AgentOrchestration.swift \
        macos/Sources/KimiAgentDesktop/DesktopAppModel.swift
git commit -m "feat: Swift 层集成动态规划桥接"

# Commit 4: 打包和配置
git add scripts/package-native-macos.mjs scripts/enable-dynamic-planning.sh package.json
git commit -m "feat: 更新打包脚本和环境配置工具"

# Commit 5: 文档
git add CLAUDE_CODE_COMPARISON.md DYNAMIC_PLANNING_STATUS.md
git commit -m "docs: 添加动态规划文档和对比分析"

# 推送
git push origin master
```

## ⚠️ 注意事项
1. **不要提交敏感信息**：
   - API 密钥
   - 测试用的真实项目路径
   
2. **检查 .gitignore**：
   ```
   release-native/
   dist/
   node_modules/
   *.log
   .DS_Store
   ```

3. **commit message 规范**：
   - feat: 新功能
   - fix: 修复
   - docs: 文档
   - refactor: 重构
   - test: 测试
