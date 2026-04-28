#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.."; pwd)"
WORKSPACE="$PROJECT_ROOT/Fire.xcodeproj/project.xcworkspace"
SCHEME="Fire"
DERIVED_DATA="/tmp/FireDerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/Fire.app"

echo "Resolving packages"
xcodebuild -resolvePackageDependencies \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -derivedDataPath "$DERIVED_DATA"

echo "Building Debug"
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA"

echo "Reloading input method"
bash "$PROJECT_ROOT/scripts/reload_input_method.sh"

