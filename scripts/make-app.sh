#!/usr/bin/env bash
# ABOUTME: Bundles the release binary into "Claude Monitor.app" (LSUIElement, signed
# ABOUTME: with the stable claude-monitor-signing identity, ad-hoc fallback).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
# CM_SIGN_IDENTITY overrides; else the pinned self-signed cert (docs/signing.md);
# else ad-hoc — which re-prompts for Keychain access every launch.
if [ -n "${CM_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$CM_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q '"claude-monitor-signing"'; then
    IDENTITY="claude-monitor-signing"
else
    IDENTITY="-"
    echo "make-app: WARNING: claude-monitor-signing identity not found — ad-hoc signing." >&2
    echo "make-app: WARNING: Keychain 'Always Allow' will not persist (see docs/signing.md)." >&2
fi
swift build -c release
APP="Claude Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeMonitor "$APP/Contents/MacOS/ClaudeMonitor"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeMonitor</string>
    <key>CFBundleIdentifier</key><string>mn.tanasoft.claude-monitor</string>
    <key>CFBundleName</key><string>Claude Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "$IDENTITY" "$APP"
echo "Built: $APP  (install: cp -R into /Applications)"
