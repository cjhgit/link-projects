#!/bin/bash
# 构建 Release 版本并安装到 /Applications
set -e
cd "$(dirname "$0")"

APP="controller-mac.app"
SRC="build/Build/Products/Release/${APP}"
DST="/Applications/${APP}"

echo "[install] 构建 Release..."
xcodebuild \
    -project controller-mac.xcodeproj \
    -scheme controller-mac \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath build \
    -quiet

# 终止正在运行的实例，避免替换时文件被占用
if pkill -x controller-mac 2>/dev/null; then
    echo "[install] 已终止正在运行的应用"
    sleep 0.5
fi

echo "[install] 安装到 ${DST}..."
rm -rf "$DST"
cp -R "$SRC" "$DST"

echo "[install] 完成，可从「应用程序」或启动台打开"
