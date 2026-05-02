# SwiftAcervo

Shared AI model discovery and management for Apple platforms.

SwiftAcervo ("Swift Collection/Repository") provides a single canonical location for AI models so that models downloaded by one tool are immediately visible to all others. It handles path resolution, availability checks, discovery, downloading, fuzzy search, and migration -- with zero external dependencies.

## Why SwiftAcervo?

### The Problem

AI applications on macOS and iOS each tend to manage their own model storage. An LLM chat app downloads Qwen to one directory; a text-to-speech app downloads the same model to another. The result:

- **Wasted disk space.** Multi-gigabyte models duplicated across apps.
- **Invisible downloads.** A model downloaded by one tool cannot be found by another.
- **Fragile paths.** Every project hardcodes its own cache directory, making refactoring painful.
- **No standard convention.** Adding a new model type means inventing yet another subdirectory.

### The Solution

**One path. No subdirectories. Every project uses SwiftAcervo.**

All models live under a single canonical directory inside the App Group container that the consumer configures:

```
~/Library/Group Containers/<app-group-id>/SharedModels/{org}_{repo}/
```

For example, with `ACERVO_APP_GROUP_ID=group.intrusive-memory.models`:

```
~/Library/Group Containers/group.intrusive-memory.models/SharedModels/
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

The same directory is used by signed UI apps (resolved via the `com.apple.security.application-groups` entitlement) and unsigned CLI tools (resolved via the `ACERVO_APP_GROUP_ID` environment variable). Both write to the same path, so a model downloaded by either is immediately visible to the other. See [SHARED_MODELS_DIRECTORY.md](SHARED_MODELS_DIRECTORY.md) for full path-resolution rules.

LLM, TTS, audio, and vision models are all peers in the same flat directory. The presence of `config.json` marks a model as valid. SwiftAcervo finds and downloads models -- it does **not** load them. Loading is the consumer's job.

## Getting Started

**For app and library developers integrating SwiftAcervo**, start here:

- **[USAGE.md](USAGE.md)** — Complete integration guide
  - The manifest-first principle (you don't name files; the manifest does)
  - Three ways to avoid naming files (batch, single-model, registered component)
  - How to add SwiftAcervo to your project
  - Common patterns, error handling, FAQ
  - Real-world examples (SwiftBruja, mlx-audio-swift, SwiftVoxAlta, Produciesta)

**For complete API reference**, see [API_REFERENCE.md](API_REFERENCE.md).

**For all documentation**, see the [documentation map in AGENTS.md](AGENTS.md#documentation-map).

## Installation

### Homebrew (acervo CLI)

```bash
brew tap intrusive-memory/tap
brew install acervo
```

Requires Apple Silicon (M1+) and macOS 26+. The `aws` and `hf` CLIs are required at runtime for upload and download operations:

```bash
brew install awscli huggingface-hub
```

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
        .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", from: "0.9.0")
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

SwiftAcervo has **zero external dependencies**. It uses only Foundation and CryptoKit (system frameworks) -- `URLSession` for downloads, `FileManager` for discovery, `SHA256` for integrity verification. No external model hub libraries, no MLX, no model-specific imports.

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

### Download a model (manifest-first)

Consumers don't name files. The CDN manifest is the authoritative source for what's in a model; pass `files: []` to download everything the manifest lists.

```swift
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []     // empty = "download everything in the manifest"
) { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}
```

For multi-model startup, prefer the batch form:

```swift
try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
]) { progress in
    print("[\(progress.model)] \(Int(progress.fraction * 100))%")
}
```

`ensureAvailable` skips the download if the model is already present. Use `Acervo.download(_:files:force:progress:)` with `force: true` to re-download regardless. Pinning a specific file subset (e.g., `files: ["config.json", "model.safetensors"]`) is supported as an escape hatch; see [USAGE.md](USAGE.md#pinning-a-specific-subset-escape-hatch) for when to reach for it.

### CLI progress bars

Every download entry point exposes a `@Sendable` progress callback that a command-line tool can use to render a live progress bar. The callback receives `AcervoDownloadProgress` (for single-model downloads via `Acervo` / `AcervoManager`) or `ModelDownloadProgress` (for batches via `ModelDownloadManager`). Both carry a `0.0...1.0` fraction, the current file/model, and cumulative byte counts — everything a terminal bar needs.

The library itself pulls in no terminal dependencies, so consuming CLIs stay in control of how the bar looks. A minimal, zero-dependency renderer:

```swift
import SwiftAcervo

func renderBar(_ fraction: Double, label: String) {
    let width = 30
    let filled = Int((fraction * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled)
               + String(repeating: "·", count: width - filled)
    let pct = Int((fraction * 100).rounded())
    // \r returns to the start of the line so the bar updates in place.
    print("\r\(label) [\(bar)] \(pct)%", terminator: "")
    fflush(stdout)
}

// Single-model download — manifest drives the file list.
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []
) { progress in
    renderBar(progress.overallProgress, label: progress.fileName)
}
print()  // newline when finished

