# AGENTS.md

This file provides comprehensive documentation for AI agents working with the SwiftAcervo codebase.

**Current Version**: 0.6.0 (April 2026)

---

## Project Overview

Consumers need AI models available locally, but model names vary and multiple tools shouldn't each maintain their own copy. SwiftAcervo solves this by providing **model discovery with fuzzy name matching** and **CDN-verified downloads** into a single shared App Group container (`group.intrusive-memory.models`). A model downloaded by one tool is immediately available to all others -- no duplication, no hardcoded paths.

All downloads come exclusively from a private Cloudflare R2 CDN with per-file SHA-256 integrity verification. All downloads are CDN-only.

## Shared Models Directory

**CRITICAL**: All intrusive-memory projects MUST use SwiftAcervo's `sharedModelsDirectory` for model storage. This resolves to the App Group container for `group.intrusive-memory.models` (sandboxed apps) or `Application Support/SwiftAcervo/SharedModels/` (fallback).

```
<App Group Container>/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
├── mlx-community_snac_24khz/
└── ...
```

**Rules**:
- Base directory: `Acervo.sharedModelsDirectory` (App Group container + `SharedModels/`)
- Naming: Model ID with `/` replaced by `_`
- No type subdirectories (LLM, TTS, Audio are all peers)
- Validity: `config.json` must be present in model directory
- NEVER hardcode a different model path in any project

## Project Structure

- `Sources/SwiftAcervo/Acervo.swift` -- Static discovery + download API (version constant)
- `Sources/SwiftAcervo/AcervoManager.swift` -- Actor-based thread-safe manager
- `Sources/SwiftAcervo/AcervoModel.swift` -- Model metadata struct
- `Sources/SwiftAcervo/AcervoError.swift` -- Error types (7 manifest/CDN errors added in v0.4.0)
- `Sources/SwiftAcervo/AcervoDownloader.swift` -- CDN download logic with manifest verification
- `Sources/SwiftAcervo/AcervoDownloadProgress.swift` -- Download progress tracking
- `Sources/SwiftAcervo/AcervoMigration.swift` -- Legacy path migration
- `Sources/SwiftAcervo/LevenshteinDistance.swift` -- Edit distance for fuzzy search
- `Sources/SwiftAcervo/CDNManifest.swift` -- Per-model manifest types and checksum verification
- `Sources/SwiftAcervo/SecureDownloadSession.swift` -- URLSession with redirect rejection
- `Sources/SwiftAcervo/IntegrityVerification.swift` -- Streaming SHA-256 and file verification
- `Sources/SwiftAcervo/ComponentDescriptor.swift` -- Declarative component types
- `Sources/SwiftAcervo/ComponentHandle.swift` -- Type-safe file access after download
- `Sources/SwiftAcervo/ComponentRegistry.swift` -- Thread-safe global component registry
- `Sources/SwiftAcervo/LocalHandle.swift` -- Scoped access handle for caller-supplied local paths
- `Tools/generate-manifest.sh` -- Generate manifest.json for a model directory
- `Tools/upload-model.sh` -- Full upstream → manifest → R2 upload workflow
- `Tests/SwiftAcervoTests/` -- 371 unit tests
- `Package.swift` -- Swift 6.2+, iOS 26.0+, macOS 26.0+

## CDN Download Architecture

All downloads go through the private R2 CDN:

**CDN base URL**: `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/`

**URL pattern**: `{cdnBase}/{slug}/{fileName}`

**Download flow**:
1. Fetch `manifest.json` for the model from CDN
2. Validate manifest version, model ID, and checksum-of-checksums
3. For each requested file, verify it exists in the manifest
4. Download each file using `SecureDownloadSession` (rejects non-CDN redirects)
5. Verify file size against manifest
6. Verify SHA-256 against manifest
7. Move to destination atomically

**Manifest format** (`manifest.json`):
```json
{
  "manifestVersion": 1,
  "modelId": "org/repo",
  "slug": "org_repo",
  "updatedAt": "2026-03-22T00:00:00Z",
  "files": [
    {"path": "config.json", "sha256": "...", "sizeBytes": 1234}
  ],
  "manifestChecksum": "sha256-of-sorted-concatenated-file-checksums"
}
```

## API Overview

### Acervo Static Methods

