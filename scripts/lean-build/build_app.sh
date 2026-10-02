#!/bin/bash
# =============================================================================
# 精简环境构建脚本：只用 Command Line Tools（clang / swiftc / iconutil /
# codesign），不依赖完整 Xcode，产出与 xcodebuild 相同布局的 Fire.app。
#
# 用法: scripts/lean-build/build_app.sh [debug]      （默认 Release）
# 产物: $DERIVED_DATA/Build/Products/<Config>/Fire.app （默认 /tmp/FireDerivedData）
#
# 与 xcodebuild 的差异：
#   * MainMenu.xib 不编译（CLT 无 ibtool）。注意 delegate 不能靠 nib 的
#     File's Owner 连线：AppKit 的 NSApplicationMain 在 Info.plist 无
#     NSMainNibFile 时默认加载 bundle 里的 MainMenu.nib，lean 产物没有
#     这个 nib → delegate 为 nil → applicationDidFinishLaunching 不触发
#     → IMKServer 不创建，选中输入法后按键全灭。已由
#     Fire/AppDelegate.swift 的 #if LEAN_BUILD 显式 static main() 补上；
#   * Assets.xcassets 不编译 Assets.car —— 全仓库无任何按资源名取图
#     （NSImage(named:)/Image(")调用），仅 AppIcon 用 iconutil 生成
#     AppIcon.icns（Info.plist 的 CFBundleIconFile 本来就指它）；
#   * Sparkle / Defaults / KeychainSwift / NanoID 由 scripts/lean-build
#     的 SPM 清单用 swift build 产出 .o + swiftmodule，直接参与链接，
#     版本与 xcodeproj 的 Package.resolved 对齐；
#   * SDK 27 起 SwiftUI @State 变为宏优先（SwiftUIMacros 插件不随 CLT 分发），
#     自动生成 SwiftUICore swiftinterface shim 剥离宏声明，回到编译器
#     原生的旧 property wrapper 展开（见第 0 节）。
# =============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.."; pwd)"
cd "$PROJECT_ROOT"

CONFIG="Release"
[[ "${1:-}" == "debug" ]] && CONFIG="Debug"

DERIVED="${DERIVED_DATA:-/tmp/FireDerivedData}"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
BUILD_APP="$PRODUCTS/Fire.app"

LEAN="$PROJECT_ROOT/build/lean"
DEPS="$LEAN/deps/out/Products/Release"
OUT="$LEAN/app/$CONFIG"
MODULE_CACHE="$LEAN/mc"

SDK="$(xcrun --show-sdk-path)"
MIN_MACOS="13.0"
TRIPLE="$(uname -m)-apple-macos${MIN_MACOS}"

BUNDLE_ID="com.qwertyyb.inputmethod.Fire"
PRODUCT_NAME="Fire"

mkdir -p "$OUT" "$MODULE_CACHE" "$PRODUCTS"

log() { echo "==> $*"; }

