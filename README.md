# SwiftAcervo

Shared AI model discovery and management for HuggingFace models on Apple platforms.

SwiftAcervo ("Swift Collection/Repository") provides a single canonical location for HuggingFace AI models so that models downloaded by one tool are immediately visible to all others. It handles path resolution, availability checks, discovery, downloading, fuzzy search, and migration -- with zero external dependencies.

## Why SwiftAcervo?

### The Problem

AI applications on macOS and iOS each tend to manage their own model storage. An LLM chat app downloads Qwen to one directory; a text-to-speech app downloads the same model to another. The result:

- **Wasted disk space.** Multi-gigabyte models duplicated across apps.
- **Invisible downloads.** A model downloaded by one tool cannot be found by another.
- **Fragile paths.** Every project hardcodes its own cache directory, making refactoring painful.
- **No standard convention.** Adding a new model type means inventing yet another subdirectory.

### The Solution

**One path. No subdirectories. Every project uses SwiftAcervo.**

All models live under a single canonical directory:

```
~/Library/SharedModels/{org}_{repo}/
```

For example:

```
~/Library/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
│   ├── config.json
│   ├── tokenizer.json
│   └── model.safetensors
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
│   ├── config.json
│   └── speech_tokenizer/
└── mlx-community_snac_24khz/
    └── config.json
```

LLM, TTS, audio, and vision models are all peers in the same flat directory. The presence of `config.json` marks a model as valid. SwiftAcervo finds and downloads models -- it does **not** load them. Loading is the consumer's job.

## Installation

### Swift Package Manager

Add SwiftAcervo to your `Package.swift`:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: ["SwiftAcervo"]
        )
    ]
)
```

Or add it through Xcode: **File > Add Package Dependencies** and enter the repository URL.

### Requirements

| Requirement | Minimum Version |
|------------|----------------|
| macOS      | 26.0+          |
| iOS        | 26.0+          |
| Swift      | 6.2+           |
| Xcode      | 26+            |

SwiftAcervo has **zero external dependencies**. It uses only Foundation framework APIs -- `URLSession` for downloads, `FileManager` for discovery. No HuggingFace Hub library, no MLX, no model-specific imports.

## Quick Start

```swift
import SwiftAcervo
```

### Check if a model is available

```swift
if Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit") {
    let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
    // Load model from dir using your framework (MLX, etc.)
}
```

### Download a model

```swift
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
) { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}
```

`ensureAvailable` skips the download if the model is already present. Use `download` with `force: true` to re-download regardless.

### List all models

```swift
let models = try Acervo.listModels()
for model in models {
    print("\(model.id): \(model.formattedSize)")
}
```

### Fuzzy search

Model names from HuggingFace are long and easy to get slightly wrong. SwiftAcervo provides multiple search strategies:

```swift
// Exact substring match (case-insensitive)
let qwenModels = try Acervo.findModels(matching: "Qwen")

// Fuzzy match using Levenshtein edit distance (tolerates typos)
let fuzzyMatches = try Acervo.findModels(fuzzyMatching: "Qwen2.5-7B-Instruct")

// Single closest match -- useful for "did you mean...?" suggestions
if let closest = try Acervo.closestModel(to: "Qwen2.5-7B-Instrct") {
    print("Did you mean: \(closest.id)?")
}
```

### Delete a model

```swift
try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")
```

### Thread-safe operations

For concurrent environments, use `AcervoManager`. It serializes downloads of the same model while allowing different models to download in parallel:

```swift
// Download with per-model locking
try await AcervoManager.shared.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "model.safetensors"]
)

