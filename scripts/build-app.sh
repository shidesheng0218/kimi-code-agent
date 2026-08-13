#!/bin/bash

# 快速构建和更新 Kimi Agent Desktop 应用

set -e

cd "$(dirname "$0")/.."

echo "🔨 开始构建..."
echo

# 1. 构建 TypeScript
echo "📦 编译 TypeScript..."
npm run build

# 2. 打包应用
echo "🎁 打包应用..."
npm run native:package

echo
echo "✅ 构建完成！"
echo
echo "📱 应用位置: release-native/mac-arm64/Kimi Agent Desktop.app"
echo "💿 DMG 安装包: release-native/Kimi-Agent-Desktop-0.3.0-arm64.dmg"
echo
echo "💡 现在可以从 Launchpad 启动更新后的应用"
