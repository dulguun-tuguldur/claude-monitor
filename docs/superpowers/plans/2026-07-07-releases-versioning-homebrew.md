# Releases, Versioning & Homebrew Distribution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Claude Monitor automated conventional-commit version management (`make bump`), a working Homebrew install path (a public `dulguun-tuguldur/homebrew-tap` cask), and release tooling that sources GitHub release notes from the generated changelog — then cut the first real release against it.

**Architecture:** Two commands split on purpose. `make bump` is the safe, local, reversible step: git-cliff derives the next semver from commits since the last tag, rewrites `CHANGELOG.md` + `VERSION`, and commits `chore(release): vX.Y.Z`. `make release` is the single outward-facing irreversible step: clean-tree + pinned-identity gates → build → verify → zip + sha256 → `gh release create` (notes from the changelog) → sync version+sha256 into the tap cask → human reviews & pushes the tap. Release stays local (the signing cert lives in the login keychain, never in CI) and the tap push stays manual.

**Tech Stack:** Bash scripts, `git-cliff` 2.13.1 (conventional-commit changelog), `gh` CLI, Homebrew cask, Swift Package Manager (existing build).

---

## Deviations from the design spec (`docs/superpowers/specs/2026-07-07-releases-versioning-homebrew-design.md`)

These were found and validated during planning. Each is a correctness or tooling fix, not a scope change:

1. **Release-note extraction uses `git cliff --unreleased --tag "$TAG"`, not `git cliff --latest`.** Verified in a throwaway repo: at `release.sh` time the new tag does not exist yet (today `gh release create` creates it), so `--latest` returns the *previous* release's notes, and on the first release it returns an `[unreleased]` heading. `--unreleased --tag "$TAG"` produces the correct current-version section in both the first-release (no tags) and subsequent-release (tag not yet created) cases. This keeps the change minimal — no new tagging step, no dangling-tag cleanup.
2. **The cask uses `depends_on macos: :ventura` and a bare-string `zap trash:`**, in the canonical stanza order, because `brew style --fix` rewrites the spec's `">= :ventura"` and single-element array to that form. The corrected cask passes `brew style` with zero offenses.
3. **A bump integration test lives at `scripts/bump-e2e.sh`.** The spec's testing section required a bump integration test but did not enumerate the filename; this follows the existing `scripts/new-account-e2e.sh` convention.
4. **`git-cliff` is already installed** (2.13.1) — the spec predicted it was not. The prerequisite is still documented in the README and `docs/releasing.md` for other machines.

## File Structure

Monitor repo (`~/me/claude/monitor`):
- `cliff.toml` (new) — git-cliff config: conventional-commit parsing, grouped sections, `v[0-9]*` tag pattern, leading "Other" bucket for non-conventional commits.
- `CHANGELOG.md` (new, generated, committed) — the keep-a-changelog output.
- `scripts/bump.sh` (new) — derive next version, rewrite VERSION + CHANGELOG.md, commit.
- `scripts/bump-e2e.sh` (new) — integration test for `bump.sh` in a throwaway repo.
- `scripts/release-e2e.sh` (new) — e2e test for `release.sh --dry-run` in a throwaway clone.
- `scripts/release.sh` (modify) — changelog-sourced release notes, notes echoed on dry-run.
- `Makefile` (modify) — `bump`, `test-bump`, `test-release`, `test-cask` targets + `CM_TAP_DIR` default.
- `docs/releasing.md` (new) — full release flow, prerequisites, first-release procedure.
- `README.md` (modify) — Homebrew as primary install, Gatekeeper note, corrected signing wording.
- `CLAUDE.md` (modify) — conventional-commits norm, releasing-doc pointer, new make targets.

Tap repo (`~/me/claude/homebrew-tap`, already `git init`ed, no commits, no remote):
- `Casks/claude-monitor.rb` (new) — the cask.
- `README.md` (new) — tap usage.

---

## Task 1: git-cliff config + initial changelog

**Files:**
- Create: `cliff.toml`
- Create: `CHANGELOG.md` (generated)

