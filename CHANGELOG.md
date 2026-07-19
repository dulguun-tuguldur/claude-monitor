# Changelog

All notable changes to Claude Monitor are documented in this file.
It is generated from conventional commit messages by git-cliff.
## [1.1.0] - 2026-07-19

### Features

- Read keychain credentials via security CLI subprocess
- Write keychain credentials via security CLI over stdin

### Documentation

- Design spec for silent keychain access via security CLI
- Implementation plan for silent keychain access via security CLI
- Rewrite silent-keychain-access plan with spike-verified CLI behavior

### Testing

- Create keychain fixtures via security CLI so subprocess reads don't prompt
## [1.0.1] - 2026-07-07

### Bug Fixes

- Discover default account via home-level ~/.claude.json
## [1.0.0] - 2026-07-07

### Other

- Releases, versioning & homebrew distribution (Tasks 1-5)

### Features

- Account model and .claude* discovery
- Credential parsing, expiry, write-back JSON
- Usage snapshot parsing with lenient windows
- Bar formatter with color levels
- Keychain credential store with update-only writes
- Usage client and token refresher over mockable URLSession
- Settings store
- Polling engine with refresh write-back and stale degradation
- Menu bar app with account dropdown and print-once mode
- Settings window with interval, hidden accounts, launch at login
- App bundling, e2e harness, make targets, readme
- Show session reset time in the menu bar
- Verify-app packaging gate (signature, identity pin, version)
- Stable signing identity + VERSION injection in app bundling
- Release script — build, verify, zip, publish, cask sync
- Git-cliff changelog config and initial CHANGELOG
- Make bump — git-cliff version + changelog bump, with integration test
- Release notes sourced from changelog, with dry-run e2e test

### Bug Fixes

- Distinguish auth failure from transient error in 401-retry path
- Resolve non-default keychain service via SHA-256 path prefix
- UserDefaults suite name must differ from the bundle identifier
- Release.sh defaults CM_TAP_DIR to sibling tap so cask sync always runs

### Documentation

- Replace plan/design stubs with verbatim plan and derived design spec
- Signing guide for the self-signed identity + journal entry
- Design spec for releases, versioning & homebrew distribution
- Homebrew install, releasing guide, conventional-commit norm
- Implementation plan for releases, versioning & homebrew
- Brew trust + existing-app / sha256-fix notes in releasing guide

### Miscellaneous

- Bootstrap claude-monitor package, spike results, fixtures
- MIT license
- Keep the project journal local-only
- New user enroll, gettin started, readme
- Make test-cask target and CM_TAP_DIR default

