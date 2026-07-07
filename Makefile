# ABOUTME: Developer entry points for building, testing, bundling, and running
# ABOUTME: the Claude Monitor menu bar app.
.PHONY: build test e2e app verify-app release run new-account test-new-account bump test-bump test-release test-cask

# Homebrew tap checkout (sibling of this repo by default); holds the cask.
# Exported so `make release` / `make release CM_TAP_DIR=...` reaches release.sh.
CM_TAP_DIR ?= ../homebrew-tap
export CM_TAP_DIR

build:
	swift build

test:
	swift test

e2e:
	bash scripts/e2e.sh

app:
	bash scripts/make-app.sh

verify-app:
	bash scripts/verify-app.sh

release:
	bash scripts/release.sh

bump:
	bash scripts/bump.sh

test-bump:
	bash scripts/bump-e2e.sh

test-release:
	bash scripts/release-e2e.sh

test-cask:
	brew style "$(CM_TAP_DIR)/Casks/claude-monitor.rb"

run:
	swift run ClaudeMonitor

new-account:
	bash scripts/new-account.sh $(NAME) $(FROM)

test-new-account:
	bash scripts/new-account-e2e.sh
