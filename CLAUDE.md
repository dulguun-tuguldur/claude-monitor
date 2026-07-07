# Claude Monitor

Assistant name for this project: **FRIDAY**.

## What this is

Claude Monitor is a native macOS menu bar app that shows Claude Code account
usage percentages at a glance. Mr. D runs six separate Claude Code accounts
(via `CLAUDE_CONFIG_DIR` aliases), each with its own usage quotas (5-hour
window, 7-day window, and per-model 7-day windows for Sonnet/Opus). This app
polls each account's usage and surfaces all of them in the menu bar so
nobody has to go check each account by hand.

## Architecture

This is a Swift Package Manager package with two targets, deliberately kept
separate so the logic can be tested without touching AppKit/SwiftUI:

- `Sources/MonitorCore` — UI-free library. Owns usage-response parsing,
  credential file handling, token refresh logic, and anything else that can
  be unit tested in isolation.
- `Sources/ClaudeMonitor` — thin executable target (AppKit/SwiftUI) that
  wires `MonitorCore` up to a menu bar item. Kept as thin as possible; if
  logic can live in `MonitorCore` instead, it belongs there.
- `Tests/MonitorCoreTests` — tests for `MonitorCore`, backed by JSON
  fixtures under `Tests/MonitorCoreTests/Fixtures/`.

## Build / test commands

- `make test` — run the test suite.
- `make e2e` — run end-to-end tests.
- `make run` — run the app from source (`swift run`).
- `make app` — build a distributable `.app` bundle.
- `make new-account NAME=<name> [FROM=<base-dir>]` — scaffold a new
  `~/.claude-<name>` account config dir (`scripts/new-account.sh`).
- `make test-new-account` — test the account-provisioning script
  (`scripts/new-account-e2e.sh`).

(Note: the `Makefile` backing these targets is added in a later task; Task 0
only establishes the SPM package skeleton itself. Until then, use
`swift build` / `swift test` / `swift run` directly.)

## Docs

- Implementation plan: `docs/superpowers/plans/2026-07-05-claude-monitor.md`
- Design spec: `docs/superpowers/specs/2026-07-05-claude-monitor-design.md`
- Spike results (Keychain / live usage API capture): `docs/superpowers/specs/spike-results.md`

See those documents for the why, the locked decisions, and the full
multi-task plan this project is being built against.
