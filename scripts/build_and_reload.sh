#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.."; pwd)"
WORKSPACE="$PROJECT_ROOT/Fire.xcodeproj/project.xcworkspace"
SCHEME="Fire"
DERIVED_DATA="/tmp/FireDerivedData"

# 默认 Release(-O)：输入法是常驻热路径进程，Debug(-Onone) 会把按键延迟
# 放大 10~70 倍（长编码下 75~95ms/键，肉眼可见卡顿），只应在调试时显式选择。
# 用法：scripts/build_and_reload.sh [debug]
CONFIG="Release"
if [[ "${1:-}" == "debug" ]]; then
  CONFIG="Debug"
fi

BUILD_APP="$DERIVED_DATA/Build/Products/$CONFIG/Fire.app"

if xcodebuild -version >/dev/null 2>&1; then
  echo "Resolving packages"
  xcodebuild -resolvePackageDependencies \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA"

  echo "Building $CONFIG (xcodebuild)"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA"
else
  # 精简环境：本机只有 Command Line Tools。用 clang + swiftc + SPM 手工链路
  # 产出同一布局的 Fire.app（依赖版本与 Package.resolved 对齐），
  # 细节与已核实差异见 scripts/lean-build/build_app.sh 头注释。
  echo "未检测到完整 Xcode，使用精简工具链构建 ${CONFIG}（仅 Command Line Tools）"
  LEAN_ARG=""
  [[ "$CONFIG" == "Debug" ]] && LEAN_ARG="debug"
  DERIVED_DATA="$DERIVED_DATA" bash "$PROJECT_ROOT/scripts/lean-build/build_app.sh" $LEAN_ARG
fi

# ad-hoc 签名 + 硬运行时（ENABLE_HARDENED_RUNTIME=YES）会开启 dyld 库校验：
# 本地 ad-hoc 重签的 Sparkle.framework 与主程序 Team ID 不一致，进程启动即崩
# （Library missing / different Team IDs），输入法选中后整个键盘无响应。
# 官方发布走真实证书无此问题；本地 ad-hoc 构建去掉 runtime 标记再安装。
echo "Re-signing (ad-hoc, no hardened runtime)"
codesign --force --sign - "$BUILD_APP"

echo "Reloading input method ($CONFIG)"
BUILD_APP="$BUILD_APP" bash "$PROJECT_ROOT/scripts/reload_input_method.sh"

