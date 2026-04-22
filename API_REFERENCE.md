# API_REFERENCE.md — Complete Method and Type Documentation

**For**: Developers who need the complete reference of all available methods and types.

---

## Acervo (Static API)

Stateless namespace for model discovery and downloading. Safe to call from any thread.

### Path Resolution

| Method | Returns | Description |
|--------|---------|-------------|
| `sharedModelsDirectory` | `URL` | App Group container path + `SharedModels/` |
| `modelDirectory(for:)` | `URL` | Local directory URL for a model ID |
| `slugify(_:)` | `String` | Converts `org/repo` to `org_repo` |

### Availability

| Method | Returns | Description |
|--------|---------|-------------|
| `isModelAvailable(_:)` | `Bool` | `true` if model directory contains `config.json` |
| `modelFileExists(_:fileName:)` | `Bool` | `true` if specific file exists in model directory |

### Discovery

| Method | Returns | Description |
|--------|---------|-------------|
| `listModels()` | `[AcervoModel]` | All valid models, sorted alphabetically |
| `modelInfo(_:)` | `AcervoModel` | Metadata for a single model by ID |
| `findModels(matching:)` | `[AcervoModel]` | Case-insensitive substring search |
| `findModels(fuzzyMatching:editDistance:)` | `[AcervoModel]` | Levenshtein edit distance (default: 5) |
| `closestModel(to:editDistance:)` | `AcervoModel?` | Single best fuzzy match or `nil` |
| `modelFamilies()` | `[String: [AcervoModel]]` | Group models by base name family |

### Download

| Method | Throws | Description |
|--------|--------|-------------|
| `download(_:files:force:progress:)` | `AcervoError` | Download specified files from CDN with manifest verification |
| `ensureAvailable(_:files:progress:)` | `AcervoError` | Download only if model not already available |
| `deleteModel(_:)` | `AcervoError` | Remove a model directory from disk |

**Parameters**:
- `modelId` — Model identifier (e.g., `"mlx-community/Qwen2.5-7B-Instruct-4bit"`)
- `files` — Array of file paths to download (e.g., `["config.json", "model.safetensors"]`)
- `force` — If `true`, re-download even if already available (default: `false`)
- `progress` — Optional closure receiving `AcervoDownloadProgress` on each file completion

### Component Registry

| Method | Returns | Description |
|--------|---------|-------------|
| `register(_:)` | `Void` | Register a component descriptor (returns `Void`, side effect is registration) |
| `downloadComponent(_:force:progress:)` | `Void` | Download a registered component using registry file list |
| `ensureComponentReady(_:progress:)` | `Void` | Ensure component is downloaded and verified; auto-hydrates bare descriptors on first call |
| `verifyComponent(_:)` | `Void` | Verify component's files against SHA-256 checksums |
| `isComponentReady(_:)` | `Bool` | Sync readiness check. Returns `false` for un-hydrated descriptors (safe default — network fetch not possible sync). Use `isComponentReadyAsync(_:)` for accuracy on bare descriptors. |
| `isComponentReadyAsync(_:)` | `Bool` | Async readiness check; hydrates descriptor first if needed. Recommended for bare descriptors. Throws `AcervoError`. |
| `registeredComponents()` | `[ComponentDescriptor]` | List all registered component descriptors |
| `unhydratedComponents()` | `[String]` | Returns component IDs whose descriptors have no file list yet (require CDN hydration). Un-hydrated components are excluded from `pendingComponents()` and `totalCatalogSize()`. |

### Manifest API

| Method | Returns | Description |
|--------|---------|-------------|
| `hydrateComponent(_:)` | `Void` | Fetches CDN manifest for a registered component and populates its `files`, per-file sizes, SHA-256 hashes, and `estimatedSizeBytes`. Idempotent. Concurrent calls for the same ID coalesce into one network fetch. Throws `AcervoError.componentNotRegistered` if the component is not in the registry. |
| `fetchManifest(for:)` | `CDNManifest` | Returns the CDN manifest for the given component without hydrating the registry. Use this for custom catalogs, cache warmers, or CI verification tools that need manifest data but don't want to trigger downloads. |

### Migration

| Method | Returns | Description |
|--------|---------|-------------|
| `migrateFromLegacyPaths()` | `[AcervoModel]` | Move models from legacy cache paths to `sharedModelsDirectory` |

---

## AcervoManager (Actor)

Singleton actor wrapping the `Acervo` static API with per-model locking. Use when multiple concurrent operations target the same model.

**Access**: `AcervoManager.shared`

### Core Operations

| Method | Parameters | Throws | Description |
|--------|-----------|--------|-------------|
| `download(_:files:force:progress:)` | `modelId`, `files`, `force`, `progress` | `AcervoError` | Download with per-model serialization |
| `withModelAccess(_:perform:)` | `modelId`, closure | `AcervoError` | Exclusive access to model directory while holding lock |
| `clearCache()` | — | — | Clear URL cache |
| `preloadModels()` | — | `AcervoError` | Preload all model metadata into cache |

