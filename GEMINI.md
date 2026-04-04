# GEMINI.md

**Read [AGENTS.md](AGENTS.md) first** for universal project documentation.

**SwiftAcervo** -- Shared AI model discovery and management.

**Version**: 0.5.5

Canonical model path: App Group container (`group.intrusive-memory.models`) + `SharedModels/{org}_{repo}/`

Platforms: iOS 26.0+, macOS 26.0+ only. Zero external dependencies (Foundation + CryptoKit).

## Build and Test

```bash
xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'
xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'
```
