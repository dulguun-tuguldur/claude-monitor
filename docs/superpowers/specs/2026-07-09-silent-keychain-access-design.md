# Silent Keychain Access — Design Spec (2026-07-09)

**Goal:** Eliminate the macOS Keychain password prompts permanently by routing
`KeychainStore`'s secret reads and writes through `/usr/bin/security`
subprocesses instead of direct `SecItemCopyMatching`/`SecItemUpdate` calls.

**Scope:** `Sources/MonitorCore/KeychainStore.swift` (plus its tests). The
`CredentialStore` protocol, `candidateServices` naming logic, the update-only
invariant, and everything downstream are unchanged.

---

## Context (why this exists)

Even after signing the app with the stable `claude-monitor-signing` identity
(2026-07-07), Mr. D still got password prompts after every restart — including
when he hadn't "opened" the app (launch-at-login / macOS app relaunch means it
starts itself and polls immediately).

Root cause, confirmed by dumping the login-keychain ACLs (2026-07-09):
"Always Allow" records **two** layers on a keychain item, and our signing
identity only satisfies one:

1. **ACL entry** (*which app*) — our durable
   `certificate leaf = H"8759dc…"` entry works and survives rebuilds.
   Present on 5 of 6 items; the **default account's item
   (`Claude Code-credentials`) never got it** and prompts on every launch.
2. **Partition-ID list** (*which signing partition*) — for apps with a real
   Team ID this is a durable `teamid:XXXX` entry. Our self-signed cert has
   **no Team ID** (`TeamIdentifier=not set`), so securityd falls back to
   recording the per-build **cdhash**. Every release changes the cdhash →
   partition check fails → re-prompt on all six items, even though the ACL
   layer still matches.

So under direct SecItem access, prompts can never be permanently fixed without
a Team ID (paid Apple Developer identity or an unverified cert-OU trick).

**The escape hatch already present on every item:** Claude Code creates and
accesses these items via the `security` CLI, so every item's ACL trusts
`/usr/bin/security` (`identifier "com.apple.security" and anchor apple`) and
its partition list carries the permanent `apple-tool:` partition. Apple's
binary never changes identity across our rebuilds. Access through it is
silent by construction — this is exactly how Claude Code itself reads tokens
without prompting.

## Decisions locked during brainstorming (2026-07-09)

- **Approach A chosen** (security-CLI subprocess) over B (re-mint self-signed
  cert with an OU so codesign sets a TeamIdentifier — unverified whether
  securityd would then write durable `teamid:` partitions) and C (paid
  Apple Developer ID, $99/yr — guaranteed, also unlocks real Touch ID via the
  data-protection keychain, but overkill for a personal tool).
- **Touch ID is out of scope**: the prompt seen is securityd's file-based
  keychain dialog; third-party apps cannot add Touch ID to it, and Touch
  ID-gated items require data-protection-keychain entitlements (paid signing).
  With approach A there is no dialog at all, which is strictly better.
- No ACL surgery on the stale debug-build cdhash entries (harmless cruft).
- No new binary dependencies: `/usr/bin/security` ships with macOS.

## Design

### Read path (`readCredentials`)

Spawn `/usr/bin/security find-generic-password -s <service> -w`.
Trim the trailing newline and hand the bytes to `Credentials.parse`.

- `-w` prints the secret as text when printable (Claude Code stores printable
  JSON), but prints **hex** when the blob isn't valid printable text. Fallback:
  if direct parse fails and the output is pure hex, hex-decode and parse that.
- Exit code 44 (`errSecItemNotFound`) → `KeychainError.notFound`;
  any other non-zero exit → `KeychainError.osStatus(exitCode)`.

### Write path (`writeCredentials`, token rotation)

Spawn `/usr/bin/security -i` (interactive mode) and write
`add-generic-password -U -s <service> -a <account> -w <secret>` to **stdin** —
the token must never appear in argv (visible in `ps`).

- `-U` updates the existing item in place, preserving its ACL.
- **Update-only invariant preserved:** `-U` would happily *create* a missing
  item, so `writeCredentials` first resolves existence and throws `.notFound`
  instead of letting `-U` create. The existing `resolveService`
  attributes-only `SecItemCopyMatching` query stays as-is — attribute reads
  don't touch the secret, so they never prompt.
- The `-a` account attribute is read from the resolved item's attributes
  (the existing resolve query already returns them), not hardcoded.

### Subprocess seam (testability)

Subprocess invocation goes behind a small injectable runner
(e.g. `(arguments, stdin) -> (stdout, exitCode)`) defaulting to a real
`Process` implementation. Unit tests fake the runner to cover: happy-path
JSON, hex output, exit 44 → `.notFound`, other exits → `.osStatus`, write
refuses to create, secret passed via stdin not argv.

### E2E / existing tests

The `CM_KEYCHAIN_SERVICE_PREFIX` seam is untouched. E2E fixtures are created
with the `security` CLI already, so they carry the `apple-tool:` partition and
stay silent under the new path.

## One-time user action

Item `Claude Code-credentials-ce2d9f0a` is missing `apple-tool:` from its
partition list, so the **first** CLI read of that account will prompt once;
"Always Allow" there binds to Apple's `/usr/bin/security` and is permanent.
All other items are already silent on this path. Afterwards: zero dialogs,
across restarts and future releases.

## Security posture (honest tradeoff)

Reading via `/usr/bin/security` works because that binary is broadly trusted
by these items. This is **not a regression**: Claude Code itself established
this trust when it created the items, and any local process could already read
them the same way. The monitor simply joins the trust model that already
exists instead of fighting the per-build partition check.

## Error handling

Unchanged at the API surface: `KeychainError.notFound` / `.osStatus` flow to
the same callers. A missing or non-executable `/usr/bin/security` (effectively
impossible on macOS) surfaces as `.osStatus`.

## Out of scope

- Certificate changes, Touch ID plumbing, notarization/paid signing.
- Cleaning stale ACL/partition entries on the items.
- Any change to polling, refresh, or UI code.