// Exclusive access to a model directory
let configURL = try await AcervoManager.shared.withModelAccess(
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
) { dir in
    dir.appendingPathComponent("config.json")
}
```

## API Reference

SwiftAcervo provides two main entry points: the `Acervo` static API for simple operations, and the `AcervoManager` actor for thread-safe concurrent access. For complete documentation, see [AGENTS.md](AGENTS.md).

### Acervo (Static API)

`Acervo` is a caseless enum used as a namespace. All functionality is provided through static methods.

#### Path Resolution

| Method | Description |
|--------|-------------|
| `sharedModelsDirectory` | Returns `~/Library/SharedModels/` |
| `modelDirectory(for:)` | Returns local directory URL for a HuggingFace model ID |
| `slugify(_:)` | Converts `org/repo` to `org_repo` |

#### Availability

| Method | Description |
|--------|-------------|
| `isModelAvailable(_:)` | `true` if model directory contains `config.json` |
| `modelFileExists(_:fileName:)` | `true` if a specific file exists in the model directory |

#### Discovery

| Method | Description |
|--------|-------------|
| `listModels()` | Returns all valid models sorted alphabetically |
| `modelInfo(_:)` | Returns metadata for a single model by ID |
| `findModels(matching:)` | Case-insensitive substring search across model IDs |
| `findModels(fuzzyMatching:editDistance:)` | Levenshtein edit distance search (default threshold: 5) |
| `closestModel(to:editDistance:)` | Returns the single best fuzzy match, or `nil` |
| `modelFamilies()` | Groups models by base name family |

#### Download

| Method | Description |
|--------|-------------|
| `download(_:files:token:force:progress:)` | Downloads specified files from HuggingFace |
| `ensureAvailable(_:files:token:progress:)` | Downloads only if model is not already available |
| `deleteModel(_:)` | Removes a model directory from disk |

#### Migration

| Method | Description |
|--------|-------------|
| `migrateFromLegacyPaths()` | Moves models from legacy cache paths to `~/Library/SharedModels/` |

### AcervoManager (Actor)

`AcervoManager` is a singleton actor that wraps the `Acervo` static API with per-model locking. Two concurrent downloads of the same model are serialized; different models proceed in parallel.

| Method | Description |
|--------|-------------|
| `download(_:files:token:force:progress:)` | Download with per-model serialization |
| `withModelAccess(_:perform:)` | Exclusive access to a model directory while holding the lock |
| `clearCache()` | Clear the URL cache |
| `preloadModels()` | Preload all model metadata into the cache |
| `getDownloadCount(for:)` | Number of times `download()` was called for a model |
| `getAccessCount(for:)` | Number of times `withModelAccess()` was called for a model |
| `printStatisticsReport()` | Print a formatted usage statistics report |
| `resetStatistics()` | Reset all counters |

### Supporting Types

**`AcervoModel`** -- Model metadata (`Identifiable`, `Codable`, `Sendable`):
- `id: String` -- HuggingFace model identifier (e.g., `"mlx-community/Qwen2.5-7B-Instruct-4bit"`)
- `path: URL` -- Local filesystem directory
- `sizeBytes: Int64` -- Total size of all files
- `downloadDate: Date` -- Directory creation date
- `formattedSize: String` -- Human-readable size (e.g., `"4.4 GB"`)
- `slug: String` -- Directory name form (e.g., `"mlx-community_Qwen2.5-7B-Instruct-4bit"`)
- `baseName: String` -- Model name with quantization/size/variant suffixes stripped
- `familyName: String` -- Organization + base name for grouping variants

**`AcervoDownloadProgress`** -- Download progress information (`Sendable`):
- `fileName: String` -- Current file being downloaded
- `bytesDownloaded: Int64` -- Bytes downloaded for the current file
- `totalBytes: Int64?` -- Expected total bytes, or `nil` if unknown
- `fileIndex: Int` -- Zero-based index in the file list
- `totalFiles: Int` -- Total files being downloaded
- `overallProgress: Double` -- Combined progress from 0.0 to 1.0

**`AcervoError`** -- Error types (`LocalizedError`, `Sendable`):
- `directoryCreationFailed(String)`
- `modelNotFound(String)`
- `downloadFailed(fileName:statusCode:)`
- `networkError(Error)`
- `modelAlreadyExists(String)`
- `migrationFailed(source:reason:)`
- `invalidModelId(String)`

## Design Principles

- **Stability first.** The API surface is intentionally small. Once set, it should rarely change.
- **Zero dependencies.** Foundation only. No HuggingFace Hub library, no MLX, no model-specific logic.
- **Not a model loader.** SwiftAcervo finds and downloads models. Loading is the consumer's job.
- **Caller-specified file lists.** Different model types need different files. The caller provides the list.
- **config.json as validity marker.** Universal across all HuggingFace model types.
- **Swift 6 strict concurrency.** All closures are `@Sendable`. `AcervoManager` is an actor.

## Consumer Integration

SwiftAcervo is the model management layer for the [intrusive-memory](https://github.com/intrusive-memory) ecosystem. Each consumer project depends on SwiftAcervo for model discovery and downloading, then loads models using its own framework. Because every project shares `~/Library/SharedModels/`, a model downloaded by any one tool is immediately available to all others.

### SwiftBruja (MLX Inference)

[SwiftBruja](https://github.com/intrusive-memory/SwiftBruja) provides MLX-based LLM inference. It uses SwiftAcervo to locate quantized language models:

```swift
import SwiftAcervo
import SwiftBruja

