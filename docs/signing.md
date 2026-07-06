# Code signing

## Why this exists

Claude Monitor reads OAuth credential Keychain items *owned by Claude Code*.
macOS gates that behind a per-item ACL grant ("Always Allow"), and the grant is
keyed to the requesting app's **designated requirement** — a stable statement
of code identity derived from the signing certificate and bundle identifier.

An ad-hoc signature (`codesign --sign -`) has no designated requirement, so
"Always Allow" has nothing durable to bind to: every launch (and every rebuild)
re-prompts for every account. Signing with a real certificate — even a free
self-signed one — gives the app a stable identity, so each account prompts
**once, ever**.

The same identity is what release builds ship with (see `scripts/make-app.sh`
and `scripts/release.sh`).

## One-time setup: create the signing certificate

This is GUI-only by necessity: on macOS 15+, scripted trust changes
(`security add-trusted-cert -d`) are blocked without MDM. Takes ~2 minutes.

1. Open **Keychain Access** (in /System/Library/CoreServices/Applications, or
   via Spotlight).
2. Menu bar → **Keychain Access → Certificate Assistant → Create a
   Certificate…**
3. Fill in:
   - **Name:** `claude-monitor-signing` (exactly — the build scripts look this
     name up)
   - **Identity Type:** Self-Signed Root
   - **Certificate Type:** Code Signing
   - Check **"Let me override defaults"**
4. Click Continue. On the validity page, set **Validity Period: 3650 days**
   (the 365-day default means re-signing and re-granting every year). Keep
   clicking Continue, accepting the other defaults; ensure the final page's
   keychain is **login**. Create, then Done.
5. In Keychain Access under **My Certificates**, double-click
   `claude-monitor-signing` → expand **Trust** → set **Code Signing: Always
   Trust**. Close the window (admin password prompt confirms it).
6. Verify from a terminal:

   ```sh
   security find-identity -v -p codesigning
   ```

   The list must include `claude-monitor-signing`.

The first time `codesign` uses the key you'll get one "codesign wants to sign
using key…" prompt — click **Always Allow**.

## Spike results: does "Always Allow" persist?

Two layers gate silent Keychain access: the item ACL (keyed to the designated
requirement — stable with this cert) and the partition list, whose behavior
for no-team-ID identities across rebuilds is undocumented. Verified live on
this machine (macOS 26 / Darwin 25.3.0):

- **Relaunch after Always Allow ×6:** _(pending)_
- **Rebuild + re-sign + reinstall, same cert:** _(pending)_
- **One-day soak (Claude Code refreshing tokens normally):** _(pending)_

## Known limits

- `make run` / `swift run` debug binaries are unsigned — they will still
  prompt. Day-to-day, use the installed signed app.
- If Claude Code itself ever delete-recreates a credential item (rather than
  updating in place), the grant on that item is wiped and macOS prompts once
  more for that account. Nothing on our side can prevent that; our own token
  write-back uses `SecItemUpdate` precisely to avoid causing it.
- Other machines don't trust this certificate — that's fine for Keychain
  grants (ACL matching checks code identity, not certificate trust), but it
  means Gatekeeper friction for downloaded copies; see the README's install
  section.
