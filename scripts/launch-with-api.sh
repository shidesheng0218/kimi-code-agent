#!/bin/bash
# 启动应用并配置 API 密钥

export KIMI_DYNAMIC_PLANNING=1
export KIMI_API_KEY="your-api-key-here"  # 请替换为你的 Kimi API 密钥
export KIMI_BASE_URL="https://api.moonshot.cn/v1"  # 可选，默认就是这个

open "release-native/mac-arm64/Kimi Agent Desktop.app"