let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"

// Ensure the model is downloaded
try await Acervo.ensureAvailable(modelId, files: [
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "model.safetensors"
])

// Get the local directory and load with MLX
let modelDir = try Acervo.modelDirectory(for: modelId)
let engine = try BrujaEngine(modelPath: modelDir)
let response = try await engine.generate(prompt: "Explain quantum computing")
```

### mlx-audio-swift (Text-to-Speech)

[mlx-audio-swift](https://github.com/intrusive-memory/mlx-audio-swift) handles TTS model inference. It uses SwiftAcervo to download and locate audio models:

```swift
import SwiftAcervo

let ttsModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
let codecModelId = "mlx-community/snac_24khz"

// Ensure both TTS and codec models are available
try await Acervo.ensureAvailable(ttsModelId, files: [
    "config.json",
    "model.safetensors",
    "speech_tokenizer/config.json"
])
try await Acervo.ensureAvailable(codecModelId, files: [
    "config.json",
    "model.safetensors"
])

// Both model directories are now ready for mlx-audio-swift to load
let ttsDir = try Acervo.modelDirectory(for: ttsModelId)
let codecDir = try Acervo.modelDirectory(for: codecModelId)
```

### SwiftVoxAlta (Voice Processing)

[SwiftVoxAlta](https://github.com/intrusive-memory/SwiftVoxAlta) manages voice processing pipelines. It uses `AcervoManager` for thread-safe access when multiple voice operations run concurrently:

```swift
import SwiftAcervo

let voiceModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"

// Thread-safe download with progress tracking
try await AcervoManager.shared.download(voiceModelId, files: [
    "config.json",
    "model.safetensors",
    "speech_tokenizer/config.json"
]) { progress in
    print("Voice model: \(Int(progress.overallProgress * 100))%")
}

// Exclusive access while reading model configuration
let voiceConfig = try await AcervoManager.shared.withModelAccess(voiceModelId) { dir in
    let configURL = dir.appendingPathComponent("config.json")
    return try Data(contentsOf: configURL)
}
```

### Produciesta (Production App)

[Produciesta](https://github.com/intrusive-memory/Produciesta) is the user-facing production app that ties the ecosystem together. It uses SwiftAcervo at startup to migrate legacy paths and verify model availability:

```swift
import SwiftAcervo

// At app launch: migrate any models from the old cache structure
let migrated = try Acervo.migrateFromLegacyPaths()
if !migrated.isEmpty {
    print("Migrated \(migrated.count) model(s) to SharedModels")
}

// Preload the cache so model lookups are fast throughout the session
try await AcervoManager.shared.preloadModels()

// Check which models the user has available
let available = try Acervo.listModels()
let families = try Acervo.modelFamilies()
for (family, variants) in families {
    print("\(family): \(variants.count) variant(s)")
}
```

## Migration from Legacy Paths

Before SwiftAcervo, intrusive-memory projects stored models in a type-based directory structure under the system caches:

```
~/Library/Caches/intrusive-memory/Models/
├── LLM/
│   └── mlx-community_Qwen2.5-7B-Instruct-4bit/
├── TTS/
│   └── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
├── Audio/
│   └── mlx-community_snac_24khz/
└── VLM/
    └── (vision-language models)
```

SwiftAcervo consolidates all models into a single flat directory:

```
~/Library/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
└── mlx-community_snac_24khz/
```

### Running the Migration

Call `migrateFromLegacyPaths()` once at application startup. It scans all four legacy subdirectories (`LLM`, `TTS`, `Audio`, `VLM`) for valid model directories (those containing `config.json`) and moves them to `~/Library/SharedModels/`:

```swift
import SwiftAcervo

let migrated = try Acervo.migrateFromLegacyPaths()
print("Migrated \(migrated.count) model(s)")

