.DEFAULT_GOAL := help

.PHONY: help
help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the app for a simulator (DESTINATION='platform=iOS Simulator,name=...' to choose one)
	./scripts/test.sh build

.PHONY: test
test: ## Build the app and run the unit tests on a simulator (DESTINATION to choose one)
	./scripts/test.sh test

.PHONY: lint
lint: ## Check the sources with swift format, strictly
	xcrun swift-format lint --strict --recursive --configuration .swift-format WDIG WDIGTests

.PHONY: ci
ci: ## Everything a merge needs, on a clean checkout of the merge result
	./scripts/ci.sh

.PHONY: phone
phone: ## Install a Debug build on the phone over Wi-Fi and report the build the phone has
	./scripts/wifi-install.sh

.PHONY: testflight
testflight: ## Archive, sign in the cloud and upload to TestFlight, from a clean main, once per commit
	./scripts/deploy-testflight.sh

.PHONY: testflight-status
testflight-status: ## Builds, groups and testers as App Store Connect sees them
	./scripts/testflight-status.sh