// Multi-model batch
try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
]) { progress in
    renderBar(progress.fraction, label: progress.model)
}
print()
```

A few conventions worth following so your CLI behaves well in pipes, CI logs, and `--quiet` invocations:

- **Check `isatty(fileno(stdout))` before drawing a bar.** When stdout isn't a TTY (piped, redirected, CI log capture), skip the bar and emit plain line-based progress — or nothing at all. ANSI control sequences in log files are noise.
- **Offer a `--quiet` / `-q` flag** that suppresses the bar. Errors should still go to stderr.
- **Pass `nil` for the progress callback** when you genuinely want silence; SwiftAcervo does no extra work in that case.
- **The callback fires on a background task**, so don't capture UI or non-`Sendable` state inside it. For terminal output `print` is fine.

The `acervo` CLI in this repo uses [Progress.swift](https://github.com/jkandzi/Progress.swift) for a richer renderer (elapsed time, ETA, throughput). That's a reasonable drop-in if you don't want to hand-roll one — see `Sources/acervo/ProgressReporter.swift` for the wiring, including the TTY guard and the `--quiet` `@OptionGroup`. SwiftAcervo itself does not depend on Progress.swift; the library stays Foundation + CryptoKit only.

### List all models

```swift
let models = try Acervo.listModels()
for model in models {
    print("\(model.id): \(model.formattedSize)")
}
```

### Fuzzy search

Model names are long and easy to get slightly wrong. SwiftAcervo provides multiple search strategies:

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
// Download with per-model locking. `files: []` = whatever the manifest says.
try await AcervoManager.shared.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []
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
| `sharedModelsDirectory` | Returns `<App Group Container>/SharedModels/` (group ID resolved via `ACERVO_APP_GROUP_ID` env var or `com.apple.security.application-groups` entitlement). Traps with `fatalError` if neither source supplies a value. |
| `modelDirectory(for:)` | Returns local directory URL for a model ID |
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
| `download(_:files:force:progress:)` | Downloads specified files from CDN with manifest verification |
| `ensureAvailable(_:files:progress:)` | Downloads only if model is not already available |
| `deleteModel(_:)` | Removes a model directory from disk |

#### Component Registry

| Method | Description |
|--------|-------------|
| `register(_:)` | Registers a component descriptor with the global registry |
| `downloadComponent(_:force:progress:)` | Downloads a registered component using registry file list |
| `ensureComponentReady(_:progress:)` | Ensures a component is downloaded and verified |
| `verifyComponent(_:)` | Verifies a component's files against SHA-256 checksums |
| `registeredComponents()` | Returns all registered component descriptors |

#### Migration

| Method | Description |
|--------|-------------|
| `migrateFromLegacyPaths()` | Moves models from legacy cache paths to `sharedModelsDirectory` |

### AcervoManager (Actor)

`AcervoManager` is a singleton actor that wraps the `Acervo` static API with per-model locking. Two concurrent downloads of the same model are serialized; different models proceed in parallel.

| Method | Description |
|--------|-------------|
| `download(_:files:force:progress:)` | Download with per-model serialization |
| `withModelAccess(_:perform:)` | Exclusive access to a model directory while holding the lock |
| `clearCache()` | Clear the URL cache |
| `preloadModels()` | Preload all model metadata into the cache |
| `getDownloadCount(for:)` | Number of times `download()` was called for a model |
| `getAccessCount(for:)` | Number of times `withModelAccess()` was called for a model |
| `printStatisticsReport()` | Print a formatted usage statistics report |
| `resetStatistics()` | Reset all counters |

### Supporting Types

**`AcervoModel`** -- Model metadata (`Identifiable`, `Codable`, `Sendable`):
- `id: String` -- Model identifier (e.g., `"mlx-community/Qwen2.5-7B-Instruct-4bit"`)
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

**`ComponentDescriptor`** -- Declarative model component description (`Sendable`, `Identifiable`):
- `id: String` -- Unique component identifier
- `type: ComponentType` -- Functional role (`.encoder`, `.backbone`, `.decoder`, etc.)
- `repoId: String` -- The origin repository identifier
- `files: [ComponentFile]` -- Required files with optional checksums
- `estimatedSizeBytes: Int64` -- Total expected download size

**`AcervoError`** -- Error types (`LocalizedError`, `Sendable`):
- `directoryCreationFailed(String)`
- `modelNotFound(String)`
- `downloadFailed(fileName:statusCode:)`
- `networkError(Error)`
- `modelAlreadyExists(String)`
- `migrationFailed(source:reason:)`
- `invalidModelId(String)`
- `manifestDownloadFailed(statusCode:)` -- CDN manifest unavailable
- `manifestIntegrityFailed(expected:actual:)` -- Manifest checksum mismatch
- `integrityCheckFailed(file:expected:actual:)` -- File SHA-256 mismatch
- `downloadSizeMismatch(fileName:expected:actual:)` -- File size mismatch
- `fileNotInManifest(fileName:modelId:)` -- Requested file not in CDN manifest
- `localPathNotFound(url:)` -- Caller-supplied local URL does not exist on disk

## Design Principles

- **Stability first.** The API surface is intentionally small. Once set, it should rarely change.
- **Zero dependencies.** Foundation + CryptoKit only. No external model hub libraries, no MLX, no model-specific logic.
- **Not a model loader.** SwiftAcervo finds and downloads models. Loading is the consumer's job.
- **CDN-only downloads.** All models are served from a private CDN with per-file SHA-256 verification.
- **Integrity by default.** Every download is verified against a CDN manifest. Corrupt files are rejected immediately.
- **config.json as validity marker.** Universal across all model types.
- **Swift 6 strict concurrency.** All closures are `@Sendable`. `AcervoManager` is an actor.

## Consumer Integration

SwiftAcervo is the model management layer for the [intrusive-memory](https://github.com/intrusive-memory) ecosystem. Each consumer project depends on SwiftAcervo for model discovery and downloading, then loads models using its own framework. Because every project resolves to the same App Group container (`group.intrusive-memory.models` for shipped intrusive-memory apps, supplied via entitlements for UI apps and `ACERVO_APP_GROUP_ID` for CLIs), a model downloaded by any one tool is immediately available to all others.

### SwiftBruja (MLX Inference)

[SwiftBruja](https://github.com/intrusive-memory/SwiftBruja) provides MLX-based LLM inference. It uses SwiftAcervo to locate quantized language models:

```swift
import SwiftAcervo
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers

