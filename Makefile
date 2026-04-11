SCHEME = SwiftAcervo
DESTINATION = 'platform=macOS,arch=arm64'

ACERVO_SCHEME = acervo
ACERVO_BINARY = acervo
BIN_DIR = bin
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

.PHONY: build test clean resolve lint help \
        build-acervo install-acervo release-acervo \
        test-acervo-unit test-acervo-integration test-acervo-cdn

build:
	xcodebuild build -scheme $(SCHEME) -destination $(DESTINATION)

test:
	xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION)

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
	xcodebuild test -scheme $(ACERVO_SCHEME) -destination $(DESTINATION) \
	  -only-testing:AcervoToolTests

test-acervo-integration: resolve
	xcodebuild test -scheme $(ACERVO_SCHEME) -destination $(DESTINATION) \
	  -only-testing:AcervoToolIntegrationTests

test-acervo-cdn: resolve
	xcodebuild test -scheme $(ACERVO_SCHEME) -destination $(DESTINATION) \
	  -only-testing:AcervoToolTests/CDNManifestFetchTests

help:
	@echo "Available targets:"
	@echo "  build                    - Build the SwiftAcervo scheme"
	@echo "  test                     - Run all tests"
	@echo "  clean                    - Clean build artifacts"
	@echo "  resolve                  - Resolve Swift package dependencies"
	@echo "  lint                     - Format all Swift source files"
	@echo "  build-acervo             - Build the acervo CLI binary"
	@echo "  install-acervo           - Build acervo and install to $(BIN_DIR)/ (Debug)"
	@echo "  release-acervo           - Build acervo and install to $(BIN_DIR)/ (Release)"
	@echo "  test-acervo-unit         - Run acervo unit tests (no credentials)"
	@echo "  test-acervo-integration  - Run acervo integration tests (requires R2_* + HF_TOKEN)"
	@echo "  test-acervo-cdn          - Fetch and verify a known CDN manifest (network, no creds)"
	@echo "  help                     - Show this help message"
