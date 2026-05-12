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

---

## Bundle Components

A **bundle component** is any `ComponentDescriptor` whose `repoId` points to a CDN manifest that also covers files belonging to other components. The canonical example is `black-forest-labs/FLUX.2-klein-4B`, which ships a transformer, text encoder, and VAE inside a single HuggingFace/CDN repository under distinct subfolders — one manifest, many logical components.

SwiftAcervo treats this as a first-class supported shape. The registry keys on `id`, not `repoId`, so N distinct component IDs can all point at the same `repoId` without conflict.

### When to use the bundle pattern

Use bundle components when:

- A single CDN repo bundles multiple logical model components (transformer, encoder, VAE, tokenizer, etc.) inside subfolders.
- You want to download, verify, or delete each component independently — for example, to skip the VAE on devices with limited storage, or to replace only the text encoder without re-downloading the full repo.
- You are integrating a third-party bundled repo (e.g., from HuggingFace) where the upstream author chose one repo for all weights.

Stick with the per-component-manifest shape when each component lives in its own CDN repo. The PixArt components (`t5-xxl-encoder-int4`, `sdxl-vae-decoder-fp16`, `pixart-sigma-xl-dit-int4`) are a good example: three CDN repos, three independent manifests, three components. Either shape works with the same `register` / `ensureComponentReady` / `withComponentAccess` API — no special flag or type is needed.

### How to declare bundle descriptors

Register one `ComponentDescriptor` per logical component. Give each a unique `id`, share the same `repoId`, and declare the exact files each component needs.

**Important**: Bundle descriptors MUST use the explicit-files initializer `init(id:type:displayName:repoId:files:estimatedSizeBytes:minimumMemoryBytes:metadata:)`. Do NOT register a bundle component with the bare un-hydrated initializer — calling `hydrateComponent` on a bare bundle descriptor overwrites `files` with the full manifest, breaking the per-component file scope (**R1**).

```swift
// Three components, one repo, distinct file subsets
let transformer = ComponentDescriptor(
    id: "flux2-klein-4b-transformer",
    type: .backbone,
    displayName: "FLUX.2-klein-4B Transformer",
    repoId: "black-forest-labs/FLUX.2-klein-4B",
    files: [
        ComponentFile(relativePath: "transformer/model.safetensors",
                      expectedSizeBytes: 8_200_000_000,
                      sha256: "<sha256>"),
        ComponentFile(relativePath: "transformer/config.json",
                      expectedSizeBytes: 2_048,
                      sha256: "<sha256>"),
    ],
    estimatedSizeBytes: 8_200_002_048,
    minimumMemoryBytes: 8_000_000_000
)

let textEncoder = ComponentDescriptor(
    id: "flux2-klein-4b-text-encoder",
    type: .encoder,
    displayName: "FLUX.2-klein-4B Text Encoder",
    repoId: "black-forest-labs/FLUX.2-klein-4B",
    files: [
        ComponentFile(relativePath: "text_encoder/config.json",
                      expectedSizeBytes: 1_024,
                      sha256: "<sha256>"),
        ComponentFile(relativePath: "text_encoder/model.safetensors",
                      expectedSizeBytes: 1_340_000_000,
                      sha256: "<sha256>"),
    ],
    estimatedSizeBytes: 1_340_001_024,
    minimumMemoryBytes: 1_400_000_000
)

let vae = ComponentDescriptor(
    id: "flux2-klein-4b-vae",
    type: .decoder,
    displayName: "FLUX.2-klein-4B VAE",
    repoId: "black-forest-labs/FLUX.2-klein-4B",
    files: [
        ComponentFile(relativePath: "vae/config.json",
                      expectedSizeBytes: 512,
                      sha256: "<sha256>"),
        ComponentFile(relativePath: "vae/diffusion_pytorch_model.safetensors",
                      expectedSizeBytes: 335_000_000,
                      sha256: "<sha256>"),
    ],
    estimatedSizeBytes: 335_000_512,
    minimumMemoryBytes: 340_000_000
)

Acervo.register([transformer, textEncoder, vae])
```

All three components land on disk under the same slug directory:

```
<sharedModelsDirectory>/black-forest-labs_FLUX.2-klein-4B/
├── transformer/
│   ├── config.json
│   └── model.safetensors
├── text_encoder/
│   ├── config.json
│   └── model.safetensors
└── vae/
    ├── config.json
    └── diffusion_pytorch_model.safetensors
```

### Contract guarantees (R1–R6)

These guarantees hold for any bundle component `D` with an explicit `files` list, where `D.repoId` resolves to a CDN manifest covering a superset of those files:

**R1 (download scope)**: `ensureComponentReady("flux2-klein-4b-transformer")` downloads only the transformer's declared files. The text encoder and VAE files are never fetched unless their own components are ensured.

**R2 (access scope)**: `withComponentAccess("flux2-klein-4b-transformer") { handle in ... }` exposes only the transformer's declared files. `handle.availableFiles()` lists only `transformer/config.json` and `transformer/model.safetensors`. Subfolder structure is preserved — `handle.url(for: "transformer/model.safetensors")` resolves to the correct on-disk path. The sibling text encoder and VAE files are on disk but are not accessible through this handle.

**R3 (readiness scope)**: `isComponentReady("flux2-klein-4b-transformer")` returns `true` if and only if every file in the transformer's `files` list is present on disk with the expected size. Whether the text encoder or VAE files exist on disk is irrelevant — sibling readiness does not affect this component's readiness check.

**R4 (sibling-safe deletion)**: Calling `deleteComponent("flux2-klein-4b-transformer")` removes only the transformer's declared files. The text encoder and VAE files are untouched. If only one component has been deleted, `isComponentReady("flux2-klein-4b-text-encoder")` and `isComponentReady("flux2-klein-4b-vae")` continue to return `true`. The shared slug directory (`black-forest-labs_FLUX.2-klein-4B/`) is removed only after all bundle components have been deleted and it is empty.

**R5 (full manifest)**: `Acervo.fetchManifest(forComponent: "flux2-klein-4b-transformer")` returns the complete CDN manifest — including files for the text encoder, VAE, and any other components in the bundle. This is intentional: the manifest is the authoritative catalog; component file scoping is a consumer-side concern.

**R6 (registry canary)**: Registering `flux2-klein-4b-transformer`, `flux2-klein-4b-text-encoder`, and `flux2-klein-4b-vae` — all with the same `repoId` but different `id`s — never fires the re-register canary. The canary fires only when the same `id` is registered a second time with a different file list or repo, which signals a genuine descriptor conflict. Registering sibling bundle components is always silent.

### Caveats

- **Shared slug directory**: Components A, B, and C can all see each other's files on disk by navigating the slug directory directly. The `ComponentHandle` API enforces file scope for safe access; the `rootDirectoryURL` property on `ComponentHandle` exposes the raw shared directory and should be avoided in bundle scenarios unless you explicitly need cross-component paths.
- **No hydration for bundle descriptors**: The bare un-hydrated `ComponentDescriptor` initializer is not compatible with the bundle pattern (see note above). Always supply an explicit `files:` list.
- **`config.json` validity marker**: If none of the bundle components declare `config.json` at the repo root, `isModelAvailable` (the non-component API) will return `false` for the `repoId`. This is expected — `isModelAvailable` is for the non-component download path. Use `isComponentReady` for component-keyed checks.

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
