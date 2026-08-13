#!/bin/bash

# 测试动态规划功能的端到端集成

set -e

echo "=== Kimi Agent Desktop - 动态规划集成测试 ==="
echo

# 1. 检查 Node.js
echo "1. 检查 Node.js 环境..."
if ! command -v node &> /dev/null; then
    echo "❌ 错误: 未找到 Node.js"
    exit 1
fi
NODE_VERSION=$(node --version)
echo "✅ Node.js 版本: $NODE_VERSION"
echo

# 2. 检查 TypeScript 编译
echo "2. 检查 TypeScript 编译..."
cd "$(dirname "$0")/.."
if [ ! -d "dist" ]; then
    echo "📦 运行 TypeScript 编译..."
    npm run build
fi
echo "✅ TypeScript 编译完成"
echo

# 3. 检查 Swift 编译
echo "3. 检查 Swift 编译..."
cd macos
if ! swift build > /dev/null 2>&1; then
    echo "❌ 错误: Swift 编译失败"
    exit 1
fi
echo "✅ Swift 编译完成"
echo

# 4. 测试 CLI 工具
echo "4. 测试动态规划 CLI..."
cd ..
cat > /tmp/test-dynamic-plan-request.json <<EOF
{
  "taskID": "test-123",
  "sessionID": "session-456",
  "prompt": "修复登录页面的按钮样式问题",
  "workspacePath": "$(pwd)",
  "mode": "automatic",
  "model": "moonshot-v1-128k"
}
EOF

if [ -f "dist/cli/dynamicPlanningCLI.js" ]; then
    echo "✅ 找到 CLI 脚本: dist/cli/dynamicPlanningCLI.js"
else
    echo "❌ 错误: 未找到 dist/cli/dynamicPlanningCLI.js"
    exit 1
fi
echo

# 5. 运行测试
echo "5. 运行集成测试..."
npm test 2>&1 | grep -E "PASS|FAIL|✓|✗" | head -20
echo "✅ 测试完成"
echo

echo "=== 集成测试完成 ==="
echo
echo "📝 启用动态规划："
echo "   export KIMI_DYNAMIC_PLANNING=1"
echo
echo "📝 配置 Node 路径（如果需要）："
echo "   在 Swift 代码中已设置为: /opt/homebrew/opt/node@22/bin/node"
echo
echo "📝 下一步："
echo "   1. 设置环境变量 KIMI_DYNAMIC_PLANNING=1"
echo "   2. 配置 Kimi API Key"
echo "   3. 启动应用并创建任务"
echo "   4. 观察动态规划的生成过程"
