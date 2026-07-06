#!/usr/bin/env bash
# ABOUTME: End-to-end test: real binary + real keychain item + stub usage server;
# ABOUTME: asserts printed bar text for a fake account, then cleans everything up.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8765
SERVICE_PREFIX="cm-e2e-$$-"
FAKEHOME=$(mktemp -d)
SERVER_PID=""

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    security delete-generic-password -s "${SERVICE_PREFIX}e2e" >/dev/null 2>&1 || true
    rm -rf "$FAKEHOME"
}
trap cleanup EXIT

# fake account dir
mkdir -p "$FAKEHOME/.claude-e2e"
echo '{}' > "$FAKEHOME/.claude-e2e/.claude.json"

# keychain item with far-future expiry so no refresh is attempted
python3 - "$SERVICE_PREFIX" <<'PY'
import json, subprocess, sys
creds = {"claudeAiOauth": {"accessToken": "e2e-token", "refreshToken": "e2e-refresh",
                           "expiresAt": 4102444800000, "scopes": [], "subscriptionType": "max"}}
# -A: any app may read this throwaway fake-token item — avoids an ACL prompt
# for the freshly built test binary.
subprocess.run(["security", "add-generic-password", "-U", "-A",
                "-s", sys.argv[1] + "e2e", "-a", "e2e", "-w", json.dumps(creds)], check=True)
PY

# stub usage server
python3 - "$PORT" <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"five_hour": {"utilization": 42.2, "resets_at": "2026-07-05T16:00:00Z"},
                           "seven_day": {"utilization": 18.0, "resets_at": "2026-07-08T00:00:00Z"},
                           "seven_day_sonnet": {"utilization": 9.4, "resets_at": "2026-07-08T00:00:00Z"}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
SERVER_PID=$!
sleep 1

swift build
OUT=$(CM_CLAUDE_ROOT="$FAKEHOME" \
      CM_KEYCHAIN_SERVICE_PREFIX="$SERVICE_PREFIX" \
      CM_USAGE_URL="http://127.0.0.1:$PORT/usage" \
      .build/debug/ClaudeMonitor --print-once)

echo "$OUT"
echo "$OUT" | grep -q "e2e 42·18·9" && echo "E2E PASS" || { echo "E2E FAIL"; exit 1; }
