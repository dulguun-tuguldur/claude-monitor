# Getting Started with Claude Monitor

Claude Monitor is a macOS menu bar app that shows Claude Code usage —
session, week, and week-Sonnet percentages — for every account you run via
`CLAUDE_CONFIG_DIR`, all in one glance.

Getting set up is three steps: **install the app**, **let it read your
Keychain once**, and **enroll your accounts**. Pick the install path that
fits you — a pre-built release (fastest) or a build from source (for
contributors, or if there's no release for you).

## Prerequisites

- macOS 13 (Ventura) or newer.
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed, with
  at least one logged-in account.
- Source build only: a Swift toolchain (Xcode or the Command Line Tools).

---

## 1. Install the app

Choose **one** of the two paths below.

### Option A — Pre-built release (fastest)

The published build is already signed with a stable identity, so a single
"Always Allow" (step 2) sticks forever — **no certificate setup needed**. It's
signed with a self-signed cert and is **not notarized**, so Gatekeeper needs a
one-time nudge on first launch.

**A1 · Homebrew** *(once a tap is published)*

```sh
brew install --cask dulguun-tuguldur/tap/claude-monitor
```

Homebrew drops it in `/Applications` and clears the quarantine flag for you —
skip straight to [§2](#2-first-launch--keychain-access).

**A2 · Download the release zip**

1. Download the latest `ClaudeMonitor-<version>.zip` from the
   [Releases page](https://github.com/dulguun-tuguldur/claude-monitor/releases).
2. Double-click to unzip (or `unzip` it), then move it into place:

   ```sh
   mv ~/Downloads/"Claude Monitor.app" /Applications/
   ```

3. Clear the quarantine flag — otherwise macOS says the app "can't be opened":

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Claude Monitor.app"
   ```

   (Or, first launch only: right-click the app → **Open** → **Open**.)

That's the install — go to [§2](#2-first-launch--keychain-access).

### Option B — Build from source

For contributors, or when no release is available. **You must create a
code-signing identity first.** Skip it and the build is *ad-hoc* signed — whose
signature changes on every rebuild, so macOS re-prompts for Keychain access on
every launch. A stable identity is what lets a single "Always Allow" persist.

**B1 · Clone**

```sh
git clone https://github.com/dulguun-tuguldur/claude-monitor.git
cd claude-monitor
```

**B2 · Create the `claude-monitor-signing` identity** *(one time)*

*GUI — the documented path (see also [`docs/signing.md`](signing.md)):*

1. Open **Keychain Access** → menu **Certificate Assistant → Create a
   Certificate…**
2. **Name:** `claude-monitor-signing` (exactly — the build scripts grep for
   it). **Identity Type:** Self-Signed Root. **Certificate Type:** Code
   Signing. Tick **"Let me override defaults."**
3. Continue → **Validity Period: 3650** days → accept the remaining defaults →
   final page keychain = **login** → Create → Done.
4. Under **My Certificates**, double-click `claude-monitor-signing` → expand
   **Trust** → set **Code Signing: Always Trust** (admin password confirms).
5. Confirm it took:

   ```sh
   security find-identity -v -p codesigning   # must list claude-monitor-signing
   ```

*CLI fallback — use this if Certificate Assistant fails with "The specified
item could not be found in the keychain" (a known macOS bug):*

```sh
# 1) code-signing cert config (works with macOS's LibreSSL)
cat > /tmp/cms.cnf <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = claude-monitor-signing
[v3]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CNF

# 2) key + self-signed code-signing cert, valid 10 years
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/cms-key.pem \
  -out /tmp/cms-cert.pem -days 3650 -config /tmp/cms.cnf -extensions v3

# 3) bundle to .p12 — a NON-empty passphrase + legacy PBE/MAC are required,
#    or `security import` fails with "MAC verification failed"
openssl pkcs12 -export -inkey /tmp/cms-key.pem -in /tmp/cms-cert.pem \
  -name claude-monitor-signing -out /tmp/cms.p12 -passout pass:tmpimport \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

# 4) import into the login keychain and trust it for code signing
security import /tmp/cms.p12 -k ~/Library/Keychains/login.keychain-db \
  -P tmpimport -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db /tmp/cms-cert.pem

# 5) confirm, then delete the temp key material (it now lives in the keychain)
security find-identity -v -p codesigning   # must list claude-monitor-signing
rm -f /tmp/cms-key.pem /tmp/cms.p12 /tmp/cms-cert.pem /tmp/cms.cnf
```

> **Back up the identity.** The private key lives only in your login keychain.
> If you wipe or reinstall macOS, re-import the same `.p12` to keep the
> *identical* certificate — that keeps every "Always Allow" grant valid.

**B3 · Build, verify, install**

```sh
make app          # release build, signed with claude-monitor-signing
make verify-app   # gate: fails if the bundle is ad-hoc or the identity pin is wrong
cp -R "Claude Monitor.app" /Applications/
```

The first time `codesign` uses the key, macOS pops one "codesign wants to sign
using key…" prompt — click **Always Allow** so future rebuilds are silent.

---

## 2. First launch & Keychain access

1. Launch **Claude Monitor** from `/Applications` (Spotlight works too). It runs
   as a menu bar item with **no Dock icon** — look for `✳ <numbers>` near the
   top-right of your screen.
2. The first time it reads each account's stored credentials, macOS asks
   whether "Claude Monitor" may use that item. Click **Always Allow**. This
   happens **once per account** — with a signed build (Option A, or Option B
   with the identity) the grant persists across relaunches and upgrades.
3. Optional: open **Settings** from the menu bar item → enable **Launch at
   Login** so it starts on boot. This is silent because the app is signed.

---

## 3. Enroll your accounts

Claude Monitor watches your home folder for Claude Code config dirs: `~/.claude`
(shown as **main**) and any `~/.claude-<name>` (shown as **<name>**). Each must
contain a `.claude.json`. Your everyday account is discovered automatically.

To add another account:

1. **Scaffold a fresh config dir.** From a source checkout, `make new-account`
   clones settings, skills, hooks, plugins, and MCP config from a base account
   — but deliberately **not** logins or session history, so the new account
   starts clean:

   ```sh
   make new-account NAME=work                      # base = ~/.claude
   make new-account NAME=work FROM=~/.claude-me     # clone a different base
   ```

   (Installed from a release without the repo? Just create `~/.claude-work`
   yourself — the `make` target is only a convenience.)

2. **Add the printed alias** to your `~/.zshrc`:

   ```sh
   alias claude-work="CLAUDE_CONFIG_DIR=$HOME/.claude-work claude"
   ```

3. **Log in with that account's own credentials** — start it once, then
   `/login`:

   ```sh
   claude-work        # then, inside the session: /login
   ```

The account shows as `not logged in` until you do, then Claude Monitor picks up
its usage on the next poll — no restart needed.

---

## 4. Reading the display

Each account's bar is three numbers, `session · week · week-Sonnet`:

| Segment | Meaning |
| --- | --- |
| **session** | 5-hour rolling window usage % |
| **week** | 7-day window usage % (all models) |
| **week-Sonnet** | 7-day Sonnet window usage % |

`–` means that window doesn't apply to the account. Numbers turn **amber at
≥70%** and **red at ≥90%**.

Status words in the dropdown:

| Status | Meaning / fix |
| --- | --- |
| *numbers* | Logged in, reading fine. |
| `not logged in` | No credentials yet — run the account's alias once and `/login`. |
| `re-login needed` | Refresh token was rejected — run `/login` in that account's session. |
| `stale` | The last poll failed; showing the previous good value. |
| `pending` | First poll still in flight. |

---

## 5. Troubleshooting

- **Prompts for the Keychain on every launch.** You're running an **ad-hoc**
  build — `make run`, `swift run`, or `.build/debug/ClaudeMonitor`. Verify with
  `codesign -dvv "/Applications/Claude Monitor.app"`; if you see
  `flags=0x2(adhoc)`, install a release (Option A) or rebuild with the identity
  (Option B). Day-to-day, always launch the `/Applications` app, never the
  debug binary.
- **"Claude Monitor can't be opened" / "is damaged."** Gatekeeper on the
  un-notarized download. Run
  `xattr -dr com.apple.quarantine "/Applications/Claude Monitor.app"`, or
  right-click → **Open**.
- **An account says `not logged in` but you did log in.** Make sure the dir is
  named `.claude` or `.claude-<name>` directly under your home folder and
  contains a `.claude.json`.
- **Prompts returned after an OS reinstall or keychain reset.** The signing
  identity lived in your login keychain and is gone — recreate it (Option B2)
  or re-import your saved `.p12`.

---

## Uninstall

Quit from the menu bar item first, then:

```sh
rm -rf "/Applications/Claude Monitor.app"
```

To also remove the signing identity you created: Keychain Access → **login** →
**My Certificates** → delete `claude-monitor-signing`.