- [ ] **Step 1: Write `cliff.toml`**

Exact content (validated: renders a clean, grouped v1.0.0 changelog from the real history, no `<!-- -->` leakage, "Other" bucket sorts first when present):

```toml
# ABOUTME: git-cliff config — parses conventional commits into a grouped,
# ABOUTME: keep-a-changelog-style CHANGELOG.md; release tags match v[0-9]*.

[changelog]
header = """
# Changelog

All notable changes to Claude Monitor are documented in this file.
It is generated from conventional commit messages by git-cliff.
"""
body = """
{% if version -%}
## [{{ version | trim_start_matches(pat="v") }}] - {{ timestamp | date(format="%Y-%m-%d") }}
{% else -%}
## [unreleased]
{% endif -%}
{% for group, commits in commits | group_by(attribute="group") %}
### {{ group | striptags | trim | upper_first }}
{% for commit in commits %}
- {{ commit.message | split(pat="\n") | first | upper_first | trim }}
{%- endfor %}
{% endfor %}
"""
trim = true
footer = ""

[git]
conventional_commits = true
filter_unconventional = false
split_commits = false
filter_commits = false
tag_pattern = "v[0-9]*"
topo_order = false
sort_commits = "oldest"
commit_parsers = [
  { message = "^feat", group = "<!-- 1 -->Features" },
  { message = "^fix", group = "<!-- 2 -->Bug Fixes" },
  { message = "^doc", group = "<!-- 3 -->Documentation" },
  { message = "^perf", group = "<!-- 4 -->Performance" },
  { message = "^refactor", group = "<!-- 5 -->Refactoring" },
  { message = "^test", group = "<!-- 6 -->Testing" },
  { message = "^chore\\(release\\):", skip = true },
  { message = "^chore", group = "<!-- 7 -->Miscellaneous" },
  { message = "^ci", group = "<!-- 7 -->Miscellaneous" },
  { message = ".*", group = "<!-- 0 -->Other" },
]
```

- [ ] **Step 2: Verify the config renders the v1.0.0 changelog**

Run: `git cliff --tag v1.0.0 | grep -E '^## \[1\.0\.0\]|^### Features|^### Bug Fixes'`
Expected: three matching lines (the version header, `### Features`, `### Bug Fixes`). No error, no `<!--` in output.

- [ ] **Step 3: Generate `CHANGELOG.md`**

This treats the current history as the v1.0.0 release, so `release.sh` has a section to read on the first run:

Run: `git cliff --tag v1.0.0 -o CHANGELOG.md`
Expected: `CHANGELOG.md` created, top line `# Changelog`, contains `## [1.0.0] - <today>`.

- [ ] **Step 4: Commit**

```bash
git add cliff.toml CHANGELOG.md
git commit -m "feat: git-cliff changelog config and initial CHANGELOG"
```

---

## Task 2: `bump.sh` + integration test

**Files:**
- Create: `scripts/bump-e2e.sh`
- Create: `scripts/bump.sh`
- Modify: `Makefile`

