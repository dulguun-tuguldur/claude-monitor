#!/usr/bin/env bash
# ABOUTME: Builds, verifies, zips, and publishes a signed Claude Monitor release to
# ABOUTME: GitHub Releases, optionally syncing the Homebrew tap cask version/sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi

VERSION=$(cat VERSION)
TAG="v$VERSION"
ZIP="dist/ClaudeMonitor-$VERSION.zip"

fail() { echo "release: FAIL: $*" >&2; exit 1; }

# Preconditions: releases are cut from a clean tree, signed with the pinned
# identity (never ship ad-hoc), onto a tag that doesn't exist yet.
if [ -n "$(git status --porcelain)" ]; then fail "working tree not clean"; fi
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"claude-monitor-signing"'; then
    fail "claude-monitor-signing identity not found (see docs/signing.md)"
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "tag $TAG already exists"; fi

bash scripts/make-app.sh
bash scripts/verify-app.sh

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "Claude Monitor.app" "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "release: artifact $ZIP"
echo "release: sha256  $SHA256"

if [ "$DRY_RUN" = "1" ]; then
    echo "release: DRY RUN — skipping: gh release create $TAG"
else
    gh release create "$TAG" "$ZIP" --title "Claude Monitor $VERSION" \
        --notes "Signed (self-signed identity), un-notarized. See the README for install and first-launch steps."
fi

# Cask sync: rewrite version/sha256 in the tap's cask. Dry runs edit a temp
# copy so the real tap is untouched; real runs still never push the tap.
if [ -n "${CM_TAP_DIR:-}" ]; then
    CASK="$CM_TAP_DIR/Casks/claude-monitor.rb"
    if [ ! -f "$CASK" ]; then fail "cask not found at $CASK"; fi
    TARGET="$CASK"
    if [ "$DRY_RUN" = "1" ]; then
        TARGET="$(mktemp -d)/claude-monitor.rb"
        cp "$CASK" "$TARGET"
    fi
    sed -i '' -e "s|^  version \".*\"|  version \"$VERSION\"|" \
              -e "s|^  sha256 \".*\"|  sha256 \"$SHA256\"|" "$TARGET"
    echo "release: cask updated: $TARGET"
    if [ "$DRY_RUN" != "1" ]; then
        echo "release: review, commit, and push the tap manually."
    fi
fi

echo "release: DONE ($TAG)"
