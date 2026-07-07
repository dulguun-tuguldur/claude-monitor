#!/usr/bin/env bash
# ABOUTME: End-to-end test for new-account.sh: validation errors, copy
# ABOUTME: correctness against a fixture base dir, and real-app discovery.
set -euo pipefail
cd "$(dirname "$0")/.."

FAKEROOT=$(mktemp -d)
cleanup() { rm -rf "$FAKEROOT"; }
trap cleanup EXIT

fail() { echo "new-account-e2e: FAIL: $*" >&2; exit 1; }

BASE="$FAKEROOT/.claude"
mkdir -p "$BASE/skills/foo" "$BASE/hooks" \
         "$BASE/plugins/marketplaces/mkt" "$BASE/plugins/cache" "$BASE/plugins/data"
echo '{"model":"sonnet"}' > "$BASE/settings.json"
echo '# skill' > "$BASE/skills/foo/SKILL.md"
echo 'echo hi' > "$BASE/hooks/bar.sh"
echo '{"plugins":[]}' > "$BASE/plugins/installed_plugins.json"
echo '{"marketplaces":[]}' > "$BASE/plugins/known_marketplaces.json"
echo 'content' > "$BASE/plugins/marketplaces/mkt/x"
echo 'stale-cache' > "$BASE/plugins/plugin-catalog-cache.json"
echo 'stale' > "$BASE/plugins/cache/entry"
echo 'stale' > "$BASE/plugins/data/entry"
echo 'history-line' > "$BASE/history.jsonl"
mkdir -p "$BASE/sessions"
echo 'session' > "$BASE/sessions/s1"
python3 - "$BASE/.claude.json" <<'PY'
import json, sys
data = {
    "mcpServers": {"example": {"command": "echo"}},
    "oauthAccount": {"accountUuid": "base-uuid"},
    "userID": "base-user",
    "machineID": "base-machine",
    "projects": {"/some/path": {}},
}
json.dump(data, open(sys.argv[1], "w"))
PY

### Validation cases ###

if bash scripts/new-account.sh 2>/dev/null; then fail "missing name should fail"; fi
if CM_CLAUDE_ROOT="$FAKEROOT" bash scripts/new-account.sh 'bad name!' 2>/dev/null; then
    fail "invalid name should fail"
fi
if CM_CLAUDE_ROOT="$FAKEROOT" bash scripts/new-account.sh probe "$FAKEROOT/.claude-nope" 2>/dev/null; then
    fail "missing base dir should fail"
fi

mkdir -p "$FAKEROOT/.claude-existing"
echo '{}' > "$FAKEROOT/.claude-existing/.claude.json"
if CM_CLAUDE_ROOT="$FAKEROOT" bash scripts/new-account.sh existing "$BASE" 2>/dev/null; then
    fail "pre-existing dest should fail"
fi

### Copy correctness ###

CM_CLAUDE_ROOT="$FAKEROOT" bash scripts/new-account.sh probe "$BASE"

DEST="$FAKEROOT/.claude-probe"
[ -d "$DEST" ] || fail "dest dir not created"
[ -f "$DEST/settings.json" ] || fail "settings.json not copied"
[ -f "$DEST/skills/foo/SKILL.md" ] || fail "skills not copied"
[ -f "$DEST/hooks/bar.sh" ] || fail "hooks not copied"
[ -f "$DEST/plugins/installed_plugins.json" ] || fail "plugin manifest not copied"
[ -f "$DEST/plugins/known_marketplaces.json" ] || fail "known_marketplaces not copied"
[ -f "$DEST/plugins/marketplaces/mkt/x" ] || fail "marketplaces not copied"

[ -e "$DEST/plugins/plugin-catalog-cache.json" ] && fail "plugin cache should not be copied"
[ -e "$DEST/plugins/cache" ] && fail "plugins/cache should not be copied"
[ -e "$DEST/plugins/data" ] && fail "plugins/data should not be copied"
[ -e "$DEST/history.jsonl" ] && fail "history.jsonl should not be copied"
[ -e "$DEST/sessions" ] && fail "sessions should not be copied"

[ -f "$DEST/.claude.json" ] || fail ".claude.json not created"
python3 - "$DEST/.claude.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("mcpServers") == {"example": {"command": "echo"}}, "mcpServers missing/wrong"
assert "oauthAccount" not in data, "oauthAccount leaked"
assert "userID" not in data, "userID leaked"
assert "machineID" not in data, "machineID leaked"
assert "projects" not in data, "projects leaked"
assert set(data.keys()) == {"mcpServers"}, f"unexpected keys: {data.keys()}"
PY

### Real-app discovery ###

swift build
OUT=$(CM_CLAUDE_ROOT="$FAKEROOT" .build/debug/ClaudeMonitor --print-once)
echo "$OUT"
echo "$OUT" | grep -q "probe" || fail "monitor did not discover the new account"

echo "NEW-ACCOUNT E2E PASS"
