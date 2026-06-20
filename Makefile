SCHEME = SwiftAcervo
TEST_SCHEME = SwiftAcervo-Package
DESTINATION = 'platform=macOS,arch=arm64'
IOS_DESTINATION = 'platform=iOS Simulator,name=iPhone 17,OS=26.1'

MACOS_TESTPLAN = SwiftAcervo-macOS
IOS_TESTPLAN = SwiftAcervo-iOS
PERF_TESTPLAN = SwiftAcervo-Performance
TESTPLAN_DIR = .swiftpm/xcode/xcshareddata/xctestplans

ACERVO_SCHEME = acervo
ACERVO_BINARY = acervo
BIN_DIR = bin
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

# Test runs read ACERVO_APP_GROUP_ID from per-platform test plans under
# .swiftpm/xcode/xcshareddata/xctestplans/. Each plan sets the value to
# `group.acervo.testbundle.default` so tests never write into a developer's
# real shared-models directory. Individual tests that need stricter
# isolation override the value per-test via the `withIsolatedAcervoState`
# helper. Shell env vars are NOT propagated by xcodebuild to the xctest
# runner, so the test plan is the only reliable channel.
#
# SwiftAcervo-macOS plan → SwiftAcervoTests + AcervoToolTests
# SwiftAcervo-iOS   plan → SwiftAcervoTests only (acervo CLI target uses
#                          Foundation.Process, which is unavailable on iOS)

.PHONY: build test test-ios test-perf test-plan-shape clean resolve lint help release \
        build-acervo install-acervo release-acervo \
        test-acervo-unit test-acervo-cdn codesign-cli

build:
	xcodebuild build -scheme $(SCHEME) -destination $(DESTINATION)

test:
	xcodebuild test -scheme $(TEST_SCHEME) -testPlan $(MACOS_TESTPLAN) \
	  -destination $(DESTINATION)

test-ios:
	xcodebuild test -scheme $(TEST_SCHEME) -testPlan $(IOS_TESTPLAN) \
	  -destination $(IOS_DESTINATION) \
	  -skipPackagePluginValidation \
	  ONLY_ACTIVE_ARCH=YES \
	  COMPILER_INDEX_STORE_ENABLE=NO

test-perf:
	xcodebuild test -scheme $(TEST_SCHEME) -testPlan $(PERF_TESTPLAN) \
	  -destination $(DESTINATION)

# Shape gate: assert no test class except StreamingPerformanceTests appears in
# skippedTests on the CI plans (macOS + iOS). The Performance plan is excluded
# because it legitimately skips most suites until a real perf test is added.
# Exits non-zero and names the offending class if the invariant is violated.
test-plan-shape:
	@echo "==> Validating test plan shape (CI plans only)..."
	@for PLAN in $(TESTPLAN_DIR)/SwiftAcervo-macOS.xctestplan \
	             $(TESTPLAN_DIR)/SwiftAcervo-iOS.xctestplan; do \
	  OFFENDERS=$$(jq -r ' \
	    .testTargets \
	    | map(.skippedTests // []) \
	    | flatten \
	    | map(select(. != "StreamingPerformanceTests")) \
	    | .[] \
	  ' "$$PLAN" 2>/dev/null); \
	  if [ -n "$$OFFENDERS" ]; then \
	    echo "FAIL: $$(basename $$PLAN) has disallowed skippedTests entries:"; \
	    echo "$$OFFENDERS" | sed 's/^/  - /'; \
	    exit 1; \
	  fi; \
	  echo "  OK: $$(basename $$PLAN)"; \
	done
	@echo "==> All CI test plans pass shape gate."

clean:
	xcodebuild clean -scheme $(SCHEME) -destination $(DESTINATION)
	rm -rf .build

resolve:
	swift package resolve

lint:
	swift format -i -r .

build-acervo: resolve
	xcodebuild -scheme $(ACERVO_SCHEME) -destination $(DESTINATION) build

