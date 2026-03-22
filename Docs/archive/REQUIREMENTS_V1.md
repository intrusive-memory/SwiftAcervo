# SwiftAcervo Requirements

## Vision

**SwiftAcervo** ("Swift Collection/Repository") provides a single canonical location for shared HuggingFace AI models across the intrusive-memory ecosystem. All projects discover, download, and reference models through SwiftAcervo instead of defining their own paths.

This library is designed for **stability**. Like SwiftFijos for test fixtures, once the discovery and download logic is set, it should rarely change. The API surface is intentionally small and final.

## The Problem

Multiple libraries each hardcode their own model subdirectory:

| Project | Current Path |
|---------|-------------|
| SwiftBruja | `~/Library/Caches/intrusive-memory/Models/LLM/` |
| SwiftVoxAlta | `~/Library/Caches/intrusive-memory/Models/TTS/` |
| mlx-audio-swift | `~/Library/Caches/intrusive-memory/Models/Audio/` |
| Produciesta | `~/Library/Caches/intrusive-memory/Models/LLM/` (duplicated logic) |

A model downloaded by one tool is invisible to another. Qwen3-TTS models exist in both `TTS/` and `Audio/`, wasting ~10 GB on duplicates. Adding a new model type requires inventing yet another subdirectory.

## The Solution

**One path. No subdirectories. Every project uses SwiftAcervo.**

```
~/Library/SharedModels/{org}_{repo}/
```

---

## Canonical Path

```
~/Library/SharedModels/
├── mlx-community_Qwen2.5-7B-Instruct-4bit/
│   ├── config.json
│   ├── tokenizer.json
│   ├── tokenizer_config.json
│   └── model.safetensors
├── mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/
│   ├── config.json
│   ├── ...
│   └── speech_tokenizer/
├── mlx-community_Phi-3-mini-4k-instruct-4bit/
│   └── ...
└── mlx-community_snac_24khz/
    └── ...
```

### Path Rules

1. **Base directory**: `~/Library/SharedModels/` -- persistent, not in Caches (survives macOS cleanup)
2. **Model naming**: HuggingFace ID with `/` replaced by `_` (e.g., `mlx-community/Qwen2.5-7B-Instruct-4bit` becomes `mlx-community_Qwen2.5-7B-Instruct-4bit`)
3. **No type subdirectories**: LLM, TTS, Audio, VLM models are all peers in the same flat directory
4. **Validity marker**: A model directory is considered valid when `config.json` is present
5. **Reverse lookup**: Directory name `org_repo` maps back to HuggingFace ID `org/repo` (first underscore that matches a known org boundary)

---

## Design Principles

### 1. Stability First

This library should change as rarely as SwiftFijos. The path convention, discovery logic, and download mechanics are intentionally simple so they do not need updating. Once v1.0 ships, breaking changes should be avoided.

### 2. Zero External Dependencies

Foundation only. No HuggingFace Hub library, no MLX, no model-type-specific logic. URLSession for downloads. FileManager for discovery. That's it.

### 3. Not a Model Loader

SwiftAcervo finds and downloads models. It does **not** load them into memory. Loading is the consumer's job (SwiftBruja loads via MLX, mlx-audio-swift loads via MLXAudioTTS, etc.). SwiftAcervo is the filesystem layer beneath all of them.

### 4. Caller-Specified File Lists

Different model types need different files. LLMs need `model.safetensors` + tokenizer files. Audio models need speech tokenizer subdirectories. SwiftAcervo does not know or care what files a model needs -- the caller provides the file list, and SwiftAcervo downloads them.

### 5. Fuzzy Model Search

Model names from HuggingFace are long and easy to get slightly wrong (`Qwen2.5` vs `Qwen25`, `1.7B` vs `1.7b`, `VoiceDesign` vs `Voice-Design`). SwiftAcervo provides fuzzy matching to find models even when the caller's name is off by a few characters.

**Exact match** (`findModels(matching:)`): Case-insensitive substring search across model IDs. Fast, no tolerance for typos.

**Fuzzy match** (`findModels(fuzzyMatching:)`): Levenshtein edit distance search. Finds models within a configurable distance threshold. Returns results sorted by closeness. Strips common prefixes (`mlx-community/`) before comparing to reduce noise.

**Closest match** (`closestModel(to:)`): Returns the single best fuzzy match, or `nil` if nothing is within threshold. Useful for CLI tools that want to suggest "did you mean...?" corrections.

