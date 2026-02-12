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
        .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", from: "1.0.0")
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

## License

See [LICENSE](LICENSE) for details.
