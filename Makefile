SCHEME = SwiftAcervo
DESTINATION = 'platform=macOS'

.PHONY: build test clean resolve help

build:
	xcodebuild build -scheme $(SCHEME) -destination $(DESTINATION)

test:
	xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION)

clean:
	xcodebuild clean -scheme $(SCHEME) -destination $(DESTINATION)
	rm -rf .build

resolve:
	swift package resolve

help:
	@echo "Available targets:"
	@echo "  build   - Build the SwiftAcervo scheme"
	@echo "  test    - Run all tests"
	@echo "  clean   - Clean build artifacts"
	@echo "  resolve - Resolve Swift package dependencies"
	@echo "  help    - Show this help message"
