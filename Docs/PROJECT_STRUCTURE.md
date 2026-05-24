# PROJECT_STRUCTURE.md — File Organization and Module Layout

**For**: Developers navigating the SwiftAcervo codebase.

---

## Directory Tree

```
SwiftAcervo/
├── Sources/
│   ├── SwiftAcervo/              # Main library
│   │   ├── Acervo.swift                        # Enum shell: version, offline-mode env helpers (~51 lines)
│   │   ├── Acervo+PathResolution.swift         # App group, slugify, modelDirectory, ensureModelDirectory, excludeFromBackup
│   │   ├── Acervo+Availability.swift           # Legacy isModelAvailable/isModelConfigPresent/modelFileExists + 3-state availability(_:)
│   │   ├── Acervo+Discovery.swift              # listModels, gcEmptyModelDirectories, modelInfo, modelFamilies, directorySize
│   │   ├── Acervo+Search.swift                 # Glob findModels(matching:) + fuzzy findModels/closestModel + private helpers
│   │   ├── Acervo+Download.swift               # Legacy download(_:files:progress:telemetry:) orchestration facade
│   │   ├── Acervo+EnsureAvailable.swift        # Repo-keyed + slug-keyed ensureAvailable + ComponentStateBox aggregator
│   │   ├── Acervo+SlugAvailability.swift       # Slug-keyed availability(slug:url:) + internal isOrgRepoSlug/componentTotalBytes/fetchSlugManifest helpers
│   │   ├── Acervo+DeleteModel.swift            # Legacy deleteModel(_:) + slug-keyed deleteModel(slug:url:)
│   │   ├── Acervo+ComponentRegistration.swift  # register(_:) × 2 + unregister(_:) — thin facade over ComponentRegistry
│   │   ├── Acervo+ComponentCatalog.swift       # registeredComponents, component, isComponentReady, pendingComponents, totalCatalogSize, unhydratedComponents
│   │   ├── Acervo+ComponentIntegrity.swift     # verifyComponent(_:) + verifyAllComponents() — delegates to IntegrityVerification
│   │   ├── Acervo+ManifestAccess.swift         # Four fetchManifest(...) overloads — thin facade over AcervoDownloader
│   │   ├── Acervo+Hydration.swift              # hydrateComponent + internal HydrationCoalescer actor (single-flight coalescing)
│   │   ├── Acervo+ComponentDownloads.swift     # downloadComponent, ensureComponentReady, ensureComponentsReady, deleteComponent
│   │   ├── Acervo+CDNMutation.swift            # publishModel, deleteFromCDN, recache — CDN write operations (pre-mission)
│   │   ├── AcervoManager.swift
│   │   ├── AcervoModel.swift
│   │   ├── AcervoError.swift
│   │   ├── AcervoDownloader.swift
│   │   ├── AcervoDownloadProgress.swift
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
│       ├── DeleteCommand.swift
│       ├── RecacheCommand.swift
│       ├── PublishRunner.swift
│       ├── ManifestGenerator.swift
│       ├── HuggingFaceClient.swift
│       ├── CredentialResolver.swift
│       ├── ToolCheck.swift
│       ├── ProcessRunner.swift
│       └── Version.swift
├── Tests/
│   ├── SwiftAcervoTests/         # Library unit tests
│   │   ├── AcervoTests.swift
│   │   ├── AcervoManagerTests.swift
│   │   ├── ComponentRegistryTests.swift
│   │   └── ...
│   └── AcervoToolTests/          # CLI unit tests + read-only CDN smoke
│       ├── ArgumentBuildersTests.swift
│       ├── ManifestGeneratorTests.swift
│       ├── IntegrityCheckTests.swift
│       ├── CDNManifestFetchTests.swift  # live-CDN read-only smoke (no creds)
│       └── ...
├── Tools/                        # Legacy shell scripts
│   ├── generate-manifest.sh
│   └── upload-model.sh
├── Package.swift
├── Makefile
└── Documentation files (.md)
    ├── README.md
    ├── USAGE-library.md
    ├── USAGE-library.md
    ├── USAGE-cli.md
    ├── DESIGN_PATTERNS.md
    ├── CDN_ARCHITECTURE.md
    ├── USAGE-cli.md
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
**Namespace**: Caseless enum `Acervo` — pure namespace shell (~51 lines).

Contains only: `version`, `offlineModeEnvironmentVariable`, `isOfflineModeActive`. All methods live in sibling `Acervo+*.swift` extension files (see directory tree above).

#### Acervo+PathResolution.swift
Path resolution: `appGroupEnvironmentVariable`, `sharedModelsDirectory`, `slugify(_:)`, `modelDirectory(for:)`, `ensureModelDirectory(for:)`, `excludeFromBackup(_:)`.

#### Acervo+Availability.swift
Availability checks: `isModelAvailable(_:)`, `isModelConfigPresent(_:)`, `modelFileExists(_:fileName:)` (legacy synchronous), plus async `availability(_:verifyHashes:)` (3-state: `.notAvailable`, `.downloading`, `.available`).

#### Acervo+Discovery.swift
Filesystem enumeration: `listModels()`, `gcEmptyModelDirectories()`, `modelInfo(_:)`, `modelFamilies()`, and the private `directorySize(of:)` helper.

#### Acervo+Search.swift
Model search: `findModels(matching:)` (glob), `findModels(fuzzyMatching:editDistance:)`, `closestModel(to:editDistance:)`, and private helpers `commonPrefixes`/`stripCommonPrefixes`.

#### Acervo+Download.swift
Legacy download orchestration: `download(_:files:progress:telemetry:)` — thin facade delegating to `AcervoDownloader`.

#### Acervo+EnsureAvailable.swift
Ensure-available orchestration: repo-keyed `ensureAvailable(_:files:progress:telemetry:)` + slug-keyed `ensureAvailable(slug:url:files:progress:telemetry:)`, plus the `ComponentStateBox` progress-aggregator helper.

#### Acervo+SlugAvailability.swift
Slug-keyed availability: `availability(slug:url:telemetry:)` + internal helpers `isOrgRepoSlug`, `componentTotalBytes`, `fetchSlugManifest` (kept `internal static` for cross-file access by `Acervo+EnsureAvailable.swift`).

#### Acervo+DeleteModel.swift
Local model deletion: `deleteModel(_:)` (legacy repo-keyed) + `deleteModel(slug:url:)` (slug-keyed). Symmetric with `Acervo+CDNMutation.swift` (remote vs local delete).

#### Acervo+ComponentRegistration.swift
Component registration facade: `register(_:)` (two overloads) + `unregister(_:)`. Thin pass-through to `ComponentRegistry`.

#### Acervo+ComponentCatalog.swift
Component catalog queries: `registeredComponents()` (two overloads), `component(_:)`, `isComponentReady(_:)`, `isComponentReadyAsync(_:)`, `pendingComponents()`, `totalCatalogSize()`, `unhydratedComponents()`.

#### Acervo+ComponentIntegrity.swift
Component integrity: `verifyComponent(_:)` + `verifyAllComponents()`. Delegates to `IntegrityVerification`.

#### Acervo+ManifestAccess.swift
Manifest access: four `fetchManifest(...)` overloads (by modelId / componentId, with optional URLSession seam). Pure facade over `AcervoDownloader.downloadManifest`.

#### Acervo+Hydration.swift
Component hydration: `hydrateComponent(_:telemetry:)` + the internal `HydrationCoalescer` actor (ensures concurrent hydration calls for the same component coalesce into one underlying network fetch).

#### Acervo+ComponentDownloads.swift
Component download + deletion: `downloadComponent(_:progress:telemetry:)`, `ensureComponentReady(_:progress:telemetry:)`, `ensureComponentsReady(_:progress:telemetry:)`, `deleteComponent(_:)`.

#### Acervo+CDNMutation.swift
CDN write operations (pre-mission, unchanged): `publishModel(modelId:directory:credentials:keepOrphans:progress:)`, `deleteFromCDN(modelId:credentials:progress:)`, `recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:)`.

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
**Arguments**: `modelId`, `directory`, `--bucket`, `--prefix`, `--endpoint`, `--dry-run`, `--force`, `--keep-orphans`, `--no-verify`, `--token`, `--source`, `--output`

Actions:
1. Resolves credentials via `CredentialResolver`
2. Short-circuits on `--dry-run`: generates manifest, prints summary, exits 0
3. Delegates to `PublishRunner.run(...)` which calls `Acervo.publishModel` (CHECKs 2–6 + orphan prune)

#### ShipCommand.swift
**Arguments**: `modelId`, optional `files`, `--source`, `--output`, `--token`, `--no-verify`, `--bucket`, `--prefix`, `--endpoint`, `--dry-run`, `--force`, `--keep-orphans`

Actions:
1. Shells out to `hf download` via `ProcessRunner`
2. CHECK 0: HF tree completeness check
3. CHECK 1: HF LFS SHA-256 verification (skipped with `--no-verify`)
4. Short-circuits on `--dry-run`: generates manifest, prints summary, exits 0
5. Delegates to `PublishRunner.run(...)` which calls `Acervo.publishModel` (CHECKs 2–6 + orphan prune)

**Type**: Orchestrates the full download + publish pipeline in one command

#### DeleteCommand.swift
**Arguments**: `modelId`, `--yes`

Actions:
1. Resolves credentials via `CredentialResolver`
2. Prompts for confirmation (TTY) or requires `--yes` (non-interactive)
3. Calls `Acervo.deleteFromCDN(...)` and maps `AcervoDeleteProgress` to stdout

#### RecacheCommand.swift
**Arguments**: `modelId`, `--keep-orphans`, `--yes`

Actions:
1. Resolves credentials via `CredentialResolver`
2. Calls `Acervo.recache(...)` with an `hf download` closure as `fetchSource`

### Implementation Details

#### PublishRunner.swift
CLI-internal seam around `Acervo.publishModel`. Holds a swappable `override` closure so
tests can assert call routing (e.g. `keepOrphans` propagation) and drive the pipeline
against a mocked `URLSession` without touching the network. Production code goes straight
through `Acervo.publishModel`. Lives in the CLI target so it does not expand the library's
public surface.

#### CredentialResolver.swift
Resolves `AcervoCDNCredentials` from environment variables (`R2_ACCESS_KEY_ID`,
`R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_PUBLIC_URL`, `R2_BUCKET`, `R2_REGION`).
Throws `AcervoToolError.missingEnvironmentVariable` on missing required variables.

#### ManifestGenerator.swift
Generates manifest.json:
- Scans staging directory
- Computes SHA-256 per file
- Computes manifest checksum (SHA-256-of-checksums)
- Writes manifest.json

#### ProcessRunner.swift
Runs external subprocesses (`hf download`) synchronously via `Process`. Captures stdout/stderr
and surfaces exit codes as `AcervoToolError.subprocessFailed` on non-zero exit.

#### HuggingFaceClient.swift
Downloads from HuggingFace:
- Fetches file list via HuggingFace API
- Downloads each file via `hf download`
- Verifies LFS pointers (CHECK 1)
- Reports progress

#### ToolCheck.swift
Validates required CLI tools:
- Checks if `hf` is on PATH
- Fails early with a Homebrew install hint if missing
- CDN operations use the library's native SigV4 path; no `aws` check

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
- **ManifestTests.swift** — Manifest parsing, validation

Run with: `make test` or `xcodebuild test -scheme SwiftAcervo-Package`

### CLI Unit Tests (`AcervoToolTests/`)

Unit tests for argument parsing and logic:

- **ArgumentParsingTests.swift** — Command parsing
- **ManifestGeneratorTests.swift** — Manifest generation
- **IntegrityCheckTests.swift** — All 6 checks
- **HuggingFaceClientTests.swift** — Mock downloads

Run with: `make test-acervo-unit`

### CDN Smoke (read-only, network, no credentials)

`CDNManifestFetchTests` (inside `AcervoToolTests`) fetches a known-published
manifest from the public R2 URL, verifies its checksum-of-checksums, and
spot-checks the smallest file's SHA-256 against the bytes on the wire. Runs in
PR CI to detect download-side regressions against live infrastructure.

Run with: `make test-acervo-cdn`

### Upload / ship pipeline testing

Historically tested by `AcervoToolIntegrationTests/`. **Removed** in favor of
per-repo upload CI: each downstream repository that publishes a model is
responsible for exercising `acervo ship` against its own credentials during
that repo's model-publish workflow. SwiftAcervo itself never uploads.

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
        .testTarget(name: "AcervoToolTests", dependencies: ["acervo"])
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
- **USAGE-library.md** — Integration guide for consuming libraries (start here!)
- **USAGE-library.md** — Complete method and type reference
- **USAGE-cli.md** — Building, testing, CI/CD
- **CDN_ARCHITECTURE.md** — How downloads work
- **USAGE-cli.md** — How to upload to R2
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

- **[USAGE-library.md](USAGE-library.md)** — All exported types and methods
- **[USAGE-cli.md](USAGE-cli.md)** — How to run tests
- **[USAGE-library.md](USAGE-library.md)** — Using the library
