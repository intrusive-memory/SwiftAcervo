# GEMINI.md

**Read [AGENTS.md](AGENTS.md) first** for universal project documentation.

**SwiftAcervo** -- Shared AI model discovery and management.

**Version**: 0.7.0

Canonical model path: App Group container (`group.intrusive-memory.models`) + `SharedModels/{org}_{repo}/`

Platforms: iOS 26.0+, macOS 26.0+ only. Zero external dependencies (Foundation + CryptoKit).

## Build and Test

```bash
xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'
xcodebuild test -scheme SwiftAcervo-Package -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```
