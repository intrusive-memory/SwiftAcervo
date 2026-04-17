# AGENTS.md

This file provides comprehensive documentation for AI agents working with the SwiftAcervo codebase.

**Current Version**: 0.7.1 (April 2026)

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
- `Sources/acervo/AcervoCLI.swift` -- ArgumentParser root command
- `Sources/acervo/UploadCommand.swift` -- Upload staged files to R2 CDN
- `Sources/acervo/ShipCommand.swift` -- Download from HuggingFace + upload to CDN in one step
- `Sources/acervo/DownloadCommand.swift` -- Download model files from HuggingFace
- `Sources/acervo/VerifyCommand.swift` -- Run all 6 integrity checks against staged files
- `Sources/acervo/ManifestCommand.swift` -- Generate a CDN manifest for a staging directory
- `Sources/acervo/CDNUploader.swift` -- R2 upload via aws CLI with manifest verification
- `Sources/acervo/ManifestGenerator.swift` -- SHA-256 manifest generation with CHECK 2/3
- `Sources/acervo/HuggingFaceClient.swift` -- HuggingFace LFS download + CHECK 1 verification
- `Sources/acervo/ToolCheck.swift` -- Validates aws and hf are on PATH before commands run
- `Sources/acervo/Version.swift` -- acervo CLI version constant
- `Tools/generate-manifest.sh` -- Legacy shell script (superseded by `acervo manifest`)
- `Tools/upload-model.sh` -- Legacy shell script (superseded by `acervo ship`)
- `Tests/SwiftAcervoTests/` -- library unit tests
- `Tests/AcervoToolTests/` -- acervo CLI unit tests (argument builders, integrity, manifest)
- `Tests/AcervoToolIntegrationTests/` -- acervo CLI integration tests (skip without credentials)
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

## ModelDownloadManager

ModelDownloadManager provides standardized multi-model download orchestration for consuming libraries. It handles concurrent progress tracking, disk space validation, and error context.

### Usage Example: Consuming Library Startup

```swift
import SwiftAcervo

// In your library's initialization phase
func loadModels() async throws {
    // Validate disk space first
    let totalBytes = try await ModelDownloadManager.shared.validateCanDownload([
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    ])
    
    print("Will download \(totalBytes / (1024*1024)) MB total")
    
    // Download with progress reporting
    try await ModelDownloadManager.shared.ensureModelsAvailable([
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    ]) { progress in
        let percent = Int(progress.fraction * 100)
        let mb = progress.bytesDownloaded / (1024 * 1024)
        let total = progress.bytesTotal / (1024 * 1024)
        print("\r[\(progress.model)] \(progress.currentFileName): \(percent)% (\(mb)/\(total) MB)", terminator: "")
        fflush(stdout)
    }
    
    // All models now available
    print("\nModels ready!")
}
```

### Public API

| Method | Description |
|--------|-------------|
| `ensureModelsAvailable(_:progress:)` | Download all specified models if not already available |
| `validateCanDownload(_:)` | Check disk space and return total bytes needed |

### Return Types

```swift
public struct ModelDownloadProgress: Sendable {
    public let model: String           // e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit"
    public let fraction: Double        // 0.0 to 1.0 cumulative progress
    public let bytesDownloaded: Int64  // Total bytes downloaded across all models
    public let bytesTotal: Int64       // Total bytes to download across all models
    public let currentFileName: String // e.g., "model.safetensors"
}
```

### Error Handling

`ModelDownloadManager.ensureModelsAvailable()` throws `AcervoError`:

- `modelNotFound(modelId: String)` — Model doesn't exist on CDN
- `manifestChecksumMismatch(modelId: String)` — Manifest integrity check failed
- `downloadFailed(reason: String)` — Network error (transient)
- `checksumMismatch(fileName: String)` — File corrupted during download

Catch these at the consuming library level and convert to app-specific error types.

### Best Practices

1. **Always validate disk space first**: Call `validateCanDownload()` before user-initiated downloads
2. **Show aggregate progress**: Display cumulative MB downloaded, not per-model percentages
3. **Serialize model downloads**: Manager handles this (sequential, not parallel)
4. **Handle cancellation gracefully**: If user cancels, partial files remain (resume on next attempt)
5. **Distinguish model types in messages**: Include model name in progress callback output

### AcervoManager Methods

| Method | Description |
|--------|-------------|
| `download(_:files:force:progress:)` | Download with per-model serialization |
| `withModelAccess(_:perform:)` | Exclusive access to a model directory |
| `withComponentAccess(_:perform:)` | Scoped access to a registered component with integrity verification |
| `withLocalAccess(_:perform:)` | Scoped access to a caller-supplied local URL (e.g., LoRA adapter) |
| `clearCache()` | Clear model metadata cache |
| `preloadModels()` | Preload all model metadata into cache |

## CDN-First Validation Pattern for Consuming Libraries

Consuming libraries (e.g., SwiftBruja, SwiftProyecto) often have required model dependencies. Rather than fail silently or download unexpectedly, use this pattern to validate CDN availability upfront, then optionally download with user feedback.

### Pattern: Check Local → Validate CDN → Download if Needed

**Goal**: Ensure a required model exists on the CDN and has all expected files, without side effects unless validation fails.

