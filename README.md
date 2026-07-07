# Claude Monitor

A native macOS menu bar app that shows Claude Code account usage — session,
week, and week-Sonnet percentages — for every account you run via
`CLAUDE_CONFIG_DIR` aliases, all in one glance. No more running `/usage` in
each account's Claude Code session by hand.

<!-- screenshot: menu bar showing "✳ 42·18·9" and the account dropdown with
     per-account rows (session / week / week-sonnet) -->

## Install

### Homebrew (recommended)

```sh
brew tap dulguun-tuguldur/tap
brew install --cask claude-monitor
```

Claude Monitor is self-signed and not notarized, so on first launch macOS
Gatekeeper will refuse to open it. To open it the first time, right-click
**Claude Monitor** in `/Applications`, choose **Open**, then **Open** again in
the dialog (or use System Settings > Privacy & Security > "Open Anyway"). This
is a one-time step per installed version.

Then launch it from `/Applications` and open the Settings window from the menu
bar item if you want "Launch at Login".

### Build from source

```sh
make app
cp -R "Claude Monitor.app" /Applications/
```

`make app` produces `Claude Monitor.app` in the repo root — a release build,
signed with the self-signed `claude-monitor-signing` identity (see
`docs/signing.md`), `LSUIElement` so it runs with no Dock icon.

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

## Provisioning a new account

To add another Claude Code account for the monitor to track:

```sh
make new-account NAME=<name> [FROM=~/.claude-<base-account>]
```

This scaffolds `~/.claude-<name>` by cloning the base account's
`settings.json` (notifications included), skills, hooks, plugin manifests
and marketplaces, and user-scoped MCP server config. It deliberately does
**not** copy login credentials or session state (history, projects, caches,
etc.) — those stay behind so the new account starts clean.

After it runs, add the printed shell alias to your `~/.zshrc`, run it once
(or `CLAUDE_CONFIG_DIR=~/.claude-<name> claude`), and run `/login` with that
account's own Anthropic credentials. Claude Monitor shows the account as
"not logged in" until then, and picks up its usage automatically on the
next poll — no restart needed.

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
| `make bump` | Runs `scripts/bump.sh`: derives the next version + changelog from commits |
| `make test-bump` | Runs `scripts/bump-e2e.sh`: bump.sh in a throwaway repo |
| `make release` | Runs `scripts/release.sh`: build, verify, zip, publish, sync cask |
| `make test-release` | Runs `scripts/release-e2e.sh`: dry-run release in a throwaway clone |
| `make test-cask` | `brew style` on the Homebrew cask |
| `make e2e` | Runs `scripts/e2e.sh`: real binary, real (throwaway) Keychain item, stub HTTP server |
| `make app` | Runs `scripts/make-app.sh`: bundles a release build into `Claude Monitor.app` |
| `make run` | `swift run ClaudeMonitor` |
| `make new-account NAME=<name> [FROM=<base-dir>]` | Runs `scripts/new-account.sh`: scaffolds a new `~/.claude-<name>` account dir |
| `make test-new-account` | Runs `scripts/new-account-e2e.sh`: validation, copy correctness, and real-app discovery for `new-account.sh` |
