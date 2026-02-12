# AGENTS.md

This file provides comprehensive documentation for AI agents working with the SwiftAcervo codebase.

**Current Version**: 0.1.0 (February 2026)

---

## Project Overview

Consumers need HuggingFace models available locally, but model names vary and multiple tools shouldn't each maintain their own copy. SwiftAcervo solves this by providing **model discovery with fuzzy name matching** and **download from HuggingFace** into a single shared directory (`~/Library/SharedModels/`). A model downloaded by one tool is immediately available to all others -- no duplication, no hardcoded paths.

Modeled after SwiftFijos (test fixture discovery), SwiftAcervo is designed for **stability** -- once the discovery and download logic is set, it should rarely change.

## Shared Models Directory

**CRITICAL**: All intrusive-memory projects MUST use `~/Library/SharedModels/` for HuggingFace model storage.

```
~/Library/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
├── mlx-community_snac_24khz/
└── ...
```

**Rules**:
- Base directory: `~/Library/SharedModels/`
- Naming: HuggingFace ID with `/` replaced by `_`
- No type subdirectories (LLM, TTS, Audio are all peers)
- Validity: `config.json` must be present in model directory
- NEVER hardcode a different model path in any project

## Project Structure

- `Sources/SwiftAcervo/Acervo.swift` -- Static discovery + download API
- `Sources/SwiftAcervo/AcervoManager.swift` -- Actor-based thread-safe manager
- `Sources/SwiftAcervo/AcervoModel.swift` -- Model metadata struct
- `Sources/SwiftAcervo/AcervoError.swift` -- Error types
- `Sources/SwiftAcervo/AcervoDownloader.swift` -- HuggingFace download logic
- `Sources/SwiftAcervo/AcervoDownloadProgress.swift` -- Download progress tracking
- `Sources/SwiftAcervo/AcervoMigration.swift` -- Legacy path migration
- `Sources/SwiftAcervo/LevenshteinDistance.swift` -- Edit distance for fuzzy search
- `Tests/SwiftAcervoTests/` -- Test suite
- `Package.swift` -- Swift 6.2+, iOS 26.0+, macOS 26.0+

## Key Components

| File | Purpose |
|------|---------|
| `Acervo.swift` | Static methods: `sharedModelsDirectory`, `modelDirectory(for:)`, `slugify(_:)`, `isModelAvailable(_:)`, `modelFileExists(_:fileName:)`, `listModels()`, `modelInfo(_:)`, `findModels(matching:)`, `findModels(fuzzyMatching:editDistance:)`, `closestModel(to:)`, `modelFamilies()`, `download(_:files:token:force:progress:)`, `ensureAvailable(_:files:token:progress:)`, `deleteModel(_:)`, `migrateFromLegacyPaths()` |
| `AcervoManager.swift` | Actor with per-model download locks, metadata cache, exclusive model access via `withModelAccess(_:perform:)`, download/access statistics |
| `AcervoModel.swift` | Identifiable, Codable model metadata: `id`, `path`, `sizeBytes`, `downloadDate`, `formattedSize`, `slug`, `baseName`, `familyName` |
| `AcervoError.swift` | Error types: `directoryCreationFailed`, `modelNotFound`, `downloadFailed`, `networkError`, `modelAlreadyExists`, `migrationFailed`, `invalidModelId` |
| `AcervoDownloader.swift` | URLSession-based HuggingFace file downloads with progress reporting and optional auth token support |
| `AcervoDownloadProgress.swift` | Download progress struct: `fileName`, `bytesDownloaded`, `totalBytes`, `fileIndex`, `totalFiles`, `overallProgress` |
| `AcervoMigration.swift` | Legacy path constants for migrating from `~/Library/Caches/intrusive-memory/Models/` subdirectories |
| `LevenshteinDistance.swift` | Levenshtein edit distance algorithm for fuzzy model name matching |

## API Overview

### Acervo Static Methods

