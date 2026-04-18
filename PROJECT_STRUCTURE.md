# PROJECT_STRUCTURE.md — File Organization and Module Layout

**For**: Developers navigating the SwiftAcervo codebase.

---

## Directory Tree

```
SwiftAcervo/
├── Sources/
│   ├── SwiftAcervo/              # Main library
│   │   ├── Acervo.swift
│   │   ├── AcervoManager.swift
│   │   ├── AcervoModel.swift
│   │   ├── AcervoError.swift
│   │   ├── AcervoDownloader.swift
│   │   ├── AcervoDownloadProgress.swift
│   │   ├── AcervoMigration.swift
│   │   ├── LevenshteinDistance.swift
│   │   ├── CDNManifest.swift
│   │   ├── SecureDownloadSession.swift
│   │   ├── IntegrityVerification.swift
│   │   ├── ComponentDescriptor.swift
│   │   ├── ComponentHandle.swift
│   │   ├── ComponentRegistry.swift
│   │   └── LocalHandle.swift
│   └── acervo/                   # CLI tool
│       ├── AcervoCLI.swift
│       ├── UploadCommand.swift
│       ├── ShipCommand.swift
│       ├── DownloadCommand.swift
│       ├── VerifyCommand.swift
│       ├── ManifestCommand.swift
│       ├── CDNUploader.swift
│       ├── ManifestGenerator.swift
│       ├── HuggingFaceClient.swift
│       ├── ToolCheck.swift
│       └── Version.swift
├── Tests/
│   ├── SwiftAcervoTests/         # Library unit tests
│   │   ├── AcervoTests.swift
│   │   ├── AcervoManagerTests.swift
│   │   ├── ComponentRegistryTests.swift
│   │   └── ...
│   ├── AcervoToolTests/          # CLI unit tests
│   │   ├── ArgumentBuildersTests.swift
│   │   ├── ManifestGeneratorTests.swift
│   │   ├── IntegrityCheckTests.swift
│   │   └── ...
│   └── AcervoToolIntegrationTests/  # Full pipeline tests
│       └── ...
├── Tools/                        # Legacy shell scripts
│   ├── generate-manifest.sh
│   └── upload-model.sh
├── Package.swift
├── Makefile
└── Documentation files (.md)
    ├── README.md
    ├── USAGE.md
    ├── API_REFERENCE.md
    ├── BUILD_AND_TEST.md
    ├── DESIGN_PATTERNS.md
    ├── CDN_ARCHITECTURE.md
    ├── CDN_UPLOAD.md
    ├── PROJECT_STRUCTURE.md
    ├── SHARED_MODELS_DIRECTORY.md
    ├── REQUIREMENTS.md
    ├── ARCHITECTURE.md
    ├── CONTRIBUTING.md
    └── CLAUDE.md
```

---

## SwiftAcervo Library (`Sources/SwiftAcervo/`)

### Core API

#### Acervo.swift
**Namespace**: Static enum `Acervo`

Methods:
- **Path resolution**: `sharedModelsDirectory`, `modelDirectory(for:)`, `slugify(_:)`
- **Availability**: `isModelAvailable(_:)`, `modelFileExists(_:fileName:)`
- **Discovery**: `listModels()`, `modelInfo(_:)`, `findModels(matching:)`, `findModels(fuzzyMatching:)`, `closestModel(to:)`, `modelFamilies()`
- **Download**: `download(_:files:force:progress:)`, `ensureAvailable(_:files:progress:)`
- **Migration**: `migrateFromLegacyPaths()`
- **Components**: `register(_:)`, `registeredComponents()`, `downloadComponent(_:)`, `ensureComponentReady(_:)`, `verifyComponent(_:)`

**Type**: ~500–600 lines, mostly method signatures and delegates to `AcervoManager`

#### AcervoManager.swift
**Namespace**: Singleton actor `AcervoManager.shared`