install-acervo: resolve
	xcodebuild -scheme $(ACERVO_SCHEME) -destination $(DESTINATION) build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftAcervo-*/Build/Products/Debug \
	  -name $(ACERVO_BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
	  cp "$$PRODUCT_DIR/$(ACERVO_BINARY)" $(BIN_DIR)/; \
	  echo "Installed $(ACERVO_BINARY) to $(BIN_DIR)/ (Debug)"; \
	else \
	  echo "Error: Could not find $(ACERVO_BINARY) in DerivedData"; exit 1; \
	fi

release: release-acervo

release-acervo: resolve
	xcodebuild -scheme $(ACERVO_SCHEME) -destination $(DESTINATION) \
	  -configuration Release build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftAcervo-*/Build/Products/Release \
	  -name $(ACERVO_BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
	  cp "$$PRODUCT_DIR/$(ACERVO_BINARY)" $(BIN_DIR)/; \
	  echo "Installed $(ACERVO_BINARY) to $(BIN_DIR)/ (Release)"; \
	else \
	  echo "Error: Could not find $(ACERVO_BINARY) in DerivedData"; exit 1; \
	fi

test-acervo-unit: resolve
	xcodebuild test -scheme $(TEST_SCHEME) -testPlan $(MACOS_TESTPLAN) \
	  -destination $(DESTINATION) \
	  -only-testing:AcervoToolTests

test-acervo-cdn: resolve
	xcodebuild test -scheme $(TEST_SCHEME) -testPlan $(MACOS_TESTPLAN) \
	  -destination $(DESTINATION) \
	  -only-testing:AcervoToolTests/CDNManifestFetchTests

# ── App Group code-signing ────────────────────────────────────────────────
# Sign the acervo CLI with the com.apple.security.application-groups entitlement
# so the group ID is embedded in the binary and SwiftAcervo resolves the shared
# models container (~/Library/Group Containers/group.intrusive-memory.models/)
# WITHOUT requiring ACERVO_APP_GROUP_ID in the environment. Container access is
# plain POSIX (same-user, mode 700); the entitlement only supplies the group
# identifier at runtime via SecTaskCopyValueForEntitlement.
#
# Default identity is ad-hoc (-), which is sufficient for the entitlement to be
# read back at runtime. For a distributable build, override with a Developer ID
# by certificate SHA-1 (names collide in the keychain):
#   make install-acervo codesign-cli CODESIGN_IDENTITY=<sha1>
APP_GROUP_ID ?= group.intrusive-memory.models
CODESIGN_IDENTITY ?= -
CODESIGN_FLAGS ?=
CODESIGN_ENTITLEMENTS ?= cli.entitlements

codesign-cli:
	@test -f "$(BIN_DIR)/$(ACERVO_BINARY)" || { echo "Error: $(BIN_DIR)/$(ACERVO_BINARY) not found — run 'make install-acervo' or 'make release-acervo' first."; exit 1; }
	@codesign --force --sign "$(CODESIGN_IDENTITY)" --entitlements "$(CODESIGN_ENTITLEMENTS)" $(CODESIGN_FLAGS) "$(BIN_DIR)/$(ACERVO_BINARY)"
	@echo "Signed $(BIN_DIR)/$(ACERVO_BINARY) (identity: $(CODESIGN_IDENTITY), group: $(APP_GROUP_ID))"
	@codesign -d --entitlements - "$(BIN_DIR)/$(ACERVO_BINARY)" 2>/dev/null | grep -A1 "application-groups" || true

help:
	@echo "Available targets:"
	@echo "  build                    - Build the SwiftAcervo scheme"
	@echo "  test                     - Run macOS test plan (SwiftAcervoTests + AcervoToolTests)"
	@echo "  test-ios                 - Run iOS test plan (SwiftAcervoTests only) on iPhone 17 simulator"
	@echo "  test-perf                - Run performance test plan (opt-in; not run in CI)"
	@echo "  test-plan-shape          - Validate CI test plans have no disallowed skippedTests entries"
	@echo "  clean                    - Clean build artifacts"
	@echo "  resolve                  - Resolve Swift package dependencies"
	@echo "  lint                     - Format all Swift source files"
	@echo "  build-acervo             - Build the acervo CLI binary"
	@echo "  install-acervo           - Build acervo and install to $(BIN_DIR)/ (Debug)"
	@echo "  release                  - Alias for release-acervo (used by CI)"
	@echo "  release-acervo           - Build acervo and install to $(BIN_DIR)/ (Release)"
	@echo "  codesign-cli             - Sign the acervo CLI with the App Group entitlement (run after install/release)"
	@echo "  test-acervo-unit         - Run acervo CLI unit tests (macOS only, no credentials)"
	@echo "  test-acervo-cdn          - Fetch and verify a known CDN manifest (macOS only, network, no creds)"
	@echo "  help                     - Show this help message"