| Method | Description |
|--------|-------------|
| `sharedModelsDirectory` | Returns `~/Library/SharedModels/` |
| `modelDirectory(for:)` | Returns local directory for a HuggingFace model ID |
| `slugify(_:)` | Converts `org/repo` to `org_repo` |
| `isModelAvailable(_:)` | True if model directory has `config.json` |
| `modelFileExists(_:fileName:)` | True if specific file exists in model directory |
| `listModels()` | List all valid models in shared directory |
| `modelInfo(_:)` | Get metadata for a model by HuggingFace ID |
| `findModels(matching:)` | Find models by name pattern (case-insensitive substring) |
| `findModels(fuzzyMatching:editDistance:)` | Find models by fuzzy edit distance (tolerates typos) |
| `closestModel(to:)` | Return single best fuzzy match, or nil |
| `modelFamilies()` | Group models by base name family |
| `download(_:files:token:force:progress:)` | Download specific files from HuggingFace |
| `ensureAvailable(_:files:token:progress:)` | Download only if not already available |
| `deleteModel(_:)` | Delete a model from disk |
| `migrateFromLegacyPaths()` | Move models from old cache paths to shared directory |

### AcervoManager Methods

| Method | Description |
|--------|-------------|
| `download(_:files:token:force:progress:)` | Download with per-model serialization |
| `withModelAccess(_:perform:)` | Exclusive access to a model directory |
| `clearCache()` | Clear model metadata cache |
| `preloadModels()` | Preload all model metadata into cache |
| `getDownloadCount(for:)` | Get download count for a model |
| `getAccessCount(for:)` | Get access count for a model |
| `printStatisticsReport()` | Print formatted statistics |
| `resetStatistics()` | Reset all statistics |

## Usage Patterns

### Basic Model Discovery

```swift
import SwiftAcervo

// Check if a model is ready to use
if Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit") {
    let dir = Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
    // Load model from dir using your framework (MLX, etc.)
}

// List everything downloaded
let models = try Acervo.listModels()
for model in models {
    print("\(model.id): \(model.formattedSize)")
}
```

### Download a Model

```swift
import SwiftAcervo

try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
) { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}
```

### Thread-Safe Access

```swift
import SwiftAcervo

let modelDir = try await AcervoManager.shared.withModelAccess(
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
) { url in
    // Safe to read model files here
    return url
}
```

## Use Cases

### 1. Find a model locally (fuzzy search)

Model names from HuggingFace are long and easy to mistype. Fuzzy matching tolerates name variations:

```swift
// User types an approximate name -- fuzzy search finds the real model
if let match = try Acervo.closestModel(to: "Qwen2.5-7B-Instrct") {
    let dir = match.path
    // Load model from dir
}
```

### 2. Download if missing

`ensureAvailable` checks local storage first, only downloading when the model isn't present:

```swift
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json", "model.safetensors"]
)
// Model is now guaranteed to be at ~/Library/SharedModels/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

### 3. Shared across tools

All intrusive-memory projects point at the same `~/Library/SharedModels/` directory. A model downloaded by SwiftBruja (LLM inference) is immediately visible to mlx-audio-swift (TTS) or any other consumer -- no re-download, no path coordination.

## Design Patterns

- **Static API + Actor**: `Acervo` for simple one-liners, `AcervoManager` for thread-safe operations
- **Per-model locking**: Same model serialized, different models concurrent
- **Caller-specified file lists**: No hardcoded model file requirements
- **Atomic downloads**: Download to temp, move to destination
- **config.json as validity marker**: Universal across all model types
- **Zero external dependencies**: Foundation only
- **Strict concurrency**: Swift 6 language mode, `@Sendable` closures

## Platform Requirements

**CRITICAL**: This library ONLY supports iOS 26.0+ and macOS 26.0+. NEVER add code for older platforms.

1. NEVER add `@available` attributes for versions below iOS 26.0 or macOS 26.0
2. NEVER add `#available` runtime checks for versions below iOS 26.0 or macOS 26.0
3. Package.swift must always specify iOS 26 and macOS 26

## Dependencies

SwiftAcervo has **zero external dependencies**. It only uses Foundation framework APIs. This is intentional and must not change.

## Build and Test

```bash
xcodebuild -scheme SwiftAcervo -destination 'platform=macOS' build
xcodebuild -scheme SwiftAcervo -destination 'platform=macOS' test
```

## Thread Safety

`AcervoManager` is an `actor` that ensures thread-safe model operations:

- **Per-model download locks**: Only one download per model at a time
- **Automatic waiting**: If a model is locked, callers wait 50ms between checks
- **Lock release**: Locks released via `defer` even on error
- **URL caching**: Thread-safe dictionary for cached model paths
- **Statistics tracking**: Thread-safe download and access counters

## What This Library is NOT

- NOT a model loader (does not import MLX or any inference framework)
- NOT a model registry (does not maintain a database of known models)
- NOT a HuggingFace client (downloads via direct URLs, not Hub API)
- NOT a cache manager (does not evict models or manage disk quotas)
