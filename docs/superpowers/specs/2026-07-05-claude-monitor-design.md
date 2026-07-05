# Claude Monitor — Design Spec (2026-07-05)

**Goal:** A native macOS menu bar app showing the selected Claude Code account's session / weekly / Sonnet usage percentages, with a dropdown to view and switch between all six accounts and a settings window.

**Architecture:** Swift Package (no Xcode project) with a UI-free `MonitorCore` library (account discovery, Keychain, OAuth refresh, usage API, formatting, polling) and a thin `ClaudeMonitor` executable (AppKit `NSStatusItem` + `NSMenu`, SwiftUI settings window). A script bundles the release binary into `Claude Monitor.app` for launch-at-login.

**Tech Stack:** Swift 5.9+ (SPM), AppKit + SwiftUI, Security.framework (Keychain), XCTest, bash + python3 for the E2E stub server.

---

## Context (why this exists)

Mr. D runs **six Claude Code accounts** via `CLAUDE_CONFIG_DIR` aliases (`claude-me`, `claude-tergel`, …) to spread usage across subscriptions. Deciding *which* account to use next means running `/usage` inside each one. This app puts the `/usage` numbers for all accounts in the menu bar: the selected account renders as `✳ 42·18·9` (session% · week% · sonnet%), the dropdown lists every account, clicking an account makes it the bar account, and Settings configures interval/hidden accounts/launch-at-login.

## Decisions locked during brainstorming (2026-07-05)

- Native Swift/SwiftUI app, **SPM package** (not Xcode project). CLI-first: `swift build` / `swift test`.
- Bar layout: **compact triple** `✳ 42·18·9`, fixed order session · week(all) · week(sonnet). Colors: default <70%, orange ≥70%, red ≥90%; gray = stale/missing.
- **Auto-refresh expired tokens** (same OAuth flow Claude Code uses) with guardrails: only refresh already-expired tokens, single-flight per account, update-only atomic Keychain write-back preserving unknown JSON fields. Monitor never *creates* credential items.
- Notifications: **not in v1**.
- Accounts labeled by **folder suffix** (`main`, `me`, `boldoo`, `naraa`, `tergel`, `tushig`) — emails in `.claude.json` are stale copies and must not be used as identity.

## Verified facts (explored 2026-07-05)

- Config dirs: `~/.claude` + `~/.claude-{me,boldoo,naraa,tergel,tushig}` (plus `-backup`, `-backup2` which must show as "not logged in" / hideable, since they contain `.claude.json` but were never logged in).
- **No `.credentials.json` anywhere** → credentials are in the macOS **Keychain**, necessarily one entry per config dir (boldoo/naraa are provably different accounts).
- Aliases: `alias claude-me="CLAUDE_CONFIG_DIR=~/.claude-me .../bin/claude"` (`~/.zshrc:137-141`).

## Open unknowns → resolved by Task 0 spike (permission-gated, needs Mr. D)

1. Exact Keychain **service/account naming** per config dir (`security` lookups were denied to the agent by policy — the user runs one command). See `spike-results.md`.
2. Exact **usage endpoint response shape** (`GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`) — captured and sanitized into test fixtures.
3. Token refresh endpoint (`POST https://console.anthropic.com/v1/oauth/token`, client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e` — Claude Code's public OAuth client id). **Not test-refreshed during the spike** (refresh rotates tokens); live-tested on one guinea-pig account in Task 12.

Where spike results differ from the assumptions baked into code, **the only files to touch are**: `KeychainStore.candidateServices` (naming), `UsageSnapshot` key constants (response keys), `TokenRefresher` (URL/client id), and the fixtures.

## File structure

```
~/me/claude/monitor/
├── Package.swift
├── CLAUDE.md                      # project instructions; assistant name: FRIDAY
├── social.md                      # journaling per Mr. D's global CLAUDE.md
├── README.md
├── Makefile
├── .gitignore
├── docs/superpowers/
│   ├── specs/2026-07-05-claude-monitor-design.md
│   └── plans/2026-07-05-claude-monitor.md
├── scripts/
│   ├── spike.sh                   # Task 0 capture helper
│   ├── make-app.sh                # bundle .app
│   └── e2e.sh                     # end-to-end test
├── Sources/
│   ├── MonitorCore/
│   │   ├── Account.swift          # model + discovery
│   │   ├── Credentials.swift      # keychain JSON parse/expiry/write-back
│   │   ├── KeychainStore.swift    # CredentialStore protocol + real impl
│   │   ├── UsageSnapshot.swift    # usage API response model
│   │   ├── UsageClient.swift      # GET usage endpoint
│   │   ├── TokenRefresher.swift   # OAuth refresh
│   │   ├── BarFormatter.swift     # "42·18·9" segments + levels
│   │   ├── Settings.swift         # UserDefaults suite
│   │   └── Poller.swift           # engine: discover→read→refresh→fetch→publish
│   └── ClaudeMonitor/
│       ├── main.swift             # --print-once mode + app bootstrap
│       ├── StatusItemController.swift
│       └── SettingsWindow.swift
└── Tests/MonitorCoreTests/
    ├── AccountDiscoveryTests.swift
    ├── CredentialsTests.swift
    ├── UsageSnapshotTests.swift
    ├── BarFormatterTests.swift
    ├── KeychainStoreTests.swift   # integration: real keychain, test items
    ├── HTTPClientTests.swift      # UsageClient + TokenRefresher via MockURLProtocol
    ├── SettingsTests.swift
    ├── PollerTests.swift
    ├── MockURLProtocol.swift
    ├── FakeCredentialStore.swift
    └── Fixtures/
        ├── usage-full.json
        ├── usage-no-sonnet.json
        ├── credentials-valid.json
        └── credentials-expired.json
```

**Test seams (env vars, also used by spike/E2E):** `CM_CLAUDE_ROOT` (discovery root override), `CM_KEYCHAIN_SERVICE_PREFIX` (service = `<prefix><label>`), `CM_USAGE_URL`, `CM_TOKEN_URL`.

## Risks / notes

- **Unofficial API**: usage + token endpoints are what Claude Code itself uses, not public API. Lenient parsing + centralized key constants keep breakage a one-file fix.
- **Never commit `spike-raw/`** — it contains live tokens. Fixtures must be hand-sanitized.
- **Keychain naming is spike-determined** — `KeychainStore.candidateServices` has no cross-account fallback by design; wrong naming shows up as `not logged in`, never as wrong-account data.
- **Refresh rotation**: refresh tokens rotate on use. The write-back MUST persist the new refresh token; a race with a concurrently-refreshing Claude Code is possible but rare since we only refresh already-expired tokens.

See `docs/superpowers/plans/2026-07-05-claude-monitor.md` for the full task-by-task implementation plan.