| Method | Description |
|--------|-------------|
| `version` | Current library version string |
| `sharedModelsDirectory` | Returns App Group container path + `SharedModels/` |
| `modelDirectory(for:)` | Returns local directory for a model ID |
| `slugify(_:)` | Converts `org/repo` to `org_repo` |
| `isModelAvailable(_:)` | True if model directory has `config.json` |
| `modelFileExists(_:fileName:)` | True if specific file exists in model directory |
| `listModels()` | List all valid models in shared directory |
| `modelInfo(_:)` | Get metadata for a model by ID |
| `findModels(matching:)` | Find models by name pattern (case-insensitive substring) |
| `findModels(fuzzyMatching:editDistance:)` | Find models by fuzzy edit distance |
| `closestModel(to:)` | Return single best fuzzy match, or nil |
| `modelFamilies()` | Group models by base name family |
| `download(_:files:force:progress:)` | Download specific files from CDN with manifest verification |
| `ensureAvailable(_:files:progress:)` | Download only if not already available |
| `deleteModel(_:)` | Delete a model from disk |
| `migrateFromLegacyPaths()` | Move models from old cache paths to shared directory |

### Component Registry Methods

| Method | Description |
|--------|-------------|
| `register(_:)` | Register a component descriptor |
| `downloadComponent(_:force:progress:)` | Download a registered component |
| `ensureComponentReady(_:progress:)` | Ensure component is downloaded and verified |
| `verifyComponent(_:)` | Verify component files against SHA-256 checksums |
| `registeredComponents()` | List all registered components |

### AcervoManager Methods

| Method | Description |
|--------|-------------|
| `download(_:files:force:progress:)` | Download with per-model serialization |
| `withModelAccess(_:perform:)` | Exclusive access to a model directory |
| `withComponentAccess(_:perform:)` | Scoped access to a registered component with integrity verification |
| `withLocalAccess(_:perform:)` | Scoped access to a caller-supplied local URL (e.g., LoRA adapter) |
| `clearCache()` | Clear model metadata cache |
| `preloadModels()` | Preload all model metadata into cache |

## Design Patterns

- **Static API + Actor**: `Acervo` for simple one-liners, `AcervoManager` for thread-safe operations
- **CDN-only downloads**: All downloads go through private R2 CDN
- **Manifest-driven integrity**: Per-file SHA-256 verification on every download
- **Streaming SHA-256**: 4MB chunked reads with incremental hashing during download
- **Concurrent file downloads**: TaskGroup-based parallel file fetches with byte-accurate cumulative progress tracking
- **Redirect rejection**: `SecureDownloadSession` blocks redirects to non-CDN domains
- **Per-model locking**: Same model serialized, different models concurrent
- **Atomic downloads**: Download to temp, verify, move to destination
- **config.json as validity marker**: Universal across all model types
- **Zero external dependencies**: Foundation + CryptoKit only (system frameworks)
- **Strict concurrency**: Swift 6 language mode, `@Sendable` closures
- **Local path access**: `withLocalAccess(_:perform:)` + `LocalHandle` for caller-supplied paths not registered in the component registry (e.g., LoRA adapters)

## Platform Requirements

**CRITICAL**: This library ONLY supports iOS 26.0+ and macOS 26.0+. NEVER add code for older platforms.

1. NEVER add `@available` attributes for versions below iOS 26.0 or macOS 26.0
2. NEVER add `#available` runtime checks for versions below iOS 26.0 or macOS 26.0
3. Package.swift must always specify iOS 26 and macOS 26

## Dependencies

SwiftAcervo has **zero external dependencies**. It uses only Foundation and CryptoKit (system frameworks). This is intentional and must not change.

## Build and Test

```bash
make build    # Build the SwiftAcervo scheme
make test     # Run all tests
make lint     # Format all Swift source files
make clean    # Clean build artifacts
make resolve  # Resolve Swift package dependencies
```

## CDN Upload Workflow

To add or update a model on the CDN:

```bash
# Full workflow: download from upstream source, generate manifest, upload to R2
./Tools/upload-model.sh "org/repo"

# Or generate manifest only for a local directory
./Tools/generate-manifest.sh "org/repo" /path/to/model/files
```

See `Tools/upload-model.sh` for environment variables (`RCLONE_REMOTE`, `R2_BUCKET`, `HF_TOKEN`).

## What This Library is NOT

- NOT a model loader (does not import MLX or any inference framework)
- Downloads exclusively from private CDN
- NOT a cache manager (does not evict models or manage disk quotas)