- [ ] **Step 1: Write the failing integration test `scripts/bump-e2e.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: Integration test for bump.sh: in a throwaway repo, asserts the
# ABOUTME: derived version, VERSION/CHANGELOG rewrite, and no-prior-tag refusal.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "bump-e2e: FAIL: $*" >&2; exit 1; }

# Seed a throwaway repo carrying a copy of the real bump.sh + cliff.toml so
# bump.sh's `cd "$(dirname "$0")/.."` lands inside the throwaway repo.
seed_repo() {
    local dir="$1"
    mkdir -p "$dir/scripts"
    cp "$REPO/scripts/bump.sh" "$dir/scripts/bump.sh"
    cp "$REPO/cliff.toml" "$dir/cliff.toml"
    cd "$dir"
    git init -q
    git config user.email t@e2e
    git config user.name t
    export GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00"
    echo "1.0.0" > VERSION
    git add -A
    git commit -q -m "feat: initial feature"
}

### Case 1: no prior tag → refuse with guidance ###
seed_repo "$WORK/r1"
if bash scripts/bump.sh >/dev/null 2>"$WORK/err1"; then
    fail "bump should refuse without a prior tag"
fi
grep -qi "first release" "$WORK/err1" || fail "refusal should mention the first release"

### Case 2: feat since last tag → minor bump ###
seed_repo "$WORK/r2"
git cliff --config cliff.toml --tag v1.0.0 -o CHANGELOG.md
git add -A
git commit -q -m "chore: add changelog"
git tag v1.0.0
git commit -q --allow-empty -m "feat: shiny new thing"

bash scripts/bump.sh

[ "$(cat VERSION)" = "1.1.0" ] || fail "expected VERSION 1.1.0, got $(cat VERSION)"
grep -q "## \[1.1.0\]" CHANGELOG.md || fail "CHANGELOG.md missing the 1.1.0 section"
grep -q "Shiny new thing" CHANGELOG.md || fail "CHANGELOG.md missing the feat entry"
git log -1 --pretty=%s | grep -q "^chore(release): v1.1.0$" || fail "release commit subject wrong"
changed=$(git show --name-only --pretty=format: HEAD | grep -v '^$' | sort | tr '\n' ' ')
[ "$changed" = "CHANGELOG.md VERSION " ] || fail "release commit touched unexpected files: $changed"

echo "BUMP E2E PASS"
```

Then: `chmod +x scripts/bump-e2e.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/bump-e2e.sh`
Expected: FAIL — `cp "$REPO/scripts/bump.sh"` errors because `scripts/bump.sh` does not exist yet.

- [ ] **Step 3: Write `scripts/bump.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: Derives the next semver from conventional commits via git-cliff,
# ABOUTME: rewrites VERSION + CHANGELOG.md, and commits chore(release): vX.Y.Z.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "bump: FAIL: $*" >&2; exit 1; }

command -v git-cliff >/dev/null 2>&1 || fail "git-cliff not installed (brew install git-cliff)"
if [ -n "$(git status --porcelain)" ]; then fail "working tree not clean"; fi

# git-cliff derives the next version from tags; the first release has none and
# is cut directly with 'make release' (see docs/releasing.md). Refuse rather
# than guess a version.
if ! git tag --list 'v[0-9]*' | grep -q .; then
    fail "no prior release tag — this is the first release; skip bump and run 'make release' (see docs/releasing.md)"
fi

NEXT=$(git cliff --bumped-version 2>/dev/null | sed 's/^v//')
[ -n "$NEXT" ] || fail "could not compute next version"

echo "$NEXT" > VERSION
git cliff --bump -o CHANGELOG.md

git add VERSION CHANGELOG.md
git commit -m "chore(release): v$NEXT"
echo "bump: VERSION=$NEXT, CHANGELOG.md regenerated, committed chore(release): v$NEXT"
```

Then: `chmod +x scripts/bump.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/bump-e2e.sh`
Expected: `BUMP E2E PASS`

- [ ] **Step 5: Add `bump` and `test-bump` make targets**

In `Makefile`, add `bump test-bump` to the `.PHONY` line, and add these targets after the `release:` target:

```makefile
bump:
	bash scripts/bump.sh

test-bump:
	bash scripts/bump-e2e.sh
```

Verify: `make test-bump` prints `BUMP E2E PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/bump.sh scripts/bump-e2e.sh Makefile
git commit -m "feat: make bump — git-cliff version + changelog bump, with integration test"
```

---

## Task 3: `release.sh` changelog-sourced notes + e2e test

**Files:**
- Create: `scripts/release-e2e.sh`
- Modify: `scripts/release.sh:34-39`
- Modify: `Makefile`