Methods:
- **Download with per-model locking**: `download(_:files:force:progress:)`
- **Exclusive model access**: `withModelAccess(_:perform:)`
- **Local path access**: `withLocalAccess(_:perform:)`
- **Cache management**: `clearCache()`, `preloadModels()`
- **Metrics**: `getDownloadCount(for:)`, `getAccessCount(for:)`, `printStatisticsReport()`, `resetStatistics()`

**Type**: Actor with per-model `NSLock` dictionary, ~400–500 lines

### Supporting Types

#### AcervoModel.swift
**Type**: `struct AcervoModel: Identifiable, Codable, Sendable`

Properties:
- `id: String` — Model identifier
- `path: URL` — Local directory
- `sizeBytes: Int64` — Total size
- `downloadDate: Date` — Creation date
- `formattedSize: String` — Human-readable size
- `slug: String` — Directory name
- `baseName: String` — Base model name
- `familyName: String` — Family grouping
- `files: [CDNFile]` — Manifest files
- `manifestChecksum: String`
- `updatedAt: Date`

#### AcervoError.swift
**Type**: `enum AcervoError: LocalizedError, Sendable`

Cases: 14 error types (modelNotFound, downloadFailed, checksumMismatch, etc.)

**Methods**: `localizedDescription` for user-facing messages

#### AcervoDownloadProgress.swift
**Type**: `struct AcervoDownloadProgress: Sendable`

Properties: fileName, bytesDownloaded, totalBytes, fileIndex, totalFiles, overallProgress

### Internal Implementation

#### AcervoDownloader.swift
Implements downloading and integrity verification:
- Fetches manifest from CDN
- Validates manifest integrity (manifest checksum)
- Streams file downloads via `SecureDownloadSession`
- Verifies file size and SHA-256
- Manages atomic temp-to-destination moves
- Concurrent file downloads via `TaskGroup`

#### IntegrityVerification.swift
SHA-256 verification utilities:
- Streaming hash computation (4 MB chunks)
- File verification against checksums
- Manifest checksum validation

#### SecureDownloadSession.swift
Custom URLSession wrapper:
- Rejects redirects to non-CDN domains
- Streams download in chunks
- Transparent to caller

#### CDNManifest.swift
Manifest parsing and validation:
- `struct CDNManifest` — Decoded manifest.json
- `struct CDNFile` — Individual file metadata
- Manifest format validation
- Checksum computation

#### AcervoMigration.swift
Migration from legacy paths:
- Scans `~/Library/Caches/intrusive-memory/Models/`
- Finds valid models (those with config.json)
- Moves to `sharedModelsDirectory`
- Handles errors gracefully (partial migration)

#### LevenshteinDistance.swift
Fuzzy search implementation:
- Levenshtein edit distance algorithm
- Used by `closestModel(to:)` and `findModels(fuzzyMatching:)`
- Default threshold: 5

### Component Registry

#### ComponentDescriptor.swift
**Type**: `struct ComponentDescriptor: Sendable, Identifiable`

Properties: id, type, displayName, repoId, files, estimatedSizeBytes, minimumMemoryBytes, metadata

**Type**: ComponentType enum (encoder, decoder, backbone, languageModel, vocoder, tokenizer, custom)

**Type**: ComponentFile struct (relativePath, expectedSizeBytes, sha256)

#### ComponentRegistry.swift
Global registry for component descriptors:
- Thread-safe dictionary of registered components
- Deduplication logic (same ID + repo + files = no-op)
- Merge metadata on re-registration
- Used by plugins to declare downloadable components

**Type**: ~300 lines, mostly thread-safe access

#### ComponentHandle.swift
Opaque file access handle:
- `url(for:)` — Resolve by relative path
- `url(matching:)` — Find first file matching suffix
- `urls(matching:)` — Find all files matching suffix
- `availableFiles()` — List all files

