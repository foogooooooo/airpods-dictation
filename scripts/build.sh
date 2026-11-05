#!/bin/zsh
# 编译 build/QuickVoice.app (菜单栏显示名: 快捷录音)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/QuickVoice.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -swift-version 5 -O -target arm64-apple-macos26.0 \
  -o "$APP/Contents/MacOS/QuickVoice" App/*.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.kuaijieluyin.quickvoice</string>
  <key>CFBundleName</key><string>快捷录音</string>
  <key>CFBundleDisplayName</key><string>快捷录音</string>
  <key>CFBundleExecutable</key><string>QuickVoice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>用 AirPods 麦克风录下你说的话并转成文字</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>在本机把录音转成文字</string>
</dict>
</plist>
PLIST

# 有 Apple Development 证书就用它签 (辅助功能权限在重新编译后不会失效), 否则 ad-hoc
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built $APP (signed: ${IDENTITY:-ad-hoc})"
