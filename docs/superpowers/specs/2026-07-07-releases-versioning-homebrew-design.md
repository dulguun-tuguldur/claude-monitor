# Releases, Versioning & Homebrew Distribution — Design

Date: 2026-07-07
Status: Approved (design), pending implementation plan

## Problem

Claude Monitor has a working local release pipeline (`scripts/release.sh`:
build → `verify-app` gate → zip → `gh release create` → optional cask sync)
but nobody can actually install it via Homebrew, versions are bumped by
hand-editing `VERSION`, and no changelog exists. We want:

1. Automated version management (derive the next version + changelog from
   commits).
2. A working Homebrew install path.
3. To cut real releases against both.

## Locked decisions

These were settled during brainstorming and are not open for
re-litigation in the plan:

- **Signing posture: self-signed, small circle.** No Apple Developer
  account, no notarization, no CI signing secrets. Consequence: the release
  build stays **local** (the signing cert lives in the login keychain;
  exporting it to CI is a worse security story than the problem it solves).
- **Version management: conventional commits + `git-cliff`.** Local bump,
  not CI-driven (release-please/semantic-release fight the self-signed-local
  model).
- **Tap shape: one generic tap.** New public repo
  `dulguun-tuguldur/homebrew-tap`, reusable for future tools. Install is
  `brew tap dulguun-tuguldur/tap && brew install --cask claude-monitor`.

## The flow

Two commands, split on purpose:

```
make bump      →  git-cliff derives next version from commits since the last
                  tag, rewrites CHANGELOG.md + VERSION, commits
                  "chore(release): vX.Y.Z". Local, reversible, no build/push.

make release   →  clean-tree + signing-identity gates → tag vX.Y.Z → build →
                  verify-app → zip + sha256 → gh release create (notes from
                  changelog) → sync version+sha256 into the tap cask →
                  human reviews & pushes the tap.
```

`bump` is the safe, local, undoable step. `release` is the single
outward-facing irreversible step and stays behind the existing clean-tree
and pinned-identity gates. Tap push stays **manual** — same reasoning as
today.

## Components

### 1. Version management (git-cliff)

- **`cliff.toml`** (repo root): conventional-commit parsing, grouped
  sections (Features / Bug Fixes / Docs / etc.), tag pattern `v[0-9]*`,
  a leading uncategorized/"Other" bucket so the ~10% of non-conventional
  historical commits still render.
- **`CHANGELOG.md`** (repo root, generated, committed).
- **`make bump`** → new script (`scripts/bump.sh`):
  - Computes the next semver via `git cliff --bumped-version` (strips the
    leading `v`).
  - Writes `VERSION`, regenerates `CHANGELOG.md` (`git cliff --bump`).
  - Commits `chore(release): vX.Y.Z` (VERSION + CHANGELOG.md only).
  - **Refuses if no prior tag exists** — that is the first-release case
    (see "First release" below); the script prints guidance and exits
    non-zero rather than guessing.
- **Prerequisite:** `brew install git-cliff` (not currently installed).
  Documented in README + `docs/releasing.md`.

### 2. Homebrew tap + cask

- New public repo `dulguun-tuguldur/homebrew-tap`, cloned locally at
  `~/me/claude/homebrew-tap` (sibling of this repo). `CM_TAP_DIR` points
  there — already the contract `release.sh` expects.
