SCHEME = SwiftAcervo
TEST_SCHEME = SwiftAcervo-Package
DESTINATION = 'platform=macOS,arch=arm64'
IOS_DESTINATION = 'platform=iOS Simulator,name=iPhone 17,OS=26.1'

MACOS_TESTPLAN = SwiftAcervo-macOS
IOS_TESTPLAN = SwiftAcervo-iOS

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

.PHONY: build test test-ios clean resolve lint help release \
        build-acervo install-acervo release-acervo \
        test-acervo-unit test-acervo-cdn

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

help:
	@echo "Available targets:"
	@echo "  build                    - Build the SwiftAcervo scheme"
	@echo "  test                     - Run macOS test plan (SwiftAcervoTests + AcervoToolTests)"
	@echo "  test-ios                 - Run iOS test plan (SwiftAcervoTests only) on iPhone 17 simulator"
	@echo "  clean                    - Clean build artifacts"
	@echo "  resolve                  - Resolve Swift package dependencies"
	@echo "  lint                     - Format all Swift source files"
	@echo "  build-acervo             - Build the acervo CLI binary"
	@echo "  install-acervo           - Build acervo and install to $(BIN_DIR)/ (Debug)"
	@echo "  release                  - Alias for release-acervo (used by CI)"
	@echo "  release-acervo           - Build acervo and install to $(BIN_DIR)/ (Release)"
	@echo "  test-acervo-unit         - Run acervo CLI unit tests (macOS only, no credentials)"
	@echo "  test-acervo-cdn          - Fetch and verify a known CDN manifest (macOS only, network, no creds)"
	@echo "  help                     - Show this help message"
