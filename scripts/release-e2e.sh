#!/usr/bin/env bash
# ABOUTME: E2E for release.sh --dry-run in a throwaway clone: asserts the zip, sha256,
# ABOUTME: temp-cask rewrite, notes, tag target, and unpushed-HEAD refusal; no real release.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "release-e2e: FAIL: $*" >&2; exit 1; }

# Hermetic clone so the real repo, working tree, and tags are never touched. A
# local bare repo stands in for origin so the clone can push its setup commit
# and satisfy release.sh's pushed-HEAD gate.
ORIGIN="$WORK/origin.git"
git clone -q --bare "$REPO" "$ORIGIN"
CLONE="$WORK/repo"
git clone -q "$ORIGIN" "$CLONE"
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
git push -q origin HEAD

# Temp tap at the clone's sibling ($WORK/homebrew-tap) so release.sh's default
# CM_TAP_DIR (../homebrew-tap, relative to the repo root it cd's into) resolves
# here. We deliberately do NOT set CM_TAP_DIR in the environment — this is the
# exact path `make release` uses, where CM_TAP_DIR is not exported. The two
# leading spaces on version/sha256 match release.sh's sed anchors.
TAP="$WORK/homebrew-tap"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/claude-monitor.rb" <<'RUBY'
cask "claude-monitor" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  app "Claude Monitor.app"
end
RUBY

OUT=$(bash scripts/release.sh --dry-run)
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

# The tag must be created on the release commit itself, not on whatever the
# remote default branch happens to point at.
HEAD_SHA=$(git rev-parse HEAD)
echo "$OUT" | grep -q -- "--target $HEAD_SHA" || fail "gh release create not targeted at HEAD"

# Dry run must not create a tag.
if git rev-parse -q --verify refs/tags/v0.0.0-e2e >/dev/null; then
    fail "dry run created a tag"
fi

# Releasing a commit that origin doesn't have must be refused up front, before
# any build work.
git commit -q --allow-empty -m "chore: unpushed"
if UNPUSHED=$(bash scripts/release.sh --dry-run 2>&1); then
    fail "release ran with HEAD not pushed"
fi
echo "$UNPUSHED" | grep -q "HEAD is not pushed" || fail "unexpected unpushed refusal: $UNPUSHED"

echo "RELEASE E2E PASS"
