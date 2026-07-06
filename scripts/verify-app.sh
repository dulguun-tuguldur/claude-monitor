#!/usr/bin/env bash
# ABOUTME: Asserts the built "Claude Monitor.app" is signed with the stable pinned
# ABOUTME: identity (expected DR) and that its Info.plist matches the VERSION file.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Claude Monitor.app"
BUNDLE_ID="mn.tanasoft.claude-monitor"
IDENTITY="claude-monitor-signing"
PLIST="$APP/Contents/Info.plist"

fail() { echo "verify-app: FAIL: $*" >&2; exit 1; }

[ -d "$APP" ] || fail "$APP not found — run 'make app' first"
[ -x "$APP/Contents/MacOS/ClaudeMonitor" ] || fail "executable missing from bundle"

codesign --verify --strict "$APP" || fail "codesign --verify --strict rejected the bundle"

info=$(codesign -dvv "$APP" 2>&1)
echo "$info" | grep -q "^Identifier=$BUNDLE_ID\$" || fail "identifier is not $BUNDLE_ID"

# Identity/DR checks pin the signature to the self-signed cert so Keychain
# "Always Allow" grants persist. Only an explicit ad-hoc override skips them.
if [ "${CM_SIGN_IDENTITY:-}" = "-" ]; then
    echo "verify-app: WARNING: CM_SIGN_IDENTITY=- set — skipping identity checks." >&2
    echo "verify-app: WARNING: ad-hoc builds re-prompt for Keychain access every launch." >&2
else
    if echo "$info" | grep -q "flags=0x2 (adhoc)\|flags=0x2(adhoc)"; then
        fail "bundle is ad-hoc signed — 'Always Allow' will not persist (see docs/signing.md)"
    fi
    echo "$info" | grep -q "^Authority=$IDENTITY\$" || fail "signing authority is not $IDENTITY"
    dr=$(codesign -d -r- "$APP" 2>/dev/null)
    echo "$dr" | grep -q "identifier \"$BUNDLE_ID\" and certificate leaf = H\"" \
        || fail "designated requirement lacks the identifier + certificate-leaf pin"
    cert_sha1=$(security find-certificate -c "$IDENTITY" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3}')
    [ -n "$cert_sha1" ] || fail "certificate $IDENTITY not found in keychain (see docs/signing.md)"
    echo "$dr" | grep -qi "H\"$cert_sha1\"" || fail "DR certificate hash does not match the $IDENTITY certificate"
fi

[ -f VERSION ] || fail "VERSION file missing at repo root"
version=$(cat VERSION)
plist_short=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST" 2>/dev/null) \
    || fail "CFBundleShortVersionString missing"
[ "$plist_short" = "$version" ] || fail "CFBundleShortVersionString '$plist_short' != VERSION '$version'"
plist_build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST" 2>/dev/null) \
    || fail "CFBundleVersion missing"
[ "$plist_build" = "$version" ] || fail "CFBundleVersion '$plist_build' != VERSION '$version'"
[ "$(/usr/libexec/PlistBuddy -c "Print LSUIElement" "$PLIST")" = "true" ] || fail "LSUIElement not true"
[ "$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")" = "13.0" ] \
    || fail "LSMinimumSystemVersion is not 13.0"

echo "verify-app: PASS ($APP version $version)"