### Metrics

| Method | Returns | Description |
|--------|---------|-------------|
| `getDownloadCount(for:)` | `Int` | Number of times `download()` was called for a model |
| `getAccessCount(for:)` | `Int` | Number of times `withModelAccess()` was called for a model |
| `printStatisticsReport()` | `Void` | Print formatted usage statistics report |
| `resetStatistics()` | `Void` | Reset all counters |

### Local Path Access

| Method | Parameters | Throws | Description |
|--------|-----------|--------|-------------|
| `withLocalAccess(_:perform:)` | `url`, closure | `AcervoError` | Scoped access to caller-supplied local URL |

**Parameters**:
- `url` — Local file or directory URL (e.g., user-supplied LoRA adapter)
- `perform` — Closure receiving `LocalHandle` for path resolution

**Returns**: Value returned by closure

**Closure parameter**: `LocalHandle` with methods:
- `url(for: String) -> URL` — Resolve file by relative path
- `url(matching: String) -> URL` — Find first file matching suffix
- `urls(matching: String) -> [URL]` — List all files matching suffix
- `availableFiles() -> [String]` — List all file paths

---

## ModelDownloadManager

Standardized multi-model download orchestration for consuming libraries.

**Access**: `ModelDownloadManager.shared`

| Method | Parameters | Throws | Returns | Description |
|--------|-----------|--------|---------|-------------|
| `ensureModelsAvailable(_:progress:)` | `modelIds`, `progress` | `AcervoError` | `Void` | Download all specified models if not already available |
| `validateCanDownload(_:)` | `modelIds` | `AcervoError` | `Int64` | Check disk space and return total bytes needed |

**Progress callback** receives `ModelDownloadProgress`:
```swift
public struct ModelDownloadProgress: Sendable {
    public let model: String           // e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit"
    public let fraction: Double        // 0.0 to 1.0 cumulative progress
    public let bytesDownloaded: Int64  // Total bytes downloaded across all models
    public let bytesTotal: Int64       // Total bytes to download across all models
    public let currentFileName: String // e.g., "model.safetensors"
}
```

---

## Supporting Types

### AcervoModel

Model metadata struct. Conforms to `Identifiable`, `Codable`, `Sendable`.

```swift
struct AcervoModel {
    let id: String              // e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit"
    let path: URL               // Local filesystem directory
    let sizeBytes: Int64        // Total size of all files
    let downloadDate: Date      // Directory creation date
    let formattedSize: String   // Human-readable size (e.g., "4.4 GB")
    let slug: String            // Directory name form (e.g., "mlx-community_Qwen...")
    let baseName: String        // Model name with quantization/size suffixes stripped
    let familyName: String      // Organization + base name for grouping variants
    let files: [CDNFile]        // Available files from manifest
    let manifestChecksum: String // Integrity marker for the manifest
    let updatedAt: Date         // When model was last updated on CDN
}
```

**Methods**:
- `id: String` — Conforms to `Identifiable`

### CDNFile

Individual file in a model's manifest.

```swift
struct CDNFile {
    let path: String            // e.g., "config.json", "model.safetensors"
    let sizeBytes: Int64        // File size for progress estimation
    let sha256: String          // SHA-256 checksum for verification
}
```

### AcervoDownloadProgress

Download progress information. Conforms to `Sendable`.

```swift
struct AcervoDownloadProgress {
    let fileName: String        // Current file being downloaded
    let bytesDownloaded: Int64  // Bytes downloaded for current file
    let totalBytes: Int64?      // Expected total, or nil if unknown
    let fileIndex: Int          // Zero-based index in file list
    let totalFiles: Int         // Total files being downloaded
    let overallProgress: Double // Combined progress 0.0 to 1.0
}
```

### ComponentDescriptor

Declarative model component description. Conforms to `Sendable`, `Identifiable`.

```swift
struct ComponentDescriptor {
    let id: String                      // Unique component identifier
    let type: ComponentType             // .encoder, .backbone, .decoder, etc.
    let displayName: String             // Human-readable name
    let repoId: String                  // Origin repository identifier
    let files: [ComponentFile]          // Required files with optional checksums (nil for bare descriptors)
    let estimatedSizeBytes: Int64       // Total expected download size (0 until hydrated if not declared)
    let minimumMemoryBytes: Int64       // RAM needed to load
    let metadata: [String: String]      // Model-specific key-value pairs

    var isHydrated: Bool                // true if files have been populated (declared or manifest-fetched)
    var needsHydration: Bool            // true if no files declared and manifest not yet fetched (inverse of isHydrated)
}
```

**Initializers**:

- `init(id:type:displayName:repoId:files:estimatedSizeBytes:minimumMemoryBytes:metadata:)` — Full init with explicit file list. `isHydrated` is `true` immediately. Existing callers are unaffected.
- `init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)` — Bare init (v0.8.0+). Omits `files` and `estimatedSizeBytes`; these are populated from the CDN manifest on first `ensureComponentReady` or explicit `hydrateComponent` call. `isHydrated` is `false` until hydration completes.

### ComponentType

Enumeration classifying component functional role.

```swift
enum ComponentType {
    case encoder            // Text/image encoder
    case decoder            // Text/image decoder
    case backbone           // Core model (DIT, UNet, etc.)
    case languageModel      // LLM or TTS base model
    case vocoder            // Audio vocoder
    case tokenizer          // Tokenizer/vocab
    case custom(String)     // Plugin-defined type
}
```

### ComponentFile

Individual file within a component.

```swift
struct ComponentFile {
    let relativePath: String            // e.g., "model.safetensors" or "tokenizer/config.json"
    let expectedSizeBytes: Int64?       // nil if unknown
    let sha256: String?                 // nil to skip verification
}
```

### ComponentHandle

Opaque file access handle provided to `withComponentAccess(_:perform:)` closure.

**Methods**:
- `url(for: String) -> URL` — Resolve file by relative path
- `url(matching: String) -> URL` — Find first file matching suffix
- `urls(matching: String) -> [URL]` — List all files matching suffix
- `availableFiles() -> [String]` — List all file paths

**Important**: URLs are valid **only** within the closure scope. They become invalid after the closure returns.

### LocalHandle

File access handle for caller-supplied local paths (LoRA adapters, etc.).

**Methods** (same as `ComponentHandle`):
- `url(for: String) -> URL` — Resolve file by relative path
- `url(matching: String) -> URL` — Find first file matching suffix
- `urls(matching: String) -> [URL]` — List all files matching suffix
- `availableFiles() -> [String]` — List all file paths

---

## AcervoError

Error type conforming to `LocalizedError`, `Sendable`.

| Case | Description |
|------|-------------|
| `directoryCreationFailed(String)` | Failed to create model directory |
| `modelNotFound(String)` | Model ID does not exist on CDN |
| `downloadFailed(fileName:statusCode:)` | Network error during file download |
| `networkError(Error)` | URLSession network error |
| `modelAlreadyExists(String)` | Model directory already exists (when creating) |
| `migrationFailed(source:reason:)` | Failure during legacy path migration |
| `invalidModelId(String)` | Model ID format is invalid |
| `manifestDownloadFailed(statusCode:)` | CDN manifest unavailable |
| `manifestIntegrityFailed(expected:actual:)` | Manifest checksum mismatch |
| `integrityCheckFailed(file:expected:actual:)` | File SHA-256 mismatch |
| `downloadSizeMismatch(fileName:expected:actual:)` | File size mismatch |
| `fileNotInManifest(fileName:modelId:)` | Requested file not in CDN manifest |
| `localPathNotFound(url:)` | Caller-supplied local URL does not exist |
| `componentNotRegistered(String)` | Component ID not in registry |
| `componentNotDownloaded(String)` | Component files not yet downloaded |
| `componentFileNotFound(component:file:)` | Requested file not in component |
| `componentNotHydrated(id:)` | Component descriptor exists but has no file list; thrown from sync-only paths (e.g., `verifyComponent`) where hydration is not possible. Call `hydrateComponent` or `ensureComponentReady` first. |

All errors have `localizedDescription` for user-facing messages.

---

## Design Notes

### Concurrency

- **`Acervo` (static)**: Stateless, thread-safe via Foundation's `FileManager` and `URLSession`
- **`AcervoManager` (actor)**: Per-model locking — same model serialized, different models concurrent
- **Closures**: All closures must be `@Sendable` (Swift 6 strict concurrency)

### Integrity Verification

- **Per-file SHA-256**: Every downloaded file is verified against manifest
- **Manifest checksum**: Manifest itself is verified with SHA-256-of-checksums
- **Streaming verification**: 4MB chunked reads during download with incremental hashing
- **Atomic downloads**: Downloaded to temporary location, verified, then moved to destination

### Storage

- **Canonical path**: `<App Group Container>/SharedModels/{org}_{repo}/`
- **Validity marker**: Presence of `config.json` indicates a valid model
- **Slugification**: Model ID `org/repo` → directory name `org_repo`

### What's NOT Included

This library does NOT:
- Load or inference models (use MLX, Core ML, etc.)
- Manage disk quotas or cache eviction
- Download from sources other than the private CDN
- Support Swift versions below 6.2
- Support iOS below 26.0 or macOS below 26.0

---

## See Also

- **[USAGE.md](USAGE.md)** — Integration patterns and examples
- **[CDN_ARCHITECTURE.md](CDN_ARCHITECTURE.md)** — How downloads work internally
- **[DESIGN_PATTERNS.md](DESIGN_PATTERNS.md)** — Core architectural decisions