- [ ] **Step 1: Write the failing e2e test `scripts/release-e2e.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: E2E for release.sh --dry-run in a throwaway clone: asserts the zip,
# ABOUTME: sha256, temp-cask rewrite, and changelog-sourced notes; no real release.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
fail() { echo "release-e2e: FAIL: $*" >&2; exit 1; }

# Hermetic clone so the real repo, working tree, and tags are never touched.
CLONE="$WORK/repo"
git clone -q "$REPO" "$CLONE"
# Overlay the working-tree files under test so we exercise uncommitted changes.
cp "$REPO/scripts/release.sh" "$CLONE/scripts/release.sh"
[ -f "$REPO/cliff.toml" ] && cp "$REPO/cliff.toml" "$CLONE/cliff.toml"
cd "$CLONE"
git config user.email e2e@test
git config user.name e2e
# Throwaway version so v0.0.0-e2e never collides with a real tag and the
# clean-tree gate holds.
echo "0.0.0-e2e" > VERSION
git add -A
git commit -q -m "chore: e2e setup"

# Temp tap with a sentinel cask to prove version/sha256 are rewritten. The two
# leading spaces on version/sha256 match release.sh's sed anchors.
TAP="$WORK/tap"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/claude-monitor.rb" <<'RUBY'
cask "claude-monitor" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  app "Claude Monitor.app"
end
RUBY

OUT=$(CM_TAP_DIR="$TAP" bash scripts/release.sh --dry-run)
echo "$OUT"

ZIP="dist/ClaudeMonitor-0.0.0-e2e.zip"
[ -f "$ZIP" ] || fail "zip artifact not produced"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

CASK_TMP=$(echo "$OUT" | sed -n 's/^release: cask updated: //p')
[ -n "$CASK_TMP" ] && [ -f "$CASK_TMP" ] || fail "dry-run temp cask not found in output"
grep -q 'version "0.0.0-e2e"' "$CASK_TMP" || fail "temp cask version not synced"
grep -q "sha256 \"$SHA\"" "$CASK_TMP" || fail "temp cask sha256 not synced"

# Notes must come from the generated changelog (version header), not the static
# fallback string.
echo "$OUT" | grep -q '## \[0.0.0-e2e\]' || fail "release notes not sourced from changelog"

# Dry run must not create a tag.
if git rev-parse -q --verify refs/tags/v0.0.0-e2e >/dev/null; then
    fail "dry run created a tag"
fi

echo "RELEASE E2E PASS"
```

Then: `chmod +x scripts/release-e2e.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/release-e2e.sh`
Expected: FAIL at "release notes not sourced from changelog" — the current `release.sh` uses a static `--notes` string and does not echo notes on dry-run.
(Prerequisite: the `claude-monitor-signing` identity must exist in the keychain — the same gate a real release requires. See `docs/signing.md`.)

- [ ] **Step 3: Modify `scripts/release.sh`**

Replace the dry-run / publish block (current lines 34-39):

```bash
if [ "$DRY_RUN" = "1" ]; then
    echo "release: DRY RUN — skipping: gh release create $TAG"
else
    gh release create "$TAG" "$ZIP" --title "Claude Monitor $VERSION" \
        --notes "Signed (self-signed identity), un-notarized. See the README for install and first-launch steps."
fi
```

with:

```bash
# Release notes come from the changelog section for this version. --unreleased
# --tag names the pending version correctly even though the tag does not exist
# yet (gh release create makes it). Fall back to a static string if git-cliff
# is unavailable.
NOTES=""
if command -v git-cliff >/dev/null 2>&1; then
    NOTES=$(git cliff --unreleased --tag "$TAG" 2>/dev/null || true)
fi
if [ -z "$NOTES" ]; then
    NOTES="Signed (self-signed identity), un-notarized. See the README for install and first-launch steps."
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "release: DRY RUN — skipping: gh release create $TAG"
    echo "release: --- release notes ---"
    echo "$NOTES"
    echo "release: --- end notes ---"
else
    gh release create "$TAG" "$ZIP" --title "Claude Monitor $VERSION" --notes "$NOTES"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/release-e2e.sh`
Expected: `RELEASE E2E PASS` (a full release build runs, so this takes ~1 minute).

- [ ] **Step 5: Add the `test-release` make target**

