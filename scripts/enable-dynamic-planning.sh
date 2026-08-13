#!/bin/bash
# 启用动态规划功能

# 设置环境变量到 launchd（macOS GUI 应用环境）
launchctl setenv KIMI_DYNAMIC_PLANNING 1

echo "✅ 动态规划已启用"
echo ""
echo "现在请："
echo "1. 完全退出 Kimi Agent Desktop 应用"
echo "2. 从 Launchpad 或 Finder 重新启动应用"
echo ""
echo "如需禁用，运行："
echo "  launchctl unsetenv KIMI_DYNAMIC_PLANNING"
