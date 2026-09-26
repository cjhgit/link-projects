#!/bin/bash
# 构建并安装 link-ios 到 iPhone（免开 Xcode）
# 用法：./run.sh [设备名或标识]    缺省自动选择第一台已连接的真机
set -e
cd "$(dirname "$0")"

BUNDLE_ID="com.yunser.link-ios"
APP="build/Build/Products/Debug-iphoneos/link-ios.app"

# 选择目标设备：未指定参数时自动取第一台已连接的物理设备（排除模拟器）
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
    DEVICE=$(python3 - <<'EOF'
import json, os, subprocess, tempfile

fd, path = tempfile.mkstemp()
subprocess.run(
    ["xcrun", "devicectl", "list", "devices", "--json-output", path],
    capture_output=True,
)
try:
    data = json.load(open(path))
except Exception:
    data = {}
finally:
    os.unlink(path)

# transportType = sameMachine 的是本机模拟器，其余（wired / localNetwork）为真机
for device in data.get("result", {}).get("devices", []):
    transport = device.get("connectionProperties", {}).get("transportType")
    if transport and transport != "sameMachine":
        print(device["identifier"])
        break
EOF
)
    if [ -z "$DEVICE" ]; then
        echo "[run] 未发现已连接的 iPhone，请用数据线连接并在设备上信任本机后重试"
        exit 1
    fi
fi

echo "[run] 构建（真机 Debug，自动签名）..."
xcodebuild \
    -project link-ios.xcodeproj \
    -scheme link-ios \
    -destination 'generic/platform=iOS' \
    -configuration Debug \
    -derivedDataPath build \
    -allowProvisioningUpdates \
    -quiet

echo "[run] 安装到设备..."
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "[run] 启动..."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
echo "[run] 完成"
