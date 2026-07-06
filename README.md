# Claude Monitor

A native macOS menu bar app that shows Claude Code account usage — session,
week, and week-Sonnet percentages — for every account you run via
`CLAUDE_CONFIG_DIR` aliases, all in one glance. No more running `/usage` in
each account's Claude Code session by hand.

<!-- screenshot: menu bar showing "✳ 42·18·9" and the account dropdown with
     per-account rows (session / week / week-sonnet) -->

## Install

1. Build the app bundle:

   ```sh
   make app
   ```

   This produces `Claude Monitor.app` in the repo root (release build,
   ad-hoc signed, `LSUIElement` so it runs with no Dock icon).

2. Install it:

   ```sh
   cp -R "Claude Monitor.app" /Applications/
   ```

3. Launch it from `/Applications`, then open the Settings window from the
   menu bar item if you want to turn on "Launch at Login".

### First-run Keychain prompt

The first time the app reads a given account's credentials, macOS may pop up
a Keychain access dialog asking whether "Claude Monitor" can access that
account's stored password item. Click **Always Allow**. This happens once
per account (not on every launch) — after that, Keychain remembers the
decision.

## Environment variable seams

These exist for testing and the E2E harness (`scripts/e2e.sh`). Normal
end users should never need to set any of them.

| Variable | Purpose |
| --- | --- |
| `CM_CLAUDE_ROOT` | Overrides the root directory scanned for `.claude*` account directories. |
| `CM_KEYCHAIN_SERVICE_PREFIX` | Overrides the Keychain service name prefix used when looking up credentials. |
| `CM_USAGE_URL` | Overrides the base URL for the usage API. |
| `CM_TOKEN_URL` | Overrides the URL used for OAuth token refresh. |

## Troubleshooting

- **"not logged in" in the account dropdown**: run that account's
  `claude-<label>` shell alias once (i.e. start a Claude Code session under
  that `CLAUDE_CONFIG_DIR`) to establish credentials in the Keychain.
- **"re-login needed"**: the stored refresh token was rejected by Anthropic.
  Run `/login` inside that account's Claude Code session to get a fresh
  token, then Claude Monitor will pick it up on its next poll.

## Build / test commands

| Command | What it does |
| --- | --- |
| `make build` | `swift build` |
| `make test` | `swift test` (unit tests for `MonitorCore`) |
| `make e2e` | Runs `scripts/e2e.sh`: real binary, real (throwaway) Keychain item, stub HTTP server |
| `make app` | Runs `scripts/make-app.sh`: bundles a release build into `Claude Monitor.app` |
| `make run` | `swift run ClaudeMonitor` |