In `Makefile`, add `test-release` to `.PHONY` and add:

```makefile
test-release:
	bash scripts/release-e2e.sh
```

Verify: `make test-release` prints `RELEASE E2E PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh scripts/release-e2e.sh Makefile
git commit -m "feat: release notes sourced from changelog, with dry-run e2e test"
```

---

## Task 4: Homebrew cask in the tap repo

**Files (tap repo `~/me/claude/homebrew-tap`):**
- Create: `~/me/claude/homebrew-tap/Casks/claude-monitor.rb`
- Create: `~/me/claude/homebrew-tap/README.md`

**Files (monitor repo):**
- Modify: `Makefile`

- [ ] **Step 1: Write the cask** `~/me/claude/homebrew-tap/Casks/claude-monitor.rb`

Exact content (validated: passes `brew style` with zero offenses):

```ruby
cask "claude-monitor" do
  version "1.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/dulguun-tuguldur/claude-monitor/releases/download/v#{version}/ClaudeMonitor-#{version}.zip"
  name "Claude Monitor"
  desc "Menu bar app showing Claude Code account usage at a glance"
  homepage "https://github.com/dulguun-tuguldur/claude-monitor"

  depends_on macos: :ventura

  app "Claude Monitor.app"

  zap trash: "~/Library/Preferences/mn.tanasoft.claude-monitor.settings.plist"

  caveats <<~EOS
    Claude Monitor is self-signed and not notarized, so on first launch macOS
    Gatekeeper will refuse to open it. To open it the first time:
      - Right-click "Claude Monitor" in /Applications, choose Open, then Open
        again in the dialog; or
      - System Settings > Privacy & Security > "Open Anyway".
    This is a one-time step per installed version.
  EOS
end
```

Notes: `sha256` is a placeholder until the first release fills it (`release.sh` keeps `version`/`sha256` current thereafter). `depends_on macos: :ventura` means ">= Ventura" and matches `LSMinimumSystemVersion 13.0`. `zap` targets the app's real UserDefaults suite `mn.tanasoft.claude-monitor.settings` (deliberately not the bundle id — see commit `17eec9d`).

- [ ] **Step 2: Write the tap README** `~/me/claude/homebrew-tap/README.md`

```markdown
# homebrew-tap

Homebrew tap for [Dulguun Tuguldur](https://github.com/dulguun-tuguldur)'s tools.

## Claude Monitor

A native macOS menu bar app showing Claude Code account usage at a glance.

```sh
brew tap dulguun-tuguldur/tap
brew install --cask claude-monitor
```

Claude Monitor is self-signed and not notarized. On first launch macOS
Gatekeeper will refuse to open it — right-click the app in `/Applications`,
choose **Open**, then **Open** again in the dialog (a one-time step per
installed version). See the cask caveats for details.
```

- [ ] **Step 3: Validate the cask with `brew style`**

Run: `brew style ~/me/claude/homebrew-tap/Casks/claude-monitor.rb`
Expected: `1 file inspected, no offenses detected`.
(`brew audit --cask claude-monitor` is deferred to after the tap is tapped — `brew audit [path]` is disabled; it needs a tapped name. Documented in `docs/releasing.md`.)

- [ ] **Step 4: Add the `test-cask` make target and `CM_TAP_DIR` default**

In the monitor `Makefile`: add `test-cask` to `.PHONY`, add a `CM_TAP_DIR` default near the top (after the ABOUTME header), and add the target:

```makefile
CM_TAP_DIR ?= ../homebrew-tap
```

```makefile
test-cask:
	brew style "$(CM_TAP_DIR)/Casks/claude-monitor.rb"
```

Verify: `make test-cask` prints `no offenses detected`.

- [ ] **Step 5: Commit in the tap repo**

```bash
git -C ~/me/claude/homebrew-tap add Casks/claude-monitor.rb README.md
git -C ~/me/claude/homebrew-tap commit -m "feat: claude-monitor cask"
```

- [ ] **Step 6: Commit the Makefile change in the monitor repo**