**Base name matching**: Extracts the base model name by stripping quantization suffixes (`-4bit`, `-8bit`, `-bf16`, `-fp16`), size suffixes (`-0.6B`, `-1.7B`), and variant suffixes (`-Base`, `-Instruct`, `-VoiceDesign`, `-CustomVoice`). Two models with the same base name are considered variants of the same model family.

```swift
// All of these find "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16":
try Acervo.findModels(matching: "Qwen3-TTS")                   // exact substring
try Acervo.findModels(fuzzyMatching: "Qwen3-TTS-12Hz-1.7B")    // fuzzy, close enough
try Acervo.closestModel(to: "Qwen3-TTS-1.7B-Base")             // best single match

// Base name grouping:
let families = try Acervo.modelFamilies()
// ["mlx-community/Qwen3-TTS-12Hz": [0.6B-Base-bf16, 1.7B-Base-bf16, 1.7B-VoiceDesign-bf16]]
```

The edit distance implementation is built-in (no external dependency). Standard Levenshtein with default threshold of 5 (configurable per call).

### 6. Pattern After SwiftFijos

| SwiftFijos | SwiftAcervo |
|-----------|------------|
| `Fijos.swift` -- static discovery | `Acervo.swift` -- static discovery + download |
| `FixtureManager.swift` -- actor, locks, cache | `AcervoManager.swift` -- actor, per-model locks, cache |
| `Fixture` struct -- metadata | `AcervoModel` struct -- metadata |
| `FijosError` enum | `AcervoError` enum |
| Fixtures directory | `~/Library/SharedModels/` |

---

## v1.0 Deliverable

### Static API (`Acervo`)

```swift
import SwiftAcervo

// Path resolution
let dir = Acervo.sharedModelsDirectory           // ~/Library/SharedModels/
let modelDir = Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
let slug = Acervo.slugify("mlx-community/Qwen2.5-7B-Instruct-4bit")  // "mlx-community_Qwen2.5-7B-Instruct-4bit"

// Availability
let ready = Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit")
let hasFile = Acervo.modelFileExists("mlx-community/Qwen2.5-7B-Instruct-4bit", fileName: "tokenizer.json")

// Discovery
let allModels = try Acervo.listModels()
let info = try Acervo.modelInfo("mlx-community/Qwen2.5-7B-Instruct-4bit")
let matches = try Acervo.findModels(matching: "Qwen")

// Fuzzy search (tolerates typos and near-misses)
let fuzzy = try Acervo.findModels(fuzzyMatching: "Qwen2.5-7B-Instruct")  // finds "Qwen2.5-7B-Instruct-4bit"
let closest = try Acervo.closestModel(to: "Qwen3-TTS-1.7B-Base")          // best match by edit distance

// Download
try await Acervo.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
) { progress in
    print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
}

// Ensure available (skip if already downloaded)
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
)

// Deletion
try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")

// Migration from legacy paths
let migrated = try Acervo.migrateFromLegacyPaths()
```

### Thread-Safe Manager (`AcervoManager`)

```swift
import SwiftAcervo

// Per-model serialized download (waits if same model is already downloading)
try await AcervoManager.shared.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "model.safetensors"]
)

// Exclusive access to a model directory (prevents concurrent modifications)
let modelDir = try await AcervoManager.shared.withModelAccess(
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
) { url in
    // Safe to read/write model files here
    return url
}

// Cache and statistics
AcervoManager.shared.clearCache()
try await AcervoManager.shared.preloadModels()
AcervoManager.shared.printStatisticsReport()
```

### Model Metadata (`AcervoModel`)

```swift
public struct AcervoModel: Identifiable, Equatable, Codable, Sendable {
    public let id: String           // "mlx-community/Qwen2.5-7B-Instruct-4bit"
    public let path: URL            // ~/Library/SharedModels/mlx-community_Qwen2.5-7B-Instruct-4bit/
    public let sizeBytes: Int64     // Total size of all files
    public let downloadDate: Date   // Directory creation date
    public var formattedSize: String // "4.4 GB"
    public var slug: String         // "mlx-community_Qwen2.5-7B-Instruct-4bit"
    public var baseName: String     // "Qwen2.5-7B-Instruct" (stripped of quantization/variant suffixes)
    public var familyName: String   // "mlx-community/Qwen2.5" (org + base model without size/variant)
}
```

### Download Progress

```swift
public struct AcervoDownloadProgress: Sendable {
    public let fileName: String       // Current file being downloaded
    public let bytesDownloaded: Int64  // Bytes so far for current file
    public let totalBytes: Int64?     // Expected total (nil if unknown)
    public let fileIndex: Int         // 0-based index in file list
    public let totalFiles: Int        // Total files being downloaded
    public var overallProgress: Double // 0.0 to 1.0
}
```

