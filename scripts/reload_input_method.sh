#!/bin/bash
set -euo pipefail

APP_PATH="/Library/Input Methods/Fire.app"
# 允许外层（build_and_reload.sh）指定构建产物；默认仍为 Debug 路径
BUILD_APP="${BUILD_APP:-/tmp/FireDerivedData/Build/Products/Debug/Fire.app}"

if [[ ! -d "$BUILD_APP" ]]; then
  echo "Build app not found: $BUILD_APP"
  echo "Run xcodebuild first, or update BUILD_APP path in this script."
  exit 1
fi

echo "Re-signing build (ad-hoc, strip hardened runtime)"
# 工程开了 ENABLE_HARDENED_RUNTIME；ad-hoc 签名下 dyld 会因 Sparkle 等嵌套
# 库 Team ID 不一致拒绝加载（启动即 SIGABRT），本地构建统一去掉 runtime 标记。
codesign --force --sign - "$BUILD_APP"

echo "Copying $BUILD_APP -> $APP_PATH"
sudo rm -rf "$APP_PATH"
sudo ditto "$BUILD_APP" "$APP_PATH"

echo "Killing running Fire input method (if any)"
sudo pkill -f "$APP_PATH/Contents/MacOS/Fire" || true

echo "Restarting input method services"
killall TextInputMenuAgent TextInputSwitcher imklaunchagent || true

echo "Done. Switch input method to Fire to verify."
