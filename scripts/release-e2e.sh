#!/usr/bin/env bash
# ABOUTME: E2E for release.sh --dry-run in a throwaway clone: asserts the zip,
# ABOUTME: sha256, temp-cask rewrite, and changelog-sourced notes; no real release.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "release-e2e: FAIL: $*" >&2; exit 1; }

# Hermetic clone so the real repo, working tree, and tags are never touched.
CLONE="$WORK/repo"
git clone -q "$REPO" "$CLONE"
# Overlay the working-tree files under test so we exercise uncommitted changes.
cp "$REPO/scripts/release.sh" "$CLONE/scripts/release.sh"
[ -f "$REPO/cliff.toml" ] && cp "$REPO/cliff.toml" "$CLONE/cliff.toml"
cd "$CLONE"
git config user.email e2e@test
git config user.name e2e
# Throwaway version so v0.0.0-e2e never collides with a real tag and the
# clean-tree gate holds.
echo "0.0.0-e2e" > VERSION
git add -A
git commit -q -m "chore: e2e setup"

# Temp tap with a sentinel cask to prove version/sha256 are rewritten. The two
# leading spaces on version/sha256 match release.sh's sed anchors.
TAP="$WORK/tap"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/claude-monitor.rb" <<'RUBY'
cask "claude-monitor" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  app "Claude Monitor.app"
end
RUBY

OUT=$(CM_TAP_DIR="$TAP" bash scripts/release.sh --dry-run)
echo "$OUT"

ZIP="dist/ClaudeMonitor-0.0.0-e2e.zip"
[ -f "$ZIP" ] || fail "zip artifact not produced"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

CASK_TMP=$(echo "$OUT" | sed -n 's/^release: cask updated: //p')
[ -n "$CASK_TMP" ] && [ -f "$CASK_TMP" ] || fail "dry-run temp cask not found in output"
grep -q 'version "0.0.0-e2e"' "$CASK_TMP" || fail "temp cask version not synced"
grep -q "sha256 \"$SHA\"" "$CASK_TMP" || fail "temp cask sha256 not synced"

# Notes must come from the generated changelog (version header), not the static
# fallback string.
echo "$OUT" | grep -q '## \[0.0.0-e2e\]' || fail "release notes not sourced from changelog"

# Dry run must not create a tag.
if git rev-parse -q --verify refs/tags/v0.0.0-e2e >/dev/null; then
    fail "dry run created a tag"
fi

echo "RELEASE E2E PASS"
