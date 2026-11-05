#!/bin/zsh
# 编译 AirPods 探针为 build/Probe.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Probe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/Probe" Probe/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.kuaijieluyin.probe</string>
  <key>CFBundleName</key><string>Probe</string>
  <key>CFBundleExecutable</key><string>Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>探针需要麦克风来检测 AirPods 静音手势</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