let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"

// Manifest-first download: no file list, no guesswork.
try await Acervo.ensureAvailable(modelId, files: []) { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}

// Guard on the local validity marker, then load with MLX.
guard Acervo.isModelAvailable(modelId) else {
    throw MyError.modelNotReady(modelId)
}
let modelDir = try Acervo.modelDirectory(for: modelId)
let container: ModelContainer = try await LLMModelFactory.shared.loadContainer(
    from: modelDir
)
```

This mirrors SwiftBruja's own `BrujaDownloadManager` and `BrujaModelManager`; see [USAGE.md](USAGE.md#reference-implementation-swiftbruja-mlx--tokenizers) for the full walkthrough.

### mlx-audio-swift (Text-to-Speech)

[mlx-audio-swift](https://github.com/intrusive-memory/mlx-audio-swift) handles TTS model inference. It uses SwiftAcervo to download and locate audio models:

```swift
import SwiftAcervo

// Batch the TTS stack. The manifest for each model decides the file list.
try await ModelDownloadManager.shared.ensureModelsAvailable([
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    "mlx-community/snac_24khz"
]) { progress in
    print("[\(progress.model)] \(Int(progress.fraction * 100))%")
}

let ttsDir = try Acervo.modelDirectory(for: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
let codecDir = try Acervo.modelDirectory(for: "mlx-community/snac_24khz")
```

### SwiftVoxAlta (Voice Processing)

[SwiftVoxAlta](https://github.com/intrusive-memory/SwiftVoxAlta) manages voice processing pipelines. It uses `AcervoManager` for thread-safe access when multiple voice operations run concurrently:

```swift
import SwiftAcervo

let voiceModelId = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"

// Thread-safe, manifest-driven download.
try await AcervoManager.shared.download(voiceModelId, files: []) { progress in
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
<App Group Container>/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
└── mlx-community_snac_24khz/
```

### Running the Migration

Call `migrateFromLegacyPaths()` once at application startup. It scans all four legacy subdirectories (`LLM`, `TTS`, `Audio`, `VLM`) for valid model directories (those containing `config.json`) and moves them to `sharedModelsDirectory`:

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
        print("Migrated \(migrated.count) model(s) to sharedModelsDirectory")
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
// These two downloads run concurrently (different models).
// `files: []` = "download whatever the manifest says."
async let llm: Void = AcervoManager.shared.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: []
)
async let tts: Void = AcervoManager.shared.download(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    files: []
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

### Local Path Access

Use `withLocalAccess(_:perform:)` to access a caller-supplied local file or directory that Acervo did not download — for example, a user-supplied LoRA adapter or weight file. Acervo validates the path exists and provides a `LocalHandle` for path-agnostic file resolution:

```swift
let loraURL = URL(filePath: "/path/to/my-lora-adapter")

let weights = try await AcervoManager.shared.withLocalAccess(loraURL) { handle in
    let fileURL = try handle.url(matching: ".safetensors")
    return try Data(contentsOf: fileURL)
}
```

`LocalHandle` provides three resolution methods:
- `url(for:)` — resolve a file by relative path from the root
- `url(matching:)` — find the first file whose path ends with a suffix
- `urls(matching:)` — list all files matching a suffix

If the URL does not exist on disk, `AcervoError.localPathNotFound(url:)` is thrown.

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

Unit tests run entirely offline with no network access required. They use temporary directories to avoid touching `sharedModelsDirectory`:

```bash
xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS'
```

### Integration Tests

Integration tests that hit the CDN are gated behind the `INTEGRATION_TESTS` compile flag. These are excluded from CI by default to keep the test suite fast and deterministic:

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