### Error Types

```swift
public enum AcervoError: LocalizedError, Sendable {
    case directoryCreationFailed(String)
    case modelNotFound(String)
    case downloadFailed(fileName: String, statusCode: Int)
    case networkError(Error)
    case modelAlreadyExists(String)
    case migrationFailed(source: String, reason: String)
    case invalidModelId(String)
}
```

---

## Package Structure

```
SwiftAcervo/
├── Package.swift
├── REQUIREMENTS.md
├── AGENTS.md
├── CLAUDE.md
├── GEMINI.md
├── README.md
├── Sources/
│   └── SwiftAcervo/
│       ├── Acervo.swift              # Static discovery + download API
│       ├── AcervoManager.swift       # Actor-based thread-safe manager
│       ├── AcervoModel.swift         # Model metadata struct
│       ├── AcervoError.swift         # Error types
│       └── AcervoDownloader.swift    # HuggingFace download implementation
├── Tests/
│   └── SwiftAcervoTests/
│       ├── AcervoTests.swift         # Static API tests
│       ├── AcervoManagerTests.swift  # Actor/threading tests
│       └── AcervoDownloaderTests.swift # URL construction, progress math
└── .github/
    └── workflows/
        └── tests.yml
```

---

## Dependencies

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftAcervo",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    products: [
        .library(name: "SwiftAcervo", targets: ["SwiftAcervo"])
    ],
    targets: [
        .target(
            name: "SwiftAcervo",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SwiftAcervoTests",
            dependencies: ["SwiftAcervo"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
```

**Zero external dependencies.** Foundation only. No HuggingFace Hub library, no MLX, no model-specific imports.

---

## Download Mechanics

### HuggingFace URL Pattern

```
https://huggingface.co/{modelId}/resolve/main/{fileName}
```

Example:
```
https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit/resolve/main/config.json
```

### Download Flow

```
Acervo.download("org/repo", files: [...])
│
├─ Validate model ID (must contain exactly one "/")
├─ Compute destination: ~/Library/SharedModels/org_repo/
├─ Create directory if needed (withIntermediateDirectories: true)
│
└─ For each file in the list:
   ├─ Skip if file already exists (unless force: true)
   ├─ Construct URL: https://huggingface.co/org/repo/resolve/main/{file}
   ├─ Download via URLSession.shared.download(from:)
   ├─ Verify HTTP 200
   ├─ Move temp file to destination (atomic)
   └─ Report progress
```

### Auth Token Support

For gated models (e.g., Llama), pass an optional bearer token:

```swift
try await Acervo.download(
    "meta-llama/Llama-3-8B",
    files: ["config.json", "model.safetensors"],
    token: hfToken
)
```

The token is sent as an `Authorization: Bearer {token}` header. SwiftAcervo does not store, cache, or manage tokens. The caller provides them.

### Subdirectory Downloads

Some models have files in subdirectories (e.g., `speech_tokenizer/config.json`). The caller includes the relative path in the file list:

```swift
try await Acervo.download(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    files: [
        "config.json",
        "model.safetensors",
        "speech_tokenizer/config.json",
        "speech_tokenizer/model.safetensors"
    ]
)
```

SwiftAcervo creates intermediate directories as needed.

---

## Migration from Legacy Paths

`Acervo.migrateFromLegacyPaths()` scans these directories:

```
~/Library/Caches/intrusive-memory/Models/LLM/
~/Library/Caches/intrusive-memory/Models/TTS/
~/Library/Caches/intrusive-memory/Models/Audio/
~/Library/Caches/intrusive-memory/Models/VLM/
```

For each subdirectory containing `config.json`:
1. Extract the slug (directory name, e.g., `mlx-community_Qwen2.5-7B-Instruct-4bit`)
2. If `~/Library/SharedModels/{slug}/` does not exist, **move** the directory
3. If it already exists, **skip** (prefer the existing copy in the new location)
4. Return list of migrated `AcervoModel` entries

The old parent directories are not deleted. Consumers clean up their own legacy references.

---

## Consumer Integration

### How Each Project Uses SwiftAcervo

**SwiftBruja** (LLM inference):
```swift
import SwiftAcervo

// BrujaModelManager replaces its path logic with:
var modelsDirectory: URL { Acervo.sharedModelsDirectory }

func modelDirectory(for modelId: String) -> URL {
    Acervo.modelDirectory(for: modelId)
}

func isModelAvailable(_ modelId: String) -> Bool {
    Acervo.isModelAvailable(modelId)
}

// Download still specifies LLM-specific file list:
try await Acervo.ensureAvailable(modelId, files: [
    "config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"
])

// Loading stays in SwiftBruja (MLX-specific):
let config = ModelConfiguration(directory: Acervo.modelDirectory(for: modelId))
let container = try await LLMModelFactory.shared.loadContainer(configuration: config)
```

**mlx-audio-swift** (audio inference):
```swift
import SwiftAcervo

// ModelUtils.resolveOrDownloadModel() becomes:
let modelDir = Acervo.modelDirectory(for: repoID.description)
if !Acervo.isModelAvailable(repoID.description) {
    try await Acervo.download(repoID.description, files: requiredFiles)
}
return modelDir
```

**SwiftVoxAlta** (TTS voice design):
```swift
import SwiftAcervo

// DigaModelManager replaces its cache logic with:
let modelsDirectory = Acervo.sharedModelsDirectory

func isModelAvailable(_ modelId: String) -> Bool {
    Acervo.isModelAvailable(modelId)
}
```

**Produciesta** (main app):
```swift
// Can delete MLXModelDownloader.swift entirely.
// Use BrujaModelManager (which now uses SwiftAcervo internally).
```

---

## Thread Safety

`AcervoManager` is a `@globalActor` that provides:

- **Per-model download locks**: Two concurrent downloads of the same model are serialized. Different models download concurrently.
- **Exclusive model access**: `withModelAccess(_:perform:)` prevents concurrent reads/writes to the same model directory.
- **Automatic lock release**: `defer` ensures locks are released even on error.
- **Wait loop**: 50ms sleep between lock checks when a model is locked by another caller.
- **URL caching**: Thread-safe dictionary for cached model directory URLs.
- **Statistics**: Thread-safe download and access count tracking.

All closures passed to `AcervoManager` must be `@Sendable`.

---

## Platform Requirements

- **macOS 26.0+** / **iOS 26.0+**
- **Swift 6.2+** with strict concurrency
- **Zero external dependencies**
- NEVER add `@available` for older platforms
- NEVER add `#available` runtime checks for older platforms

---

## CI/CD

### GitHub Actions

```yaml
name: Tests

on:
  pull_request:
    branches: [main, development]

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  test-macos:
    name: Test on macOS
    runs-on: macos-26

    steps:
      - uses: actions/checkout@v4
      - name: Show Swift version
        run: swift --version
      - name: Build
        run: xcodebuild -scheme SwiftAcervo -destination 'platform=macOS' build
      - name: Test
        run: xcodebuild -scheme SwiftAcervo -destination 'platform=macOS' test
```

### Branch Strategy

- **`development`** -- all work happens here
- **`main`** -- protected, PR-only, CI must pass
- NEVER commit directly to `main`
- NEVER delete `development`

**Flow**: `development` -> PR -> CI passes -> Merge -> Tag -> Release

---

## Test Strategy

### Unit Tests (No Network Required)

- Path construction: `slugify()`, `modelDirectory(for:)`, `sharedModelsDirectory`
- Model availability: Create temp directories with/without `config.json`
- Model listing: Create multiple temp model directories, verify enumeration
- Model info: Verify `sizeBytes`, `downloadDate`, `formattedSize`
- Pattern matching: `findModels(matching:)` with various patterns
- Error cases: Invalid model IDs, missing directories, missing models
- Progress math: `overallProgress` computation, `formattedProgress`
- URL construction: HuggingFace URL building
- Migration: Create fake legacy directories, verify move logic
- Manager locking: Verify per-model serialization
- Manager statistics: Verify count tracking and reset

### Integration Tests (Network Required, Tagged)

- Download a small model's `config.json` from HuggingFace
- Verify file lands at correct path
- Verify `force: true` re-downloads
- Verify `skip-if-exists` behavior
- Verify auth token header sent when provided

---

## What SwiftAcervo is NOT

1. **Not a model loader** -- it does not import MLX, MLXAudioTTS, or any inference framework
2. **Not a model registry** -- it does not maintain a database of known models or versions
3. **Not a HuggingFace client** -- it downloads files via direct URLs, not the Hub API
4. **Not a cache manager** -- it does not evict models or manage disk quotas
5. **Not a model converter** -- it does not quantize, optimize, or transform model files

---

## Future Considerations (Not v1.0)

These are explicitly **out of scope** for v1.0 but may be considered later:

- **Disk quota management**: Alert when SharedModels exceeds a size threshold
- **Model versioning**: Track which revision of a HuggingFace model is downloaded
- **Integrity verification**: SHA256 checksums for downloaded files
- **Partial download recovery**: Resume interrupted downloads instead of restarting
- **Sandboxed app support**: Fallback path for macOS App Sandbox containers