# APFS 大文件用 clone（秒级、不占额外空间），失败退回普通 cp
clonecp() { cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

# -----------------------------------------------------------------------------
# 0. SwiftUI @State 宏 shim（CLT 不带 SwiftUIMacros 插件时使用）
# macOS 26.5 起 SDK 的 SwiftUICore 把 @State 做成「property wrapper + 宏」双
# 重载，宏重载优先级更高，而宏实现 SwiftUIMacros.dylib 只随完整 Xcode 分发；
# CLT 下任何 @State 都报 "plugin for module 'SwiftUIMacros' not found"，且
# 编译器没有回退路径。这里探测到该情况后，把 SwiftUICore 的 swiftinterface
# 复制到本地、删除宏声明行，@State 即回到编译器内置的经典 property wrapper
# 展开（Xcode 16 之前所有二进制走的同一条路径，语义完全原生）。
# -----------------------------------------------------------------------------
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
SHIM_DIR="$LEAN/sdk-shim/macosx${SDK_VER}"
SHIM_STAMP="$SHIM_DIR/.state-macro-shim"
SHIM_FLAG=()

build_swiftui_shim() {
  log "生成 SwiftUICore 接口 shim（剥离 State 宏声明, SDK macosx${SDK_VER}）"
  mkdir -p "$SHIM_DIR"
  rm -rf "$SHIM_DIR/SwiftUICore.framework"
  cp -R "$SDK/System/Library/Frameworks/SwiftUICore.framework" "$SHIM_DIR/"
  SHIM_FW="$SHIM_DIR/SwiftUICore.framework" python3 - <<'PY'
import os, glob
fw = os.environ['SHIM_FW']
pat = ('public macro State(', 'public macro State<',
       'public macro _StatePropertyWrapperStorage(')
total = 0
for f in glob.glob(os.path.join(fw, 'Modules', '*.swiftmodule', '*.swiftinterface')):
    lines = open(f).read().splitlines(keepends=True)
    out, i, removed = [], 0, 0
    while i < len(lines):
        if any(p in lines[i] for p in pat):
            removed += 1
            while lines[i].rstrip() != ')':
                i += 1
            i += 1
        else:
            out.append(lines[i]); i += 1
    open(f, 'w').writelines(out)
    total += removed
if total == 0:
    raise SystemExit('shim 失败：swiftinterface 中未找到 State 宏声明')
PY
  touch "$SHIM_STAMP"
}

PROBE="$OUT/.state_probe.swift"
cat > "$PROBE" <<'SW'
import SwiftUI
struct P: View {
  @State private var n = 0
  var body: some View { Text("\(n)") }
}
SW
# 注意：不能用 `if swiftc | grep -q` —— pipefail 下 grep -q 提前关管道会让
# swiftc 收到 SIGPIPE(141)，整条管道判假。先捕获输出再匹配。
PROBE_ERR="$(swiftc -typecheck -target "$TRIPLE" -sdk "$SDK" -module-cache-path "$MODULE_CACHE" "$PROBE" 2>&1 || true)"
if printf '%s' "$PROBE_ERR" | grep -q "SwiftUIMacros"; then
  [[ -f "$SHIM_STAMP" ]] || build_swiftui_shim
  swiftc -typecheck -target "$TRIPLE" -sdk "$SDK" -module-cache-path "$MODULE_CACHE" \
    -F "$SHIM_DIR" "$PROBE" 2>/dev/null \
    || { echo "SwiftUICore shim 校验失败"; exit 1; }
  SHIM_FLAG=(-F "$SHIM_DIR")
  log "@State 走 SwiftUICore shim（编译器原生 property wrapper 展开）"
fi
rm -f "$PROBE"

# -----------------------------------------------------------------------------
# 1. SPM 依赖（Defaults/KeychainSwift/NanoID/Sparkle）
# -----------------------------------------------------------------------------
VENDOR_DEFAULTS="$LEAN/vendor/Defaults"
# swiftmodule 里记录了编译时 SDK（跨 macOS 大版本升级后会拒载），不一致则清掉产物重编
deps_up_to_date() {
  [[ -d "$DEPS/Sparkle.framework/Versions/A" && -f "$DEPS/Defaults.o" ]] \
    && grep -qa "macosx${SDK_VER}" "$DEPS/Defaults.swiftmodule/arm64-apple-macos.swiftmodule" 2>/dev/null
}
if ! deps_up_to_date; then
  log "构建 SPM 依赖（release, SDK macosx${SDK_VER}）"
  if [[ ! -d "$VENDOR_DEFAULTS" ]]; then
    mkdir -p "$LEAN/vendor"
    git clone https://github.com/sindresorhus/Defaults "$VENDOR_DEFAULTS"
    # 与 Fire.xcodeproj 的 Package.resolved 对齐（branch main @ 3efef5a）
    git -C "$VENDOR_DEFAULTS" checkout 3efef5a28ebdbbe922d4a2049493733ed14475a6
  fi
  rm -rf "$LEAN/deps/out" "$MODULE_CACHE" && mkdir -p "$MODULE_CACHE"
  SHIM_BUILD_FLAG=()
  [[ ${#SHIM_FLAG[@]} -gt 0 ]] && SHIM_BUILD_FLAG=(-Xswiftc -F -Xswiftc "$SHIM_DIR")
  swift build \
    --package-path "$PROJECT_ROOT/scripts/lean-build" \
    --scratch-path "$LEAN/deps" \
    -c release \
    ${SHIM_BUILD_FLAG[@]+"${SHIM_BUILD_FLAG[@]}"} \
    > "$LEAN/deps-build.log" 2>&1 || { tail -50 "$LEAN/deps-build.log"; exit 1; }
fi
[[ -f "$DEPS/Defaults.o" ]] || { echo "缺少 $DEPS/Defaults.o，SPM 依赖构建失败"; exit 1; }

# -----------------------------------------------------------------------------
# 2. sqlcipher amalgamation（App 目标）与 TableBuilder 工具
# -----------------------------------------------------------------------------
SQLCIPHER_DEFS=(-DSQLITE_HAS_CODEC -DSQLITE_TEMP_STORE=3 -DSQLCIPHER_CRYPTO_CC)
if [[ "$CONFIG" == "Release" ]]; then
  C_OPT=(-Os -DNDEBUG)
else
  C_OPT=(-O0 -g -DDEBUG=1)
fi

if [[ ! -f "$OUT/sqlite3-app.o" || Fire/SQLCipher/sqlite3.c -nt "$OUT/sqlite3-app.o" ]]; then
  log "编译 sqlite3.c (sqlcipher, App)"
  clang -c Fire/SQLCipher/sqlite3.c "${SQLCIPHER_DEFS[@]}" "${C_OPT[@]}" -w \
    -target "$TRIPLE" -isysroot "$SDK" -o "$OUT/sqlite3-app.o"
fi

log "编译 TableBuilder（词库构建工具）"
if [[ ! -f "$OUT/tb-sqlite3.o" || TableBuilder/SQLCipher/sqlite3.c -nt "$OUT/tb-sqlite3.o" ]]; then
  clang -c TableBuilder/SQLCipher/sqlite3.c "${SQLCIPHER_DEFS[@]}" "${C_OPT[@]}" -w \
    -target "$TRIPLE" -isysroot "$SDK" -o "$OUT/tb-sqlite3.o"
fi
clang++ -c TableBuilder/main.cpp "${SQLCIPHER_DEFS[@]}" "${C_OPT[@]}" -w \
  -std=gnu++17 -I TableBuilder \
  -target "$TRIPLE" -isysroot "$SDK" -o "$OUT/tb-main.o"
clang++ "$OUT/tb-main.o" "$OUT/tb-sqlite3.o" -framework Security \
  -framework CoreFoundation \
  -target "$TRIPLE" -isysroot "$SDK" -o "$OUT/TableBuilder"

# -----------------------------------------------------------------------------
# 3. Swift 主二进制
# -----------------------------------------------------------------------------
SWIFT_OPT=(-O -wmo)
[[ "$CONFIG" != "Release" ]] && SWIFT_OPT=(-Onone -g -D DEBUG)

log "编译 Fire ($CONFIG, $TRIPLE)"
# macOS 自带 bash 3.2 没有 mapfile，用 read 循环收集（不要开 globstar）
SWIFT_FILES=()
while IFS= read -r f; do SWIFT_FILES+=("$f"); done < <(find Fire -name '*.swift' | LC_ALL=C sort)
# -Xcc -DSQLITE_HAS_CODEC: 桥接头里 sqlcipher 的 sqlite3_key 等声明在该宏守护内
#   （Xcode 通过 OTHER_CFLAGS 把同一定义喂给 importer）；
# -D LEAN_BUILD: 跳过 #Preview 成员声明（PreviewsMacros 插件不随 CLT 分发）。
swiftc \
  -swift-version 5 -module-name "$PRODUCT_NAME" \
  -target "$TRIPLE" -sdk "$SDK" \
  ${SHIM_FLAG[@]+"${SHIM_FLAG[@]}"} \
  -module-cache-path "$MODULE_CACHE" \
  -import-objc-header Fire/Bridging-Header.h \
  -D LEAN_BUILD \
  -Xcc -DSQLITE_HAS_CODEC \
  -Xcc -DSQLCIPHER_CRYPTO_CC \
  -I "$DEPS" -F "$DEPS" \
  "${SWIFT_OPT[@]}" \
  "${SWIFT_FILES[@]}" "$OUT/sqlite3-app.o" \
  "$DEPS/Defaults.o" "$DEPS/KeychainSwift.o" "$DEPS/NanoID.o" \
  -framework Sparkle -framework Security \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$OUT/Fire"

# -----------------------------------------------------------------------------
# 4. 组装 .app bundle
# -----------------------------------------------------------------------------
log "组装 $BUILD_APP"
rm -rf "$BUILD_APP"
CONTENTS="$BUILD_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp "$OUT/Fire" "$CONTENTS/MacOS/Fire"
cp "$OUT/TableBuilder" "$CONTENTS/MacOS/TableBuilder"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Info.plist：展开 pbxproj 变量（与 xcodebuild 产物等价的展开值）
# 注意 pbxproj 里 INFOPLIST_KEY_NSMainNibFile=MainMenu 并不会写进
# GENERATE_INFOPLIST_FILE=NO 工程的 Info.plist（对比官方 pkg 产物确认）。
# xcodebuild 产物仍带 Resources/MainMenu.nib，AppKit 默认加载它接 delegate；
# lean 产物无 nib，delegate 由 AppDelegate 的 #if LEAN_BUILD main() 接上。
LC_ALL=C sed \
  -e 's/\$(DEVELOPMENT_LANGUAGE)/en/g' \
  -e "s/\$(EXECUTABLE_NAME)/$PRODUCT_NAME/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" \
  -e "s/\$(PRODUCT_NAME)/$PRODUCT_NAME/g" \
  -e "s/\$(PRODUCT_MODULE_NAME)/$PRODUCT_NAME/g" \
  -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$MIN_MACOS/g" \
  Fire/Info.plist > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" > /dev/null

# 资源（与已安装 bundle 的资源清单一一对应）
clonecp Fire/Resources/sentence-ngram-mobile.bin "$CONTENTS/Resources/"
clonecp Fire/Resources/ll_div.txt "$CONTENTS/Resources/"
cp Fire/Resources/fire.pdf "$CONTENTS/Resources/" 2>/dev/null \
  || clonecp Fire/fire.pdf "$CONTENTS/Resources/"
ditto Fire/Resources/schemas "$CONTENTS/Resources/schemas"
ditto Fire/en.lproj "$CONTENTS/Resources/en.lproj"
ditto Fire/zh-Hans.lproj "$CONTENTS/Resources/zh-Hans.lproj"
[[ -f Fire/Credits.html ]] && cp Fire/Credits.html "$CONTENTS/Resources/"

# AppIcon.icns（iconutil，替代 actool；CFBundleIconFile 本来就指 icns）
# 注意：xcassets 里的 *-mac.png 实为 WebP 编码（actool 宽容、iconutil 拒收），
# 先用 sips 统一转成真 PNG 再按标准 iconset 命名生成。
ICON_SRC="Fire/Assets.xcassets/AppIcon.appiconset"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
sips -s format png "$ICON_SRC/1024-mac.png" --out "$OUT/AppIcon-1024.png" >/dev/null
gen_icon() { sips -s format png -Z "$1" "$OUT/AppIcon-1024.png" --out "$ICONSET/$2" >/dev/null; }
gen_icon 16   icon_16x16.png
gen_icon 32   icon_16x16@2x.png
gen_icon 32   icon_32x32.png
gen_icon 64   icon_32x32@2x.png
gen_icon 128  icon_128x128.png
gen_icon 256  icon_128x128@2x.png
gen_icon 256  icon_256x256.png
gen_icon 512  icon_256x256@2x.png
gen_icon 512  icon_512x512.png
gen_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# Sparkle.framework（SPM binary artifact，已由 swift build 产出 universal）
ditto "$DEPS/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"

# ad-hoc 签名（先内后外；发布用真实证书仍走 scripts/a_build_app.sh 的 xcodebuild 流程）
log "ad-hoc 签名"
SPARKLE_RES="$CONTENTS/Frameworks/Sparkle.framework/Versions/A/Resources"
find "$SPARKLE_RES" -maxdepth 1 -name "*.xpc" -print0 2>/dev/null \
  | xargs -0 -n1 codesign --force --sign - || true
[[ -d "$SPARKLE_RES/Autoupdate.app" ]] \
  && codesign --force --sign - "$SPARKLE_RES/Autoupdate.app" || true
codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign - "$BUILD_APP"

log "构建完成: $BUILD_APP"
du -sh "$BUILD_APP" | sed 's/^/    /'
