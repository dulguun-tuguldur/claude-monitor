#!/usr/bin/env bash
# ABOUTME: Scaffolds a new Claude Code account config dir by cloning a base
# ABOUTME: account's settings/skills/hooks/plugins/MCP config, minus login and session state.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "new-account: FAIL: $*" >&2; exit 1; }

NAME="${1:?usage: new-account.sh <name> [base-dir]}"
ROOT="${CM_CLAUDE_ROOT:-$HOME}"
BASE="${2:-$ROOT/.claude}"

[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid name '$NAME' (allowed: letters, digits, '.', '_', '-')"

[ -d "$BASE" ] || fail "base dir '$BASE' does not exist"
[ -f "$BASE/.claude.json" ] || fail "base dir '$BASE' has no .claude.json — not a Claude Code config dir"

DEST="$ROOT/.claude-$NAME"
[ -e "$DEST" ] && fail "'$DEST' already exists — remove it or pick a different name"

mkdir -p "$DEST"

for f in settings.json settings.local.json CLAUDE.md; do
    [ -f "$BASE/$f" ] && cp "$BASE/$f" "$DEST/$f"
done

for d in skills hooks agents commands output-styles; do
    [ -d "$BASE/$d" ] && cp -R "$BASE/$d" "$DEST/$d"
done

if [ -d "$BASE/plugins" ]; then
    mkdir -p "$DEST/plugins"
    for f in installed_plugins.json known_marketplaces.json; do
        [ -f "$BASE/plugins/$f" ] && cp "$BASE/plugins/$f" "$DEST/plugins/$f"
    done
    [ -d "$BASE/plugins/marketplaces" ] && cp -R "$BASE/plugins/marketplaces" "$DEST/plugins/marketplaces"
fi

python3 - "$BASE/.claude.json" "$DEST/.claude.json" <<'PY'
import json, sys
base_path, dest_path = sys.argv[1], sys.argv[2]
base = json.load(open(base_path))
json.dump({"mcpServers": base.get("mcpServers", {})}, open(dest_path, "w"))
PY

CLAUDE_BIN="$(command -v claude || echo claude)"

echo "new-account: cloned settings/skills/hooks/plugins/mcp from '$BASE' into '$DEST'"
echo "new-account: add this alias to your shell rc:"
echo "  alias claude-$NAME=\"CLAUDE_CONFIG_DIR=$DEST $CLAUDE_BIN\""
echo "new-account: next steps:"
echo "  1. run 'claude-$NAME' (or 'CLAUDE_CONFIG_DIR=$DEST claude') once"
echo "  2. run /login with the new account's own Anthropic credentials"
echo "  Claude Monitor will show '$NAME' as not logged in until then, and pick up usage on the next poll."
