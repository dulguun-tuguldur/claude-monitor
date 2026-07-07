# ABOUTME: Developer entry points for building, testing, bundling, and running
# ABOUTME: the Claude Monitor menu bar app.
.PHONY: build test e2e app verify-app release run new-account test-new-account bump test-bump

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

run:
	swift run ClaudeMonitor

new-account:
	bash scripts/new-account.sh $(NAME) $(FROM)

test-new-account:
	bash scripts/new-account-e2e.sh