**Flow**:
1. Check if model is already available locally (`isModelAvailable`)
2. If not, fetch metadata from CDN (`modelInfo`) to validate manifest — **no download yet**
3. Consuming library validates that all required files exist in the manifest
4. If validation passes, optionally download with progress feedback (`ensureAvailable`)

**Consuming Library Responsibilities**:
- Define which files it requires (e.g., `["config.json", "model.safetensors"]`)
- Validate that `AcervoModel.files` contains all required files
- Decide whether to proceed with download or fail gracefully
- Provide user feedback during download (progress bar, file count, estimated size)

### Implementation Example

```swift
import SwiftAcervo

// In SwiftBruja or SwiftProyecto startup
func validateAndEnsureModel(modelId: String, requiredFiles: [String]) async throws {
    // Step 1: Check local availability (fast path)
    if Acervo.isModelAvailable(modelId) {
        return  // Model already available, no validation needed
    }
    
    // Step 2: Validate on CDN without downloading (read-only)
    let model = try Acervo.modelInfo(modelId)
    
    // Step 3: Verify all required files exist in manifest
    let manifestFiles = Set(model.files.map { $0.path })
    let requiredSet = Set(requiredFiles)
    
    guard requiredSet.isSubset(of: manifestFiles) else {
        let missing = Array(requiredSet.subtracting(manifestFiles))
        throw AcervoError.modelNotFound(modelId)  // Or app-specific error
    }
    
    // Step 4: Download if validation passed
    // (Show progress UI to user)
    try await Acervo.ensureAvailable(modelId, files: requiredFiles) { progress in
        let percent = Int(progress.fractionCompleted * 100)
        let mb = progress.completedUnitCount / (1024 * 1024)
        print("Downloading: \(percent)% (\(mb) MB)")
    }
}
```

### Return Value: AcervoModel

When `modelInfo(_:)` is called, it returns an `AcervoModel` struct containing:

```swift
struct AcervoModel {
    let id: String                  // e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit"
    let slug: String                // e.g., "mlx-community_Qwen2.5-7B-Instruct-4bit"
    let files: [CDNFile]            // Array of available files from manifest
    let manifestChecksum: String    // Integrity marker for the manifest itself
    let updatedAt: Date             // When model was last updated on CDN
}

struct CDNFile {
    let path: String                // e.g., "config.json", "model.safetensors"
    let sizeBytes: Int64            // File size for progress estimation
    let sha256: String              // SHA-256 checksum for verification
}
```

This allows consuming libraries to:
- Validate all required files are present before downloading
- Estimate total download size upfront
- Provide accurate progress feedback (total MB, file count)

### Error Handling

**Validation Errors** (fail-fast, no side effects):
- Model not found on CDN: `AcervoError.modelNotFound`
- Manifest corrupted or tampered: `AcervoError.manifestChecksumMismatch`
- Missing required files: Validate against `AcervoModel.files` and throw app-specific error

**Download Errors** (after validation passes):
- Network failure: `AcervoError.downloadFailed`
- Checksum mismatch: `AcervoError.checksumMismatch`
- Disk space exhausted: Handle as OS-level error (`URLError.fileOutOfSpace`)

### Best Practices for Consuming Libraries

Use **ModelDownloadManager** for standardized multi-model download orchestration:

```swift
try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
    // Handle progress callback
}
```

For advanced patterns (custom progress UI, library-specific error mapping), see [ModelDownloadManager](#modeldownloadmanager) section above.

Single-model validation can still use `Acervo.modelInfo()` directly for fast CDN checks.

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
make build              # Build the SwiftAcervo library scheme
make test               # Run all tests (SwiftAcervo-Package scheme)
make lint               # Format all Swift source files
make clean              # Clean build artifacts
make resolve            # Resolve Swift package dependencies
make build-acervo       # Build the acervo CLI binary
make install-acervo     # Build acervo and install to bin/ (Debug)
make release-acervo     # Build acervo and install to bin/ (Release)
make test-acervo-unit   # Run acervo unit tests (no credentials needed)
```

## CDN Upload Workflow

To add or update a model on the CDN, use the `acervo` CLI tool:

```bash
# Full pipeline: download from HuggingFace, generate manifest, upload to R2
acervo ship --model-id "org/repo"

# Or run steps individually:
acervo download --model-id "org/repo"        # download from HuggingFace
acervo manifest --model-id "org/repo"        # generate manifest.json
acervo verify --model-id "org/repo"          # run all 6 integrity checks
acervo upload --model-id "org/repo"          # upload to R2 CDN

# Legacy shell scripts (still functional but superseded by acervo):
./Tools/upload-model.sh "org/repo"
./Tools/generate-manifest.sh "org/repo" /path/to/model/files
```

Required environment variables: `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `HF_TOKEN`.
Optional: `R2_BUCKET`, `R2_ENDPOINT`, `R2_PUBLIC_URL`, `STAGING_DIR`.

Build the CLI: `make build-acervo` or `make install-acervo` (installs to `bin/`).

## What This Library is NOT

- NOT a model loader (does not import MLX or any inference framework)
- Downloads exclusively from private CDN
- NOT a cache manager (does not evict models or manage disk quotas)
