#!/usr/bin/env bash
# ABOUTME: Integration test for bump.sh: in a throwaway repo, asserts the
# ABOUTME: derived version, VERSION/CHANGELOG rewrite, and no-prior-tag refusal.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "bump-e2e: FAIL: $*" >&2; exit 1; }

# Seed a throwaway repo carrying a copy of the real bump.sh + cliff.toml so
# bump.sh's `cd "$(dirname "$0")/.."` lands inside the throwaway repo.
seed_repo() {
    local dir="$1"
    mkdir -p "$dir/scripts"
    cp "$REPO/scripts/bump.sh" "$dir/scripts/bump.sh"
    cp "$REPO/cliff.toml" "$dir/cliff.toml"
    cd "$dir"
    git init -q
    git config user.email t@e2e
    git config user.name t
    export GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00"
    echo "1.0.0" > VERSION
    git add -A
    git commit -q -m "feat: initial feature"
}

### Case 1: no prior tag → refuse with guidance ###
seed_repo "$WORK/r1"
if bash scripts/bump.sh >/dev/null 2>"$WORK/err1"; then
    fail "bump should refuse without a prior tag"
fi
grep -qi "first release" "$WORK/err1" || fail "refusal should mention the first release"

### Case 2: feat since last tag → minor bump ###
seed_repo "$WORK/r2"
git cliff --config cliff.toml --tag v1.0.0 -o CHANGELOG.md
git add -A
git commit -q -m "chore: add changelog"
git tag v1.0.0
git commit -q --allow-empty -m "feat: shiny new thing"

bash scripts/bump.sh

[ "$(cat VERSION)" = "1.1.0" ] || fail "expected VERSION 1.1.0, got $(cat VERSION)"
grep -q "## \[1.1.0\]" CHANGELOG.md || fail "CHANGELOG.md missing the 1.1.0 section"
grep -q "Shiny new thing" CHANGELOG.md || fail "CHANGELOG.md missing the feat entry"
git log -1 --pretty=%s | grep -q "^chore(release): v1.1.0$" || fail "release commit subject wrong"
changed=$(git show --name-only --pretty=format: HEAD | grep -v '^$' | sort | tr '\n' ' ')
[ "$changed" = "CHANGELOG.md VERSION " ] || fail "release commit touched unexpected files: $changed"

echo "BUMP E2E PASS"
