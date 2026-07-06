# ABOUTME: Developer entry points for building, testing, bundling, and running
# ABOUTME: the Claude Monitor menu bar app.
.PHONY: build test e2e app verify-app run

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

run:
	swift run ClaudeMonitor