```bash
git add Makefile
git commit -m "chore: make test-cask target and CM_TAP_DIR default"
```

---

## Task 5: Docs — releasing guide, README, CLAUDE.md

**Files:**
- Create: `docs/releasing.md`
- Modify: `README.md:11-30`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Write `docs/releasing.md`**

```markdown
# Releasing Claude Monitor

Two commands, split on purpose:

- `make bump` — safe, local, reversible. Derives the next version from commits.
- `make release` — the single outward-facing, irreversible step.

Releases are built **locally** and signed with the self-signed
`claude-monitor-signing` identity in the login keychain (no Apple Developer
account, no notarization, no CI signing secrets — see `docs/signing.md`). The
Homebrew tap push stays **manual**.

## Prerequisites

- `brew install git-cliff` — derives versions and the changelog.
- `gh` authenticated (`gh auth status`) — publishes GitHub Releases.
- The `claude-monitor-signing` identity in the keychain (`docs/signing.md`).
- The tap cloned as a sibling of this repo at `~/me/claude/homebrew-tap`
  (`CM_TAP_DIR` defaults to `../homebrew-tap`).

## Conventional commits

Version bumps and the changelog are derived from
[conventional commit](https://www.conventionalcommits.org/) messages
(`feat:`, `fix:`, `docs:`, `chore:`, …). `feat` → minor bump, `fix` → patch
bump, `feat!`/`BREAKING CHANGE` → major. Non-conventional commits still render
under an "Other" section. `chore(release):` commits are skipped in the
changelog.

## Normal release

```sh
make bump        # derive vX.Y.Z, rewrite VERSION + CHANGELOG.md, commit
git push         # push the release commit
make release     # tag, build, verify, zip, publish, sync the cask
```

Then review and push the tap:

```sh
cd ~/me/claude/homebrew-tap
git diff                 # confirm version + sha256 changed
git commit -am "claude-monitor X.Y.Z"
git push
```

## First release (v1.0.0) — special case

git-cliff derives versions from tags, and there are none yet, so the first
release **skips `make bump`**. `VERSION` is already `1.0.0` and `CHANGELOG.md`
was generated once at setup (`git cliff --tag v1.0.0 -o CHANGELOG.md`). Go
straight to:

```sh
make release     # cuts v1.0.0
```

`bump.sh` enforces this: it refuses to run until a prior tag exists.

## Publishing the tap the first time

```sh
gh repo create dulguun-tuguldur/homebrew-tap --public --source=~/me/claude/homebrew-tap --push
```

After the first release fills the cask's `sha256`, verify the install path:

```sh
brew tap dulguun-tuguldur/tap
brew audit --cask claude-monitor      # now that it is tapped
brew install --cask claude-monitor
```

## Tests

- `make test-bump` — bump.sh in a throwaway repo.
- `make test-release` — release.sh --dry-run in a throwaway clone (full build).
- `make test-cask` — `brew style` on the cask.

## Upgrade path (out of scope today)

Notarization / Apple Developer ID would remove the Gatekeeper first-launch
step. It is deliberately deferred: it needs a paid account and would push the
signing identity into CI, a worse security story for a small-circle tool.
```

- [ ] **Step 2: Update the README Install section**

Replace `README.md` lines 11-30 (the `## Install` section through the install steps, up to but not including `### First-run Keychain prompt`) with:

```markdown
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
```

- [ ] **Step 3: Add release make targets to the README command table**

In `README.md`, in the `## Build / test commands` table, add these rows after the `make test` row:

```markdown
| `make bump` | Runs `scripts/bump.sh`: derives the next version + changelog from commits |
| `make test-bump` | Runs `scripts/bump-e2e.sh`: bump.sh in a throwaway repo |
| `make release` | Runs `scripts/release.sh`: build, verify, zip, publish, sync cask |
| `make test-release` | Runs `scripts/release-e2e.sh`: dry-run release in a throwaway clone |
| `make test-cask` | `brew style` on the Homebrew cask |
```