**Type**: Wrapper around scoped URL references (valid only within closure scope)

#### LocalHandle.swift
Like `ComponentHandle`, but for caller-supplied local paths:
- Same interface as `ComponentHandle`
- Used by `withLocalAccess(_:perform:)`
- Validates path exists before access

---

## acervo CLI Tool (`Sources/acervo/`)

Integrated using ArgumentParser (Swift Package Manager dependency).

### Root Command

#### AcervoCLI.swift
**Type**: `@main struct AcervoCLI: AsyncParsableCommand`

Subcommands:
- `download` — Download from HuggingFace
- `manifest` — Generate manifest
- `verify` — Verify integrity
- `upload` — Upload to R2
- `ship` — Full pipeline

**Type**: ~50 lines, mostly metadata

### Subcommands

#### DownloadCommand.swift
**Arguments**: `--model-id`, `--staging-dir`

Actions:
1. Validates arguments
2. Checks `hf` CLI availability
3. Calls `HuggingFaceClient.download()`
4. Performs CHECK 1 (LFS integrity)

#### ManifestCommand.swift
**Arguments**: `--model-id`, `--staging-dir`

Actions:
1. Calls `ManifestGenerator.generate()`
2. Performs CHECK 2–4 (manifest validation)
3. Writes manifest.json

#### VerifyCommand.swift
**Arguments**: `--model-id`, `--staging-dir`, `--verbose` (optional)

Actions:
1. Performs all 6 checks
2. Reports results per check
3. Exits with success/failure code

#### UploadCommand.swift
**Arguments**: `--model-id`, `--staging-dir`, `--endpoint`, `--bucket`

Actions:
1. Verifies files and manifest
2. Calls `CDNUploader.upload()`
3. Uploads files and manifest to R2
4. Verifies uploaded files

#### ShipCommand.swift
**Arguments**: `--model-id`, `--staging-dir`

Actions:
1. Calls Download
2. Calls Manifest
3. Calls Verify
4. Calls Upload
5. Reports overall success

**Type**: Orchestrates the full pipeline in one command

### Implementation Details

#### ManifestGenerator.swift
Generates manifest.json:
- Scans staging directory
- Computes SHA-256 per file
- Computes manifest checksum (SHA-256-of-checksums)
- Writes manifest.json

#### CDNUploader.swift
Uploads to R2 via `aws` CLI:
- Validates files match manifest
- Uploads each file to `s3://{bucket}/models/{slug}/{fileName}`
- Uses environment variables for credentials
- Verifies uploaded files against manifest

#### HuggingFaceClient.swift
Downloads from HuggingFace:
- Fetches file list via HuggingFace API
- Downloads each file via `hf download`
- Verifies LFS pointers (CHECK 1)
- Reports progress

#### ToolCheck.swift
Validates required CLI tools:
- Checks if `aws` is on PATH
- Checks if `hf` is on PATH
- Fails early with helpful message if missing

#### Version.swift
Current CLI version constant:
- Used by `--version` flag
- Should match `Package.swift` version

---

## Tests (`Tests/`)

### Library Tests (`SwiftAcervoTests/`)

Unit tests with no network access:

- **AcervoTests.swift** — Model discovery, filtering, fuzzy search
- **AcervoManagerTests.swift** — Per-model locking, concurrent access
- **ComponentRegistryTests.swift** — Registration, deduplication
- **IntegrityVerificationTests.swift** — SHA-256 hashing
- **LevenshteinDistanceTests.swift** — Fuzzy search algorithm
- **MigrationTests.swift** — Legacy path migration
- **ManifestTests.swift** — Manifest parsing, validation

Run with: `make test` or `xcodebuild test -scheme SwiftAcervo-Package`

### CLI Unit Tests (`AcervoToolTests/`)

Unit tests for argument parsing and logic:

