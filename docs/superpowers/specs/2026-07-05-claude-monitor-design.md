# Claude Monitor — Design Spec — PLACEHOLDER (NEEDS_CONTEXT)

This design spec is meant to be reshaped from the implementation plan's
*Context (why this exists)*, *Decisions locked during brainstorming*,
*Verified facts*, *Open unknowns*, and *File structure* sections. Those
sections were not available verbatim to the agent performing the Task 0
bootstrap, so this document is a stub rather than a fabricated spec.

**Action needed:** once `docs/superpowers/plans/2026-07-05-claude-monitor.md`
is filled in with the real plan text, re-derive this design spec from its
named sections.

## Context (why this exists) — partial, from the Task 0 brief only

Claude Monitor is a native macOS menu bar app that shows Claude Code account
usage percentages. There are six Claude Code accounts (managed via
`CLAUDE_CONFIG_DIR` aliases), each with its own usage quotas; the app
displays all their usage percentages in the menu bar so the user doesn't
have to check each account manually.

## Decisions locked during brainstorming

Not available — pending the full plan text.

## Verified facts

The following were inferable from the Task 0 fixture requirements and are
believed accurate, pending confirmation against the full plan:

- The Claude usage API returns a JSON object keyed by window name
  (`five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`), each
  value containing `utilization` (percentage, Double) and `resets_at`
  (ISO 8601 timestamp string).
- `seven_day_sonnet` and `seven_day_opus` are not guaranteed to be present
  in every response (parsing must tolerate their absence).
- Unrecognized top-level fields in the usage response must be ignored
  without error (forward compatibility).
- OAuth credentials are stored under a `claudeAiOauth` object with
  `accessToken`, `refreshToken`, `expiresAt` (epoch milliseconds), `scopes`,
  and `subscriptionType`; unknown fields on this object must survive a
  read-modify-write round trip (e.g. during token refresh).

## Open unknowns

- Exact Keychain service name(s) used per `CLAUDE_CONFIG_DIR` alias account
  (see `docs/superpowers/specs/spike-results.md` — pending human spike via
  `scripts/spike.sh`).
- Real shape of a live `/usage` API response beyond the assumed fixture
  shape (also pending the human-run spike).
- All other open unknowns recorded in the original plan — not reproduced
  here since the plan text itself is still pending.

## File structure

```
claude-monitor/
  Package.swift
  Sources/
    MonitorCore/       # UI-free business logic library (usage parsing,
                        # credential handling, refresh logic, etc.)
    ClaudeMonitor/      # Thin AppKit/SwiftUI menu bar executable
  Tests/
    MonitorCoreTests/
      Fixtures/         # JSON fixtures for usage responses and credentials
  scripts/
    spike.sh            # Human-run helper to capture a live /usage response
  docs/
    superpowers/
      plans/            # Implementation plans
      specs/            # Design specs and spike results
```

This mirrors the skeleton created in Task 0 step 0.1. The full plan's file
structure section (if it names additional files, e.g. specific source files
within `MonitorCore`/`ClaudeMonitor` for later tasks) is not reproduced here
pending the verbatim plan text.