- [ ] **Step 4: Update `CLAUDE.md`**

In `CLAUDE.md`, in the `## Docs` list, add after the design-spec line:

```markdown
- Release process: `docs/releasing.md`
```

And add a new section before `## Docs`:

```markdown
## Releasing

Commits follow [conventional commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `docs:`, `chore:`, …) — `make bump` derives the next version
and changelog from them. See `docs/releasing.md` for the full flow.
```

- [ ] **Step 5: Verify the docs build/read cleanly**

Run: `grep -c "brew tap dulguun-tuguldur/tap" README.md docs/releasing.md`
Expected: `README.md:1` and `docs/releasing.md:1` (both mention the tap).

- [ ] **Step 6: Commit**

```bash
git add README.md docs/releasing.md CLAUDE.md
git commit -m "docs: Homebrew install, releasing guide, conventional-commit norm"
```

---

## Task 6 (HUMAN CHECKPOINT): publish the tap and cut v1.0.0

These are outward-facing, irreversible steps that require the signing identity
and `gh` auth. They are executed **by Mr. D**, reviewed together, not run
autonomously. Confirm before each.

- [ ] **Step 1: Confirm prerequisites**

Run: `gh auth status && security find-identity -v -p codesigning | grep claude-monitor-signing`
Expected: gh logged in as `dulguun-tuguldur`; the signing identity is listed.

- [ ] **Step 2: Full local test pass**

Run: `make test && make test-bump && make test-release && make test-cask`
Expected: all green (`Test Suite ... passed`, `BUMP E2E PASS`, `RELEASE E2E PASS`, `no offenses detected`).

- [ ] **Step 3: Create the public tap repo and push it**

Run: `gh repo create dulguun-tuguldur/homebrew-tap --public --source=$HOME/me/claude/homebrew-tap --remote=origin --push`
Expected: repo created, initial cask commit pushed.

- [ ] **Step 4: Cut the first release**

Run (in the monitor repo, clean tree): `make release`
Expected: `v1.0.0` tag + GitHub Release created with changelog notes and the zip; `release.sh` rewrites the tap cask's `version`/`sha256` in place and prints "review, commit, and push the tap manually."

- [ ] **Step 5: Review and push the tap cask**

```bash
cd ~/me/claude/homebrew-tap
git diff                              # version stays 1.0.0, sha256 now real
brew audit --cask ./Casks/claude-monitor.rb || true
git commit -am "claude-monitor 1.0.0"
git push
```

- [ ] **Step 6: Verify the install path end-to-end**

```bash
brew untap dulguun-tuguldur/tap 2>/dev/null || true
brew tap dulguun-tuguldur/tap
brew audit --cask claude-monitor
brew install --cask claude-monitor
```
Expected: the cask audits clean and installs; `Claude Monitor.app` lands in `/Applications` (open it via right-click → Open the first time).

---

## Self-review against the spec

- Version management (git-cliff): Tasks 1, 2 — `cliff.toml`, `CHANGELOG.md`, `make bump`, no-prior-tag refusal. ✓
- Homebrew tap + cask: Task 4 + Task 6 (publish). Cask matches `release.sh`'s `$CM_TAP_DIR/Casks/claude-monitor.rb` path, `zap` targets the settings suite, Gatekeeper caveat. ✓
- `release.sh` change (changelog notes): Task 3 (with the `--unreleased --tag` correctness fix). ✓
- Docs (README, releasing.md, CLAUDE.md): Task 5, including the "ad-hoc signed" wording fix and Gatekeeper note. ✓
- First-release special case: Task 5 docs + Task 6 procedure; `bump.sh` enforces the no-prior-tag refusal (Task 2). ✓
- Testing (unit/integration/e2e): existing `make test` (unit) unchanged; `bump-e2e.sh` (integration, Task 2); `release-e2e.sh` (e2e, Task 3); `brew style` cask validity (Task 4). ✓
- Out of scope respected: no notarization, no CI releases, tap push stays manual (Task 6 is human-run). ✓
```

