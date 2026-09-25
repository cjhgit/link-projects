#!/bin/bash
# 构建并运行 mac 控制端（运行前先杀掉旧进程）
set -e
cd "$(dirname "$0")"

BIN="build/Build/Products/Debug/controller-mac.app/Contents/MacOS/controller-mac"

# 杀死旧进程（按进程名精确匹配，避免误杀其他进程）
if pkill -x controller-mac 2>/dev/null; then
    echo "[run] 已终止旧进程"
    sleep 0.5
fi

echo "[run] 构建..."
xcodebuild \
    -project controller-mac.xcodeproj \
    -scheme controller-mac \
    -destination 'platform=macOS' \
    -configuration Debug \
    -derivedDataPath build \
    -quiet

echo "[run] 启动..."
# 直接运行二进制以继承环境变量（LINK_SERVER / LINK_TOKEN 可临时覆盖配置），
# 配置默认读取 ~/.link-projects/controller.env，日志见 /tmp/controller-mac.log
nohup "$BIN" > /tmp/controller-mac.log 2>&1 &
echo "[run] 已启动（pid $!，日志 /tmp/controller-mac.log）"
