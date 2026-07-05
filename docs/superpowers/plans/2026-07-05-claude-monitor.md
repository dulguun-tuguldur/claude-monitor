# Claude Monitor Implementation Plan — PLACEHOLDER (NEEDS_CONTEXT)

This file is a placeholder. The full implementation plan (Task 0 through
Task 12) was referenced verbatim during Task 0 bootstrap but the complete
source text was not available to the agent performing the bootstrap — only
the Task 0 description (steps 0.1-0.9) and a partial "Context" excerpt were
provided.

Per project policy (never fabricate content that later tasks will rely on
for accuracy), this file was left as a stub rather than reconstructed from
memory or guesswork.

**Action needed:** Mr. D (or whoever holds the original plan) should paste
the full verbatim plan text here, replacing this placeholder, before Task 1
begins — later tasks are expected to read this file for their own step
descriptions.

## What is known (from the Task 0 brief, safe to treat as accurate)

- Project: Claude Monitor — a native macOS menu bar app showing Claude Code
  account usage percentages.
- Six Claude Code accounts (via `CLAUDE_CONFIG_DIR` aliases) each have their
  own usage quotas; the app will show all their usage percentages in the
  menu bar.
- Architecture: Swift Package Manager package split into a UI-free
  `MonitorCore` library (business logic, testable) and a thin
  `ClaudeMonitor` AppKit/SwiftUI executable target.
- Task 0 (this bootstrap) covers scaffolding, docs, and test fixtures only —
  no application logic.
- Fixture shapes already established by Task 0 (see
  `Tests/MonitorCoreTests/Fixtures/`):
  - Usage API response has `five_hour`, `seven_day`, `seven_day_sonnet`,
    `seven_day_opus` keys, each an object with `utilization` (Double,
    percentage) and `resets_at` (ISO 8601 string). Unknown/future top-level
    keys must be tolerated (see `some_future_field` in the fixture).
    `seven_day_sonnet` / `seven_day_opus` may be absent entirely.
  - Credentials file (`~/.claude/.credentials.json`-shaped) has a
    `claudeAiOauth` object with `accessToken`, `refreshToken`, `expiresAt`
    (epoch millis), `scopes` (array), `subscriptionType`, and must tolerate
    unknown fields surviving a read-modify-write round trip.

Everything else (the remaining Task 0 sub-steps not covered above, and all
of Task 1 through Task 12) is NOT reconstructed here and must come from the
original plan document.
