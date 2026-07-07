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
