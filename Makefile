SCHEME = SwiftAcervo
DESTINATION = 'platform=macOS,arch=arm64'

.PHONY: build test clean resolve lint help

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

help:
	@echo "Available targets:"
	@echo "  build   - Build the SwiftAcervo scheme"
	@echo "  test    - Run all tests"
	@echo "  clean   - Clean build artifacts"
	@echo "  resolve - Resolve Swift package dependencies"
	@echo "  lint    - Format all Swift source files"
	@echo "  help    - Show this help message"
