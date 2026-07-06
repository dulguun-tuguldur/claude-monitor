#!/usr/bin/env bash
# ABOUTME: Bundles the release binary into "Claude Monitor.app" (LSUIElement,
# ABOUTME: ad-hoc signed) so it can run without a Dock icon and launch at login.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="Claude Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeMonitor "$APP/Contents/MacOS/ClaudeMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeMonitor</string>
    <key>CFBundleIdentifier</key><string>mn.tanasoft.claude-monitor</string>
    <key>CFBundleName</key><string>Claude Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP  (install: cp -R into /Applications)"
