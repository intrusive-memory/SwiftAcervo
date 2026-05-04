# GEMINI.md

**Read [AGENTS.md](AGENTS.md) first** for universal project documentation.

**SwiftAcervo** -- Shared AI model discovery and management.

**Version**: 0.11.1

Canonical model path: App Group container (`group.intrusive-memory.models`) + `SharedModels/{org}_{repo}/`

Platforms: iOS 26.0+, macOS 26.0+ only. Zero external dependencies (Foundation + CryptoKit).

## Manifest-First File Selection

Consuming libraries do not know what files exist inside a model until the CDN manifest returns. The manifest is the only authoritative source. Prefer `ModelDownloadManager.ensureModelsAvailable([...])`, `Acervo.ensureAvailable(modelId, files: [])`, or `Acervo.ensureComponentReady(componentId)` over hard-coding a `files: [...]` array; the empty form means "download whatever the manifest says." See [USAGE.md](USAGE.md) for the full integration guide.

## Build and Test

```bash
xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS'
xcodebuild test -scheme SwiftAcervo-Package -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
```