- **ArgumentParsingTests.swift** — Command parsing
- **ManifestGeneratorTests.swift** — Manifest generation
- **IntegrityCheckTests.swift** — All 6 checks
- **HuggingFaceClientTests.swift** — Mock downloads

Run with: `make test-acervo-unit`

### CLI Integration Tests (`AcervoToolIntegrationTests/`)

Full pipeline tests (slow, require credentials):

- Downloads from actual HuggingFace
- Uploads to actual R2
- Verifies round-trip integrity

Run with: `xcodebuild test -scheme AcervoToolIntegrationTests`

---

## Legacy Tools (`Tools/`)

Shell scripts for backward compatibility:

- **generate-manifest.sh** — Old way to generate manifest (use `acervo manifest`)
- **upload-model.sh** — Old way to upload (use `acervo ship`)

Still functional but not recommended.

---

## Package Configuration (`Package.swift`)

```swift
let package = Package(
    name: "SwiftAcervo",
    platforms: [
        .macOS(.v26),
        .iOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(name: "SwiftAcervo", dependencies: []),
        .executableTarget(
            name: "acervo",
            dependencies: [
                "SwiftAcervo",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "SwiftAcervoTests", dependencies: ["SwiftAcervo"]),
        .testTarget(name: "AcervoToolTests", dependencies: ["acervo"]),
        .testTarget(name: "AcervoToolIntegrationTests", dependencies: ["acervo"])
    ]
)
```

**Key points**:
- Minimum: Swift 6.2, iOS 26.0, macOS 26.0
- Only external dependency: `swift-argument-parser` (for CLI)
- Three test targets

---

## Build Configuration (`Makefile`)

Standard targets:
- `make build` — Build library
- `make test` — Run all tests
- `make lint` — Format code
- `make clean` — Clean artifacts
- `make build-acervo` — Build CLI
- `make install-acervo` — Build and install CLI to bin/
- `make release-acervo` — Release build of CLI

---

## Documentation Structure

- **README.md** — User-facing overview and quick start
- **USAGE.md** — Integration guide for consuming libraries (start here!)
- **API_REFERENCE.md** — Complete method and type reference
- **BUILD_AND_TEST.md** — Building, testing, CI/CD
- **CDN_ARCHITECTURE.md** — How downloads work
- **CDN_UPLOAD.md** — How to upload to R2
- **DESIGN_PATTERNS.md** — Architectural decisions
- **PROJECT_STRUCTURE.md** (this file) — File organization
- **SHARED_MODELS_DIRECTORY.md** — Canonical storage location
- **REQUIREMENTS.md** — v2 component registry spec (draft)
- **ARCHITECTURE.md** — Ecosystem dependency map
- **CONTRIBUTING.md** — Development guidelines
- **CLAUDE.md** — AI agent reference

---

## Dependency Graph

```
SwiftAcervo (library, no external deps)
├── CryptoKit (system, SHA-256)
└── Foundation (system, FileManager, URLSession)

acervo (CLI)
├── SwiftAcervo
├── ArgumentParser (external, CLI parsing)
├── CryptoKit
└── Foundation
```

---

## Key Invariants

1. **SwiftAcervo library has zero external dependencies** — Only Foundation + CryptoKit
2. **acervo CLI depends only on SwiftAcervo + ArgumentParser** — No HuggingFace SDK, no AWS SDK
3. **All tests are deterministic** — Unit tests use temp directories, no shared state
4. **Library exports 6 main types**:
   - `Acervo` (namespace)
   - `AcervoManager` (actor)
   - `AcervoModel` (metadata)
   - `AcervoError` (errors)
   - `ComponentDescriptor` (plugin registration)
   - `ComponentRegistry` (global registry)

---

## See Also

- **[API_REFERENCE.md](API_REFERENCE.md)** — All exported types and methods
- **[BUILD_AND_TEST.md](BUILD_AND_TEST.md)** — How to run tests
- **[USAGE.md](USAGE.md)** — Using the library