for model in migrated {
    print("  \(model.id) -> \(model.path.path)")
}
```

### Migration Behavior

- **Safe operation.** Models are moved (not copied). If a model already exists at the destination, it is skipped.
- **Old directories are preserved.** The legacy parent directories (`LLM/`, `TTS/`, etc.) are NOT deleted. Consumers are responsible for cleaning up their own legacy references.
- **Idempotent.** Running migration multiple times is harmless. Already-migrated models are skipped because their destination directories already exist.
- **Partial failure.** If one model fails to move, an `AcervoError.migrationFailed` is thrown. Models that were successfully migrated before the error remain in their new location.
- **No network required.** Migration is a local filesystem operation only.

### When to Migrate

Run migration once when upgrading from an older version of any intrusive-memory project. A good pattern is to check at app launch:

```swift
// Only attempt migration if the legacy directory exists
let legacyPath = URL(filePath: NSHomeDirectory())
    .appendingPathComponent("Library/Caches/intrusive-memory/Models")
if FileManager.default.fileExists(atPath: legacyPath.path) {
    let migrated = try Acervo.migrateFromLegacyPaths()
    if !migrated.isEmpty {
        print("Migrated \(migrated.count) model(s) to ~/Library/SharedModels/")
    }
}
```

## Thread Safety

SwiftAcervo provides two levels of concurrency support:

- **`Acervo` (static API):** Stateless methods that are safe to call from any thread. Each call is independent and relies on Foundation's thread-safe `FileManager` and `URLSession`.
- **`AcervoManager` (actor):** A singleton actor that adds per-model locking on top of the static API. Use this when multiple tasks might download or access the same model concurrently.

### Per-Model Locking

`AcervoManager` maintains a lock per model ID. Two concurrent downloads of the **same** model are serialized -- the second caller waits until the first completes. Downloads of **different** models proceed in parallel without blocking each other.

```swift
// These two downloads run concurrently (different models)
async let llm: Void = AcervoManager.shared.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "model.safetensors"]
)
async let tts: Void = AcervoManager.shared.download(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    files: ["config.json", "model.safetensors"]
)

// Wait for both to finish
try await llm
try await tts
```

### Exclusive Model Access

Use `withModelAccess(_:perform:)` when you need to read or inspect model files while holding the lock. This prevents another task from downloading (and potentially modifying) the same model directory while you are reading from it:

```swift
let configData = try await AcervoManager.shared.withModelAccess(
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
) { modelDir in
    let configURL = modelDir.appendingPathComponent("config.json")
    return try Data(contentsOf: configURL)
}
```

The lock is automatically released when the closure returns or throws, via `defer`. All closures must be `@Sendable` to satisfy Swift 6 strict concurrency.

### Usage Statistics

`AcervoManager` tracks download and access counts per model, which can be useful for diagnostics:

```swift
let downloads = await AcervoManager.shared.getDownloadCount(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
let accesses = await AcervoManager.shared.getAccessCount(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")

// Print a formatted report of top-used models
await AcervoManager.shared.printStatisticsReport()
```

## Testing

### Unit Tests

Unit tests run entirely offline with no network access required. They use temporary directories to avoid touching `~/Library/SharedModels/`:

```bash
xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'
```

### Integration Tests

Integration tests that hit the HuggingFace network are gated behind the `INTEGRATION_TESTS` compile flag. These are excluded from CI by default to keep the test suite fast and deterministic:

```bash
xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' \
    OTHER_SWIFT_FLAGS='-D INTEGRATION_TESTS'
```

### CI/CD

SwiftAcervo uses GitHub Actions for continuous integration. Tests run on every pull request targeting `main` or `development`:

[![Tests](https://github.com/intrusive-memory/SwiftAcervo/actions/workflows/tests.yml/badge.svg)](https://github.com/intrusive-memory/SwiftAcervo/actions/workflows/tests.yml)

| Job | Runner | Destination |
|-----|--------|-------------|
| Test on macOS | `macos-26` | `platform=macOS` |
| Test on iOS Simulator | `macos-26` | `platform=iOS Simulator,name=iPhone 17,OS=26.1` |

See [`.github/workflows/tests.yml`](.github/workflows/tests.yml) for the full workflow configuration.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing guidelines, commit conventions, and pull request process.

## License

MIT License. Copyright (c) 2026 Tom Stovall. See [LICENSE](LICENSE) for details.
