#!/bin/bash
set -euo pipefail

APP_PATH="/Library/Input Methods/Fire.app"
BUILD_APP="/tmp/FireDerivedData/Build/Products/Debug/Fire.app"

if [[ ! -d "$BUILD_APP" ]]; then
  echo "Build app not found: $BUILD_APP"
  echo "Run xcodebuild first, or update BUILD_APP path in this script."
  exit 1
fi

echo "Copying $BUILD_APP -> $APP_PATH"
sudo rm -rf "$APP_PATH"
sudo ditto "$BUILD_APP" "$APP_PATH"

echo "Killing running Fire input method (if any)"
sudo pkill -f "$APP_PATH/Contents/MacOS/Fire" || true

echo "Restarting input method services"
killall TextInputMenuAgent TextInputSwitcher imklaunchagent || true

echo "Done. Switch input method to Fire to verify."
