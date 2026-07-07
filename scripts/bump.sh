#!/usr/bin/env bash
# ABOUTME: Derives the next semver from conventional commits via git-cliff,
# ABOUTME: rewrites VERSION + CHANGELOG.md, and commits chore(release): vX.Y.Z.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "bump: FAIL: $*" >&2; exit 1; }

command -v git-cliff >/dev/null 2>&1 || fail "git-cliff not installed (brew install git-cliff)"
if [ -n "$(git status --porcelain)" ]; then fail "working tree not clean"; fi

# git-cliff derives the next version from tags; the first release has none and
# is cut directly with 'make release' (see docs/releasing.md). Refuse rather
# than guess a version.
if ! git tag --list 'v[0-9]*' | grep -q .; then
    fail "no prior release tag — this is the first release; skip bump and run 'make release' (see docs/releasing.md)"
fi

NEXT=$(git cliff --bumped-version 2>/dev/null | sed 's/^v//')
[ -n "$NEXT" ] || fail "could not compute next version"

echo "$NEXT" > VERSION
git cliff --bump -o CHANGELOG.md

git add VERSION CHANGELOG.md
git commit -m "chore(release): v$NEXT"
echo "bump: VERSION=$NEXT, CHANGELOG.md regenerated, committed chore(release): v$NEXT"
