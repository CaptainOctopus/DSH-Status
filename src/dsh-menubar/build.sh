#!/usr/bin/env bash
# =============================================================================
# build.sh —— 编译并打包「自包含」DSH Status 菜单栏应用 + 生成可分发 .dmg
#
# 设计目标：产出一个不依赖本机 WorkBuddy 安装路径的安装包。
#   - 所有脚本 / 网页前端 / python 解释器都内联进 .app/Contents/Resources/
#   - app 用 [[NSBundle mainBundle] resourcePath] 定位它们，可拷到任意 Mac
#   - 首次运行自动注册 LaunchAgent（登录自启），无需安装器
#
# 用法:
#   bash build.sh                # 编译 + 打包自包含 .app + 生成 DSH-Status.dmg
#   bash build.sh --install-local# 额外把 .app 装到 ~/Applications 并启动（本机用）
# =============================================================================
set -uo pipefail

# 脚本位置即源码根（可移植，不再写死绝对路径）
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SRC_DIR")"          # 项目根 = .../2026-08-28-23-12-48
APP_NAME="DSH Status"
BUNDLE_ID="com.rory.dshstatus"

# 内联 python 来源（本机 managed python，已验证可整体搬迁）
PY_SRC="$HOME/.workbuddy/binaries/python/versions/3.13.12"

# 输出目录与产物
DIST="$ROOT_DIR/dist"
APP_DIR="$DIST/$APP_NAME.app"
DMG="$(dirname "$ROOT_DIR")/DSH-Status.dmg"   # 安装包留在项目根（src/ 之外）

DO_INSTALL_LOCAL=0
[ "${1:-}" = "--install-local" ] && DO_INSTALL_LOCAL=1

echo "==> [1/6] 编译 Objective-C 源码"
cd "$SRC_DIR" || exit 1
clang -fobjc-arc -framework Cocoa -O2 -Wall DSHStatus.m -o DSHStatus
if [ ! -f DSHStatus ]; then echo "    ✗ 编译失败"; exit 1; fi
echo "    ✓ 编译成功 ($(wc -c < DSHStatus) bytes)"

echo "==> [2/6] 组装自包含 .app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp DSHStatus "$APP_DIR/Contents/MacOS/DSHStatus"
# 内联资源整合
cp "$SRC_DIR/../dsh-manager.sh"      "$APP_DIR/Contents/Resources/dsh-manager.sh"
cp "$SRC_DIR/../dsh-web-control.py"  "$APP_DIR/Contents/Resources/dsh-web-control.py"
cp "$SRC_DIR/../dsh-control.html"    "$APP_DIR/Contents/Resources/dsh-control.html"
chmod +x "$APP_DIR/Contents/Resources/dsh-manager.sh" "$APP_DIR/Contents/Resources/dsh-web-control.py"
echo "    ✓ 脚本/html 已内联到 Contents/Resources/"

echo "==> [2.5] 应用图标（AppIcon.icns，含 16~1024 各尺寸）"
if [ -f "$SRC_DIR/AppIcon.icns" ]; then
  cp "$SRC_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "    ✓ AppIcon.icns 已内联"
else
  echo "    ⚠ 未找到 AppIcon.icns（先跑 make_icon.py 生成）"
fi

echo "==> [3/6] 内联 python 解释器 (~59MB, 仅 stdlib)"
rm -rf "$APP_DIR/Contents/Resources/python"
cp -R "$PY_SRC" "$APP_DIR/Contents/Resources/python"
chmod -R u+w "$APP_DIR/Contents/Resources/python"
echo "    ✓ python 已内联"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>DSHStatus</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>11.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>LSUIElement</key>                <true/>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
</dict>
</plist>
PLIST
echo "    ✓ $APP_DIR"

echo "==> [4/6] ad-hoc 签名（跨机拷入后本地运行所需）"
if codesign -s - --force --deep "$APP_DIR" 2>/dev/null; then
    echo "    ✓ 已签名"
else
    echo "    ⚠ 签名失败（本地运行一般不受影响；跨机首跑可执行 xattr -dr 解除隔离）"
fi

echo "==> [5/6] 生成标准『拖拽安装』.dmg（含 Applications 快捷方式）"
rm -f "$DMG"

# 暂存目录：只放 .app + 一个指向 /Applications 的快捷方式（拖拽目标）
STAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
echo "    ✓ 暂存盘内容：$(ls "$STAGE")"

# 直接用源目录生成压缩只读 dmg（盘符内两个图标：app + Applications）
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" 2>&1 | tail -3
rm -rf "$STAGE"

if [ -f "$DMG" ]; then
    echo "    ✓ $DMG ($(du -h "$DMG" | cut -f1))"
else
    echo "    ✗ dmg 生成失败"
fi

echo "==> [6/6] 完成"
if [ "$DO_INSTALL_LOCAL" -eq 1 ]; then
    echo "    安装到本机 ~/Applications 并启动..."
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "$HOME/Applications/$APP_NAME.app"
    codesign -s - --force --deep "$HOME/Applications/$APP_NAME.app" 2>/dev/null
    open -a "$HOME/Applications/$APP_NAME.app"
    sleep 2
    pgrep -f "DSHStatus" >/dev/null 2>&1 && echo "    ✓ 已在菜单栏运行" || echo "    ⚠ 未检测到进程"
fi

echo ""
echo "=============== 交付物 ==============="
echo "自包含 app:  $APP_DIR"
echo "安装包 dmg:  $DMG"
echo "安装方式:    把 DSH-Status.dmg 拷到目标 Mac → 打开 → 拖 DSH Status.app 到 应用程序"
echo "             （首次运行自动注册登录自启；无需 WorkBuddy / python / node）"
echo "卸载:        launchctl bootout gui/\$(id -u)/$BUNDLE_ID; rm -rf '/Applications/DSH Status.app' ~/'Applications/DSH Status.app'"
