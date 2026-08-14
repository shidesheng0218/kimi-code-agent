#!/bin/bash
# scripts/auto-update-app.sh - 自动构建并更新应用（直接覆盖，不留备份）

set -e

echo "🔨 开始构建 Kimi Agent Desktop..."

# 1. 编译 TypeScript
echo "📦 编译 TypeScript..."
npm run build

# 2. 打包 CLI
echo "📦 打包 CLI..."
npm run bundle:cli

# 3. 构建并打包 macOS 应用
echo "🍎 构建 macOS 应用..."
node scripts/package-native-macos.mjs

# 4. 停止旧应用
echo "🛑 停止旧应用..."
pkill -f "Kimi Agent Desktop" 2>/dev/null || true
sleep 1

# 5. 直接删除旧应用（不备份）
echo "🗑️ 移除旧版本..."
rm -rf "/Applications/Kimi Agent Desktop.app"

# 6. 安装新应用
echo "📲 安装新应用..."
cp -R "release-native/mac-arm64/Kimi Agent Desktop.app" "/Applications/"

echo "✅ 应用已更新！"
echo "📍 位置: /Applications/Kimi Agent Desktop.app"
echo ""
echo "🚀 正在启动..."
open "/Applications/Kimi Agent Desktop.app"