- **`Casks/claude-monitor.rb`** (initial, hand-authored; `release.sh` keeps
  `version`/`sha256` current thereafter):

  ```ruby
  cask "claude-monitor" do
    version "1.0.0"
    sha256 "<filled at first release>"

    url "https://github.com/dulguun-tuguldur/claude-monitor/releases/download/v#{version}/ClaudeMonitor-#{version}.zip"
    name "Claude Monitor"
    desc "Menu bar app showing Claude Code account usage at a glance"
    homepage "https://github.com/dulguun-tuguldur/claude-monitor"

    depends_on macos: ">= :ventura" # matches LSMinimumSystemVersion 13.0

    app "Claude Monitor.app"

    caveats <<~EOS
      Claude Monitor is self-signed and not notarized, so on first launch
      macOS Gatekeeper will refuse to open it. To open it the first time:
        - Right-click "Claude Monitor" in /Applications, choose Open, then
          Open again in the dialog; or
        - System Settings > Privacy & Security > "Open Anyway".
      This is a one-time step per installed version.
    EOS

    zap trash: [
      "~/Library/Preferences/mn.tanasoft.claude-monitor.settings.plist",
    ]
  end
  ```

  - `zap` targets `mn.tanasoft.claude-monitor.settings.plist` — the app's
    real UserDefaults suite (deliberately *not* the bundle id; see commit
    `17eec9d`).
  - Caveat recommends right-click→Open over `xattr -dr com.apple.quarantine`
    — Apple-sanctioned and doesn't train a risky habit.
  - The cask filename matches `release.sh`'s existing
    `$CM_TAP_DIR/Casks/claude-monitor.rb` path exactly.

### 3. `release.sh` change (minimal)

Only substantive change: replace the static `--notes "..."` string with the
generated changelog section for this version (`git cliff --latest`), falling
back to the current static string if git-cliff is absent. Everything else —
gates, build, verify, zip, sha256, cask sync, manual push — stays as is.

### 4. Docs

- **README:** add Homebrew as the primary install path; keep `make app` as
  build-from-source; fix the stale "ad-hoc signed" wording (bundles are
  pinned-identity signed now); surface the Gatekeeper first-launch note.
- **`docs/releasing.md`** (new): full flow, prerequisites (`git-cliff`,
  `gh`, signing identity), tap creation/clone, first-release procedure,
  and the manual tap-push step.
- **CLAUDE.md:** note conventional commits are the project norm and point at
  `docs/releasing.md`.

## First release (v1.0.0) — special case

git-cliff derives versions from tags, and there are none yet. So the first
release skips `make bump`: `VERSION` is already `1.0.0`, so we go straight to
`make release` to cut `v1.0.0`. Every subsequent release starts with
`make bump`. `bump.sh` enforces this by refusing to run without a prior tag.

Because `make bump` is skipped, the initial `CHANGELOG.md` is generated and
committed once during setup — `git cliff --tag v1.0.0 -o CHANGELOG.md`
treats the current history as the v1.0.0 release — so `release.sh`'s
`git cliff --latest` note extraction has a section to read on the first run.

## Testing (unit + integration + e2e)

Per the project's no-exceptions testing policy, release tooling gets its own
coverage (there is none today):

- **`bump.sh` (integration):** run against a throwaway temp git repo seeded
  with synthetic conventional commits; assert the computed version and the
  resulting `VERSION` + `CHANGELOG.md` contents. No prior-tag case asserts a
  non-zero exit with guidance.
- **`release.sh --dry-run` (e2e):** new `scripts/release-e2e.sh` — dry-run
  release into a temp `CM_TAP_DIR`; assert the zip artifact exists, sha256 is
  computed, the temp cask's `version`/`sha256` were rewritten to match, and
  the notes came from the changelog. Must not touch the real tap or create a
  tag/release.
- **Cask validity:** `brew audit --cask` / `brew style` on
  `claude-monitor.rb` (brew is available locally).
- **Wiring:** new `make` targets (e.g. `test-release`), and the cask audit
  runs where the tap lives.

## Out of scope

- Notarization / Apple Developer ID (explicitly deferred; documented upgrade
  path only).
- CI-driven releases (fights the self-signed-local model).
- Auto-pushing the Homebrew tap (stays a manual review-and-push step).

## Affected / new files

New:
- `cliff.toml`
- `CHANGELOG.md`
- `scripts/bump.sh`
- `scripts/release-e2e.sh`
- `docs/releasing.md`
- `dulguun-tuguldur/homebrew-tap` repo → `Casks/claude-monitor.rb` (external)

Modified:
- `scripts/release.sh` (changelog-sourced release notes)
- `Makefile` (`bump`, `test-release` targets)
- `README.md` (Homebrew install, Gatekeeper note, signing wording)
- `CLAUDE.md` (conventional-commits note, releasing doc pointer)
