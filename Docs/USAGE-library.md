# SwiftAcervo — Library Reference

Manifest-driven shared AI model discovery, download, and verification for iOS 26.0+ and macOS 26.0+. Zero external dependencies (Foundation + CryptoKit only).

---

## Installation

### Swift Package Manager

Add SwiftAcervo to your `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v26), .iOS(.v26)],
    dependencies: [
        .package(
            url: "https://github.com/intrusive-memory/SwiftAcervo",
            branch: "main"
        ),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: ["SwiftAcervo"]
        ),
    ]
)
```

The current library version is `Acervo.version` (`"0.18.2"`).

### App Group Configuration (required)

All model storage resolves through a shared App Group container so every consumer app and library on the same device can find the same cached models. Configuration is required before any `Acervo` call that touches the filesystem.

**Resolution order** (from `Acervo+PathResolution.swift`):

1. `ACERVO_APP_GROUP_ID` environment variable — set in `~/.zprofile` for CLI tools and test runners:
   ```sh
   export ACERVO_APP_GROUP_ID=group.intrusive-memory.models
   ```
2. First entry of the `com.apple.security.application-groups` entitlement (macOS UI apps only — read via `SecTaskCopyValueForEntitlement`).
3. `fatalError` — no silent fallback.

**iOS**: The Security framework's `SecTaskCopyValueForEntitlement` is not public on iOS. iOS consumers **must** supply the group ID via the `ACERVO_APP_GROUP_ID` environment variable (set it in `main` before any SwiftAcervo call). The App Group entitlement (`com.apple.security.application-groups`) must still be granted to the iOS app target.

```swift
// iOS app entry point — must run before any Acervo call
setenv("ACERVO_APP_GROUP_ID", "group.com.mycompany.models", 1)
```

The environment variable name is exposed as `Acervo.appGroupEnvironmentVariable`.

---

## Concepts

**Manifest-driven.** Every model on the CDN publishes a `manifest.json` that lists every file, its SHA-256 checksum, and its byte size. Consumers never enumerate files locally; they pass the model ID and the library fetches the manifest to know what to download and verify. Files not listed in the manifest cannot be requested (`AcervoError.fileNotInManifest`).

**Shared models directory.** One on-disk location per App Group container — `~/Library/Group Containers/<group-id>/SharedModels/` on macOS, or the group container's `SharedModels/` subdirectory on iOS. Multiple consumer apps sharing the same App Group reuse the same cached models without re-downloading.

**`AcervoManager` actor.** The recommended entry point for app-level code. Provides per-model locking so concurrent calls for the same model serialize while calls for different models run in parallel. Access the singleton via `AcervoManager.shared`.

**Three-state availability.** The `availability(_:)` API returns `ModelAvailability`: `.available`, `.notAvailable`, `.downloading(progress:)`, or `.partial(missing: [String])`. The `.partial` case distinguishes "was downloaded, one shard is now missing" from "never downloaded." The synchronous `isModelAvailable(_:)` returns a strict `Bool` suitable for fast-path guards but cannot report the `.downloading` or `.partial` states.

**Slug-keyed vs repo-keyed APIs.** Most APIs come in two flavors:

- **Repo-keyed** — `(_ modelId: "org/repo")`: resolves a single HuggingFace-style model identifier directly.
- **Slug-keyed** — `(slug: "my-bundle-name", url: ...)`: resolves a multi-component bundle. A slug may look like `"org/repo"` (URL is derived automatically) or be an opaque string (explicit `url:` required). The library fetches the slug's manifest to discover the component list, then fans out per-component.

---

## Quick Start

```swift
import SwiftAcervo

func loadModel() async throws -> URL {
    let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    // 1. Check current availability (three-state, non-locking)
    let state = await AcervoManager.shared.availability(modelId)
    guard state != .available else {
        return try Acervo.modelDirectory(for: modelId)
    }

    // 2. Download everything in the manifest (files: [] = all files)
    try await Acervo.ensureAvailable(modelId, files: [])

    // 3. Return the resolved directory
    return try Acervo.modelDirectory(for: modelId)
}
```

---

## Public API Surface

### 1 · Path Resolution (`Acervo+PathResolution.swift`)

Resolves App Group containers, slugifies model IDs, and locates model directories. These are the leaf-level helpers that every other subsystem depends on.

---

#### `Acervo.appGroupEnvironmentVariable`

```swift
public static let appGroupEnvironmentVariable: String  // "ACERVO_APP_GROUP_ID"
```

The environment variable name that CLI tools and test runners use to supply the App Group identifier. Exposed so consumers can reference it symbolically rather than embedding the string literal.

---

#### `Acervo.sharedModelsDirectory`

```swift
public static var sharedModelsDirectory: URL { get }
```

The canonical base directory for all shared AI models. Same path for every consumer once the App Group identifier is configured. Calls `fatalError` when neither the environment variable nor the entitlement is set.

```swift
let base = Acervo.sharedModelsDirectory
// macOS: ~/Library/Group Containers/group.intrusive-memory.models/SharedModels/
```

---

#### `Acervo.slugify(_:)`

```swift
public static func slugify(_ modelId: String) -> String
```

Converts an `"org/repo"` model ID to a filesystem-safe directory name by replacing all `/` characters with `_`.

```swift
let slug = Acervo.slugify("mlx-community/Qwen2.5-7B-Instruct-4bit")
// "mlx-community_Qwen2.5-7B-Instruct-4bit"
```

---

#### `Acervo.modelDirectory(for:)`

```swift
public static func modelDirectory(for modelId: String) throws -> URL
```

Returns the local filesystem directory for the given model ID. Throws `AcervoError.invalidModelId` if the ID does not contain exactly one `/`. Does not create the directory or verify it exists.

```swift
let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
// <sharedModelsDirectory>/mlx-community_Qwen2.5-7B-Instruct-4bit/
```

---

#### `Acervo.ensureModelDirectory(for:)`

```swift
@discardableResult
public static func ensureModelDirectory(for modelId: String) throws -> URL
```

Like `modelDirectory(for:)`, but creates the directory (and all intermediate directories) if it does not already exist. Use when a side-loading workflow needs to write into the canonical location without triggering a CDN download.

```swift
let dir = try Acervo.ensureModelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
// Directory now exists on disk.
```

---

### 2 · Availability (`Acervo+Availability.swift`)

Three-state async availability and the legacy synchronous probes.

---

#### `Acervo.availability(_:verifyHashes:)`

```swift
public static func availability(
    _ modelId: String,
    verifyHashes: Bool = false
) async -> ModelAvailability
```

The canonical "is the model usable right now?" API. Runs through a three-tier validity oracle without performing any downloads:

- **Tier A** — local `manifest.json` (byte-equal) or legacy `.acervo-manifest.json` cache.
- **Tier B** — in-memory CDN manifest cache (populated by `availability(slug:url:)` or `ensureAvailable(slug:url:)`).
- **Tier C** — heuristic: `config.json` or `model_index.json` present **and** every shard enumerated in `model.safetensors.index.json`'s `weight_map` is on disk.

Consults the in-flight registry first — a download in progress always returns `.downloading(progress:)`.

When `verifyHashes: true`, stream-SHA-256s every manifest file after the presence-and-size pass. Cost is proportional to total bytes on disk; reserve for explicit bit-rot audits, not interactive UI.

Never throws. Never performs network I/O.

```swift
switch await Acervo.availability("mlx-community/Qwen2.5-7B-Instruct-4bit") {
case .available:
    print("Ready")
case .downloading(let p):
    print("In progress: \(Int(p * 100))%")
case .partial(let missing):
    print("Missing: \(missing)")
case .notAvailable:
    print("Not downloaded")
}
```

---

#### `Acervo.isModelAvailable(_:)`

```swift
public static func isModelAvailable(_ modelId: String) -> Bool
```

Strict, offline, synchronous availability check. Loads the cached manifest, verifies every declared file is on disk at the recorded byte size. Returns `false` for partial downloads or missing manifests. Does not distinguish `.downloading` or `.partial` from `.notAvailable`. Prefer `availability(_:)` for UI; use this in fast-path guards inside `ensureAvailable` flows.

---

#### `Acervo.isModelConfigPresent(_:)`

```swift
public static func isModelConfigPresent(_ modelId: String) -> Bool
```

Loose probe: returns `true` when `config.json` exists at the model root. **Does not imply "model is usable."** A directory with only `config.json` (partial download) satisfies this probe. Use as an explicit escape hatch for legacy integrations; prefer `availability(_:)` in all new code.

---

#### `Acervo.modelFileExists(_:fileName:)`

```swift
public static func modelFileExists(_ modelId: String, fileName: String) -> Bool
```

Checks whether a specific file exists within the model's directory. Supports subdirectory paths (e.g., `"speech_tokenizer/config.json"`). Never throws.

```swift
let hasTokenizer = Acervo.modelFileExists(
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
    fileName: "speech_tokenizer/config.json"
)
```

---

### 3 · EnsureAvailable (`Acervo+EnsureAvailable.swift`)

Download-if-necessary APIs. These are the primary action-side entry points.

---

#### `Acervo.ensureAvailable(_:files:progress:telemetry:)`

```swift
public static func ensureAvailable(
    _ modelId: String,
    files: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Ensures a model is available locally, downloading it if necessary. Returns immediately (fast path) when the cached manifest is present and every declared file is on disk at the recorded size.

**Download deduplication.** Uses a process-wide in-flight registry (`InFlightDownloads`). Concurrent calls for the same `modelId` coalesce into a single underlying download Task — the work is performed exactly once. Both callers receive the same outcome. The dedup key is `modelId`, not `(modelId, files)`: a joiner requesting a subset of files rides on the originator's download.

Pass `files: []` to download every file in the manifest (the overwhelmingly common case).

```swift
try await Acervo.ensureAvailable(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: [],
    progress: { p in
        print("\(p.fileName): \(Int(p.overallProgress * 100))%")
    }
)
```

---

#### `Acervo.ensureAvailable(slug:url:files:progress:telemetry:)`

```swift
public static func ensureAvailable(
    slug: String,
    url: URL? = nil,
    files: [String],
    progress: (@Sendable (ModelAvailability) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Slug-keyed multi-component variant. Fetches the slug's manifest, iterates over every `manifest.components` entry sequentially, and calls the repo-keyed `ensureAvailable` for each. The `progress` callback receives a bytes-weighted `ModelAvailability` aggregate across all components.

URL resolution rule:
- `url` supplied → used verbatim as the manifest fetch URL.
- `url` nil + slug parses as `"org/repo"` → CDN URL is derived automatically.
- `url` nil + slug is opaque → throws `AcervoError.urlRequiredForSlug`.

```swift
// HF-style slug — URL derived automatically
try await Acervo.ensureAvailable(
    slug: "black-forest-labs/FLUX.2-klein-4B",
    files: [],
    progress: { aggregate in
        if case .downloading(let p) = aggregate {
            print("Overall: \(Int(p * 100))%")
        }
    }
)
```

---

### 4 · Discovery (`Acervo+Discovery.swift`)

List and inspect models that are already in the shared models directory.

---

#### `Acervo.listModels()`

```swift
public static func listModels() throws -> [AcervoModel]
```

Scans `sharedModelsDirectory` for subdirectories containing at least one validity marker (`config.json`, `model_index.json`, or `manifest.json`). Returns them sorted alphabetically by model ID. Directories without any validity marker are excluded (stub directories from cancelled downloads); use `gcEmptyModelDirectories()` to remove them.

```swift
let models = try Acervo.listModels()
for model in models {
    print("\(model.id): \(model.formattedSize)")
}
```

---

#### `Acervo.modelInfo(_:)`

```swift
public static func modelInfo(_ modelId: String) throws -> AcervoModel
```

Returns metadata for a single model. Throws `AcervoError.modelNotFound` if the model is not in the shared models directory.

```swift
let model = try Acervo.modelInfo("mlx-community/Qwen2.5-7B-Instruct-4bit")
print("Downloaded: \(model.downloadDate), Size: \(model.formattedSize)")
```

---

#### `Acervo.modelFamilies()`

```swift
public static func modelFamilies() throws -> [String: [AcervoModel]]
```

Groups all discovered models by their `AcervoModel.familyName` (org + base model name with quantization/size/variant suffixes stripped). Models within each family are sorted alphabetically.

```swift
let families = try Acervo.modelFamilies()
for (family, variants) in families.sorted(by: { $0.key < $1.key }) {
    print("\(family): \(variants.count) variant(s)")
}
```

---

#### `Acervo.gcEmptyModelDirectories()`

```swift
@discardableResult
public static func gcEmptyModelDirectories() throws -> [URL]
```

**Destructive.** Physically removes stub directories — those with none of the three validity markers. Directories with at least one marker are left untouched. Per-directory removal is atomic; unremovable directories are silently skipped and not included in the returned list.

```swift
let removed = try Acervo.gcEmptyModelDirectories()
print("Cleaned up \(removed.count) stubs")
```

---

### 5 · Search (`Acervo+Search.swift`)

Find models by substring pattern or fuzzy edit-distance.

---

#### `Acervo.findModels(matching:)`

```swift
public static func findModels(matching pattern: String) throws -> [AcervoModel]
```

Case-insensitive substring search across all model IDs in `sharedModelsDirectory`. Returns matching models sorted alphabetically.

```swift
let qwenModels = try Acervo.findModels(matching: "Qwen")
```

---

#### `Acervo.findModels(fuzzyMatching:editDistance:)`

```swift
public static func findModels(
    fuzzyMatching query: String,
    editDistance threshold: Int = 5
) throws -> [AcervoModel]
```

Levenshtein edit-distance search. Common organization prefixes (e.g., `"mlx-community/"`) are stripped from both the query and each model ID before computing distance, so `"Qwen2.5-7B"` matches `"mlx-community/Qwen2.5-7B-Instruct-4bit"` without the prefix inflating the distance. Results are sorted by distance (closest first), then alphabetically for ties.

```swift
let matches = try Acervo.findModels(fuzzyMatching: "Qwen2.5-7B", editDistance: 10)
```

---

#### `Acervo.closestModel(to:editDistance:)`

```swift
public static func closestModel(
    to query: String,
    editDistance threshold: Int = 5
) throws -> AcervoModel?
```

Convenience wrapper over `findModels(fuzzyMatching:editDistance:)` that returns only the closest result. Returns `nil` when no model is within `threshold`. Useful for "did you mean...?" suggestions.

```swift
if let closest = try Acervo.closestModel(to: "Qwen2.5-7B-Instruct") {
    print("Did you mean: \(closest.id)?")
}
```

---

### 6 · Download (`Acervo+Download.swift`)

Explicit-file download API. For most consumers, `ensureAvailable` is the right choice; `download` is the lower-level building block it delegates to.

---

#### `Acervo.download(_:files:force:progress:telemetry:)`

```swift
public static func download(
    _ modelId: String,
    files: [String],
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Downloads specific files for a model. Validates the model ID, fetches the CDN manifest, creates the model directory, then downloads and SHA-256-verifies each file. Files already on disk at the manifest-declared size are skipped unless `force: true`. Pass `files: []` to download everything declared in the manifest.

```swift
try await Acervo.download(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    files: ["config.json", "tokenizer.json"],
    progress: { p in print("Progress: \(p.overallProgress)") }
)
```

---

### 7 · DeleteModel (`Acervo+DeleteModel.swift`)

Local-disk deletion (not CDN deletion — see CDN Mutation for the remote side).

---

#### `Acervo.deleteModel(_:telemetry:)`

```swift
public static func deleteModel(
    _ modelId: String,
    telemetry: (any AcervoTelemetryReporter)? = nil
) throws
```

Removes a model's directory from `sharedModelsDirectory` recursively. Throws `AcervoError.invalidModelId` for malformed IDs, `AcervoError.modelNotFound` if the directory does not exist.

```swift
try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")
```

---

#### `Acervo.deleteModel(slug:url:)`

```swift
public static func deleteModel(slug: String, url: URL? = nil) async throws
```

Slug-keyed variant. Fetches the slug's manifest to discover the component list, then removes each component's on-disk folder. Missing component folders are treated as no-op success. Throws `AcervoError.manifestFetchFailed` when the manifest cannot be retrieved (without the manifest, the library cannot know what to delete).

URL resolution rule mirrors `availability(slug:url:)`.

```swift
// HF-style slug — URL derived automatically
try await Acervo.deleteModel(slug: "black-forest-labs/FLUX.2-klein-4B")

// Opaque slug — explicit manifest URL required
try await Acervo.deleteModel(
    slug: "flux2-klein-4b",
    url: URL(string: "https://cdn.example/flux2-klein-4b/manifest.json")!
)
```

---

### 8 · Manifest Access (`Acervo+ManifestAccess.swift`)

Raw manifest fetch without triggering downloads. Useful for CI tools, cache warmers, or custom catalog code.

---

#### `Acervo.fetchManifest(for:)`

```swift
public static func fetchManifest(for modelId: String) async throws -> CDNManifest
public static func fetchManifest(for modelId: String, session: URLSession) async throws -> CDNManifest
```

Fetches and validates the CDN manifest for a model by its `"org/repo"` identifier. The second overload accepts an injected `URLSession` (primarily for testing via `MockURLProtocol`). Throws `AcervoError.manifestModelIdMismatch` if the server returns a manifest whose `modelId` does not match the request.

```swift
let manifest = try await Acervo.fetchManifest(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
print("Files: \(manifest.files.count), Total: \(manifest.files.map(\.sizeBytes).reduce(0, +)) bytes")
```

---

#### `Acervo.fetchManifest(forComponent:)`

```swift
public static func fetchManifest(forComponent componentId: String) async throws -> CDNManifest
public static func fetchManifest(forComponent componentId: String, session: URLSession) async throws -> CDNManifest
```

Registry-aware counterpart. Looks up the component's `repoId` in `ComponentRegistry.shared`, then calls `fetchManifest(for:)`. Does not hydrate or mutate the registry. Throws `AcervoError.componentNotRegistered` if `componentId` is not registered.

---

### 9 · Component Registration (`Acervo+ComponentRegistration.swift`)

Declare reusable model components in the global registry.

---

#### `Acervo.register(_:)` (single)

```swift
public static func register(_ descriptor: ComponentDescriptor)
```

Registers a component descriptor. Idempotent: re-registering the same ID updates the entry. If the same `id` is registered with a different `repoId` or `files`, a warning is logged and the last registration wins. Metadata dictionaries are merged (newer keys overwrite on conflict). `estimatedSizeBytes` and `minimumMemoryBytes` take the max of both values. Thread-safe.

```swift
Acervo.register(ComponentDescriptor(
    id: "t5-xxl-encoder-int4",
    type: .encoder,
    displayName: "T5-XXL Text Encoder (int4)",
    repoId: "intrusive-memory/t5-xxl-int4-mlx",
    files: [ComponentFile(relativePath: "model.safetensors")],
    estimatedSizeBytes: 1_200_000_000,
    minimumMemoryBytes: 2_400_000_000
))
```

---

#### `Acervo.register(_:)` (batch)

```swift
public static func register(_ descriptors: [ComponentDescriptor])
```

Registers multiple descriptors at once. Each is processed individually with the same deduplication rules as the single-descriptor overload.

---

#### `Acervo.unregister(_:)`

```swift
public static func unregister(_ componentId: String)
```

Removes a component registration by ID. Does **not** delete downloaded files; the component simply stops appearing in catalog queries. No-op if the ID is not registered.

---

### 10 · Component Catalog (`Acervo+ComponentCatalog.swift`)

Query registered components and their download/hydration status.

---

#### `Acervo.registeredComponents()`

```swift
public static func registeredComponents() -> [ComponentDescriptor]
```

Returns all registered descriptors (downloaded or not), in no particular order.

---

#### `Acervo.registeredComponents(ofType:)`

```swift
public static func registeredComponents(ofType type: ComponentType) -> [ComponentDescriptor]
```

Returns all registered descriptors filtered by `ComponentType`.

---

#### `Acervo.component(_:)`

```swift
public static func component(_ id: String) -> ComponentDescriptor?
```

Looks up a specific component by its ID. Returns `nil` if not registered.

---

#### `Acervo.isComponentReady(_:)`

```swift
public static func isComponentReady(_ id: String) -> Bool
```

Synchronous check: returns `true` when the component is registered, hydrated, and all declared files are on disk at the expected sizes. Returns `false` for un-hydrated descriptors (call `hydrateComponent` first, or use the async `isComponentReadyAsync`).

---

#### `Acervo.isComponentReadyAsync(_:)`

```swift
public static func isComponentReadyAsync(_ id: String) async throws -> Bool
```

Async variant that auto-hydrates un-hydrated descriptors before checking. Throws `AcervoError.componentNotRegistered` if the ID is unknown.

---

#### `Acervo.pendingComponents()`

```swift
public static func pendingComponents() -> [ComponentDescriptor]
```

Returns all registered, hydrated components for which `isComponentReady` returns `false`. Un-hydrated components are excluded (their file list is unknown). Use `unhydratedComponents()` to enumerate those separately.

---

#### `Acervo.totalCatalogSize()`

```swift
public static func totalCatalogSize() -> (downloaded: Int64, pending: Int64)
```

Sums `estimatedSizeBytes` for all hydrated components, split into downloaded vs. pending. Un-hydrated components are excluded.

```swift
let (done, pending) = Acervo.totalCatalogSize()
print("\(done / (1024 * 1024 * 1024)) GB cached, \(pending / (1024 * 1024 * 1024)) GB pending")
```

---

#### `Acervo.unhydratedComponents()`

```swift
public static func unhydratedComponents() -> [String]
```

Returns component IDs for all registered components whose file list has not yet been populated from the CDN manifest.

---

### 11 · Component Downloads (`Acervo+ComponentDownloads.swift`)

Download and delete registered components by their registry ID.

---

#### `Acervo.downloadComponent(_:force:progress:telemetry:)`

```swift
public static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Downloads a registered component using the registry's file list and CDN manifest SHA-256 checksums. Auto-hydrates un-hydrated descriptors before downloading. Applies both CDN-level (manifest-driven) and registry-level (descriptor SHA) integrity verification. Throws `AcervoError.componentNotRegistered` or `AcervoError.integrityCheckFailed`.

---

#### `Acervo.ensureComponentReady(_:progress:telemetry:)`

```swift
public static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Idempotent: returns immediately if the component is already on disk and passes `isComponentReady`. Otherwise auto-hydrates the descriptor (if needed) and downloads missing files.

---

#### `Acervo.ensureComponentsReady(_:progress:telemetry:)`

```swift
public static func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Iterates through `componentIds` and calls `ensureComponentReady` for each. Already-cached components are skipped.

---

#### `Acervo.deleteComponent(_:)`

```swift
public static func deleteComponent(_ componentId: String) throws
```

Removes only the files declared in this descriptor from the component's directory. Does **not** unregister the component — it remains in the registry as "not downloaded." Removes empty parent subdirectories after file deletion. If the component directory is now empty, removes it too. Does not throw for files that do not exist (no-op for those).

---

### 12 · Component Integrity (`Acervo+ComponentIntegrity.swift`)

Post-download SHA-256 verification of registered components.

---

#### `Acervo.verifyComponent(_:)`

```swift
public static func verifyComponent(_ componentId: String) throws -> Bool
```

Verifies the SHA-256 checksums of all files in the component's descriptor that have a declared `sha256`. Files without a declared checksum are skipped. Returns `true` when all checksums pass (or none are declared). Throws `AcervoError.componentNotRegistered`, `AcervoError.componentNotHydrated`, or `AcervoError.componentNotDownloaded`.

---

#### `Acervo.verifyAllComponents()`

```swift
public static func verifyAllComponents() throws -> [String]
```

Iterates over all registered components. Skips components that are not downloaded. Returns the IDs of any downloaded components that fail checksum verification. An empty array means all pass.

```swift
let failures = try Acervo.verifyAllComponents()
if !failures.isEmpty {
    print("Integrity failures: \(failures.joined(separator: ", "))")
}
```

---

### 13 · Hydration (`Acervo+Hydration.swift`)

Lazy descriptor population from the CDN manifest. Required before most operations on un-hydrated components.

---

#### `Acervo.hydrateComponent(_:telemetry:)`

```swift
public static func hydrateComponent(
    _ componentId: String,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Fetches the CDN manifest for the component's `repoId` and rebuilds the descriptor with a full file list (`files`, `estimatedSizeBytes`). Concurrent calls for the same `componentId` coalesce into a single network fetch via `HydrationCoalescer`. A later call after completion re-fetches, so CDN manifest updates between app launches are picked up.

**Warning:** Do not call `hydrateComponent` on bundle-pattern descriptors — descriptors where multiple components share a `repoId`, each owning a declared file subset. Hydration replaces `files` with the full manifest, breaking per-component file scope. Bundle descriptors must be registered using the explicit `files:` initializer and left pre-hydrated.

```swift
try await Acervo.hydrateComponent("t5-xxl-encoder-int4")
// descriptor now has a populated file list
```

Throws `AcervoError.componentNotRegistered` if the ID is unknown.

---

### 14 · Slug Availability (`Acervo+SlugAvailability.swift`)

Three-state availability for multi-component slug-keyed models. Unlike the repo-keyed `availability(_:)`, this method is async and performs a network fetch when the manifest is not cached.

---

#### `Acervo.availability(slug:url:telemetry:)`

```swift
public static func availability(
    slug: String,
    url: URL? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws -> ModelAvailability
```

Fetches the slug's manifest (from the in-memory `ManifestCache` if cached, otherwise from the network), then fans out across every `manifest.components` entry using the offline repo-keyed `availability(_:)` for each. Aggregates component states via `AvailabilityAggregator`:

- All components `.available` → `.available`
- Any component `.downloading` → `.downloading(weightedAverageProgress)` (weighted by each component's total bytes)
- Otherwise → `.notAvailable`

Emits exactly one `AcervoTelemetryEvent.modelAvailabilityResolved` per call.

URL resolution rule mirrors `ensureAvailable(slug:url:)`.

```swift
let state = try await Acervo.availability(
    slug: "black-forest-labs/FLUX.2-klein-4B"
)
```

Throws: `AcervoError.urlRequiredForSlug`, `AcervoError.manifestFetchFailed`, `AcervoError.networkError`, `AcervoError.manifestDecodingFailed`.

---

### 15 · CDN Mutation (`Acervo+CDNMutation.swift`)

**Operator-side APIs** for publishing, deleting, and recaching models on the private R2 CDN. These are used by the `acervo` CLI and CI/CD workflows, not by model consumers.

---

#### `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:telemetry:primaryRepo:components:slugOverride:)`

```swift
@discardableResult
public static func publishModel(
    modelId: String,
    directory: URL,
    credentials: AcervoCDNCredentials,
    keepOrphans: Bool = false,
    progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    primaryRepo: String? = nil,
    components: [String]? = nil,
    slugOverride: String? = nil
) async throws -> CDNManifest
```

Atomically publishes a locally-staged model directory to the CDN in an 11-step pipeline. The manifest is PUT last so the CDN never serves an internally inconsistent view. Post-upload verification (CHECKs 5 and 6) fetches the manifest and a sample file from the public URL. Orphan keys (prior-version files no longer in the new manifest) are deleted unless `keepOrphans: true`.

Throws `AcervoError.publishVerificationFailed(stage:)` on post-upload check failures, `AcervoError.publishOrphanPruneFailed(failedKeys:publishedManifest:)` when orphan prune partially fails (the new manifest is already live; the published manifest is returned in the error payload so the caller can surface success-with-warnings semantics).

> **Note (`consumers` field).** The manifest schema includes a `consumers: [CDNManifestConsumer]` field (see [Supporting Types → `CDNManifestConsumer`](#cdnmanifestconsumer)), but `publishModel` does **not** yet accept a `consumers:` parameter — it currently emits `consumers: []` on every publish. Wiring a producer-side API onto `publishModel` (and `recache`) is tracked separately. Until then, the field is consumer-readable but not producer-settable through the public library surface.

---

#### `Acervo.deleteFromCDN(modelId:credentials:progress:telemetry:)`

```swift
public static func deleteFromCDN(
    modelId: String,
    credentials: AcervoCDNCredentials,
    progress: (@Sendable (AcervoDeleteProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
) async throws
```

Removes every object under `models/<slug>/` from the CDN. Non-atomic by design (there is nothing to be consistent with after a delete). Idempotent: no-op when the prefix is already empty. Loops list/delete/re-list until the prefix is empty.

---

#### `Acervo.recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:)`

```swift
@discardableResult
public static func recache(
    modelId: String,
    stagingDirectory: URL,
    credentials: AcervoCDNCredentials,
    fetchSource: @Sendable (_ modelId: String, _ into: URL) async throws -> Void,
    keepOrphans: Bool = false,
    progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil
) async throws -> CDNManifest
```

Convenience over `publishModel`: the caller-supplied `fetchSource` closure populates `stagingDirectory` with model files, then the populated directory is handed to `publishModel` for the atomic publish and orphan prune. The library is agnostic to where bytes come from — supply your own closure for git, S3, a tarball, etc. For the common "refetch from HuggingFace" case use `recacheFromHuggingFace` (below), which pre-wires the native fetch. Throws `AcervoError.fetchSourceFailed(modelId:underlying:)` if the fetch closure throws.

#### `Acervo.recacheFromHuggingFace(modelId:stagingDirectory:credentials:slug:files:revision:keepOrphans:progress:)`

```swift
@discardableResult
public static func recacheFromHuggingFace(
    modelId: String,
    stagingDirectory: URL,
    credentials: AcervoCDNCredentials,
    slug: String? = nil,
    files: [String] = [],
    revision: String = "main",
    keepOrphans: Bool = false,
    progress: (@Sendable (AcervoPublishProgress) -> Void)? = nil
) async throws -> CDNManifest
```

The turnkey **refetch-from-source** path. Fetches `modelId` directly from HuggingFace via the native [`HuggingFaceClient`](#16--huggingface-source-fetch-huggingfaceclientswift) (no Python `hf` CLI, no `hf_xet` — works on iOS and macOS), then publishes to the CDN via `publishModel`. The download is self-verifying: every file's on-disk size must match HuggingFace's tree record before promotion, which is the native guard against the silent-incomplete (Xet-pointer-only) failure mode. A fetch failure surfaces as `AcervoError.fetchSourceFailed(modelId:underlying:)`.

One HF repo → one CDN slug, which covers both packaging shapes:

- **Flux2 (N:1 bundle).** `black-forest-labs/FLUX.2-klein-4B` is a single repo bundling transformer + text_encoder + tokenizer + vae + scheduler in subfolders. One call mirrors the whole bundle. Because the HF id differs from the published slug, pass `slug: "flux2-klein-4b"`. To mirror a single logical component, pass its subfolder paths via `files:`.
- **PixArt (1:1 per-component).** The T5 encoder, DiT backbone, and SDXL VAE each live in their own repo. Make one call per repo.

```swift
// Flux2: bundled repo, renamed slug
try await Acervo.recacheFromHuggingFace(
    modelId: "black-forest-labs/FLUX.2-klein-4B",
    stagingDirectory: staging,
    credentials: creds,
    slug: "flux2-klein-4b"
)

// PixArt: one call per component repo
for repo in ["intrusive-memory/t5-xxl-encoder-int4-mlx",
             "intrusive-memory/pixart-sigma-xl-dit-int4-mlx",
             "intrusive-memory/sdxl-vae-decoder-fp16-mlx"] {
    try await Acervo.recacheFromHuggingFace(
        modelId: repo, stagingDirectory: staging.appendingPathComponent(repo), credentials: creds)
}
```

> **Slug rename matters for Flux2.** When `slug` is `nil` the CDN key is derived from `modelId` (`org_repo`). The Flux2 upstream id (`black-forest-labs/FLUX.2-klein-4B`) is *not* the published slug (`flux2-klein-4b`), so omitting `slug:` would publish under the wrong key. PixArt components are already published under their HF-derived names, so they don't need it.

---

### 16 · HuggingFace Source Fetch (`HuggingFaceClient.swift`)

`HuggingFaceClient` is a standalone `actor` (not part of `Acervo`) that talks to HuggingFace's public API. It backs `recacheFromHuggingFace` but is usable directly when you need the pieces. It carries **zero dependencies beyond Foundation** and never shells out — the only network surface is `huggingface.co`. An `HF_TOKEN` environment variable, when set, is attached as a bearer token for gated/private repos (its value is never logged).

```swift
public init(
    session: URLSession? = nil,
    apiBase: URL = URL(string: "https://huggingface.co/api/models")!,
    resolveBase: URL = URL(string: "https://huggingface.co")!
)
```

#### `downloadRepo(modelId:into:files:revision:)`

```swift
public func downloadRepo(
    modelId: String,
    into destination: URL,
    files requestedFiles: [String] = [],
    revision: String = "main"
) async throws
```

Streams every file (or the `files:` subset) for `modelId` from HuggingFace's `resolve` endpoint into `destination`, reproducing the repo's directory layout. The `resolve` endpoint serves the **complete** bytes for inline, classic-LFS, and Xet-backed files alike, so no `hf_xet`/Python runtime is needed; the trade-off is no chunk-level dedup, so large blobs transfer in full. Files are written to `<path>.part` and atomically moved into place only after the on-disk size matches HuggingFace's tree record — a mismatch throws `HFDownloadError.sizeMismatch`. Names absent from the tree are ignored.

#### `fetchRepoFiles(modelId:)` / `fetchRepoFiles(modelId:revision:)`

```swift
public func fetchRepoFiles(modelId: String) async throws -> [HFTreeFile]
public func fetchRepoFiles(modelId: String, revision: String) async throws -> [HFTreeFile]
```

Lists every file in the repo with its size and Xet status. The no-revision overload tries `main` then falls back to `master`, following HF's `Link: rel="next"` pagination so repos with more than 50 entries return complete results. Throws `HFTreeError` on non-2xx responses or malformed JSON.

#### `verifyLFS(modelId:filename:actualSHA256:stagingURL:)`

```swift
public func verifyLFS(
    modelId: String, filename: String, actualSHA256: String, stagingURL: URL
) async throws
```

Compares a locally-computed SHA-256 against the `oid` HuggingFace advertises for an LFS-backed file. On mismatch it deletes `stagingURL` and throws `HFIntegrityError.checksumMismatch`. Note: non-LFS files (and most Xet repos) return HTTP 404 here — see `LFSVerificationHints.notLFSBackedHint` for how to interpret an all-404 sweep.

#### `verifyDownloadCompleteness(modelId:stagingURL:requestedFiles:)`

```swift
public func verifyDownloadCompleteness(
    modelId: String, stagingURL: URL, requestedFiles: [String]
) async throws -> [HFCompletenessFailure]
```

Walks a staging directory and reports every file whose on-disk size diverges from HuggingFace's tree listing. An empty result means the staging directory is consistent with HF and safe to promote. This is the size-based completeness gate, independent of LFS SHA-256 verification.

**Supporting types:** `HFTreeFile` (`path`, `size`, `isXet`), `HFCompletenessFailure` (`path`, `reason`, `isXet`), and the error enums `HFTreeError`, `HFIntegrityError`, `HFDownloadError`, plus the `LFSVerificationHints` namespace.

---

## AcervoManager (Actor Surface)

`AcervoManager` is the recommended thread-safe entry point for app-level code. It wraps the static `Acervo` API with per-model locking: concurrent operations for the same model serialize (via a polling lock that suspends 50 ms between attempts), while operations for different models run in parallel. Access the singleton via `AcervoManager.shared`.

### `AcervoManager.shared`

```swift
public static let shared: AcervoManager
```

The process-wide singleton. All actor methods must be `await`ed.

### Telemetry

#### `setTelemetry(_:)`

```swift
public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)
```

Attaches or removes a telemetry reporter. Pass `nil` to stop telemetry. Reporter is called from actor isolation.

#### `currentTelemetry`

```swift
public var currentTelemetry: (any AcervoTelemetryReporter)? { get }
```

The currently-attached reporter. Intended for test use (snapshot/restore around code paths that mutate it).

### URL Cache

#### `clearCache()`

```swift
public func clearCache()
```

Discards all cached model directory URLs. Subsequent operations re-resolve paths.

#### `preloadModels()`

```swift
public func preloadModels() async throws
```

Calls `Acervo.listModels()` and caches the directory URL for each discovered model. Use at app launch to warm the cache.

### Download

#### `download(_:files:force:progress:)`

```swift
public func download(
    _ modelId: String,
    files: [String],
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
) async throws
```

Acquires the per-model lock before delegating to `Acervo.download`. Releases the lock on completion or error. Tracks download counts (accessible via `getDownloadCount(for:)`). Caches the model directory URL on success.

### Availability

#### `availability(_:verifyHashes:)`

```swift
public func availability(
    _ modelId: String,
    verifyHashes: Bool = false
) async -> ModelAvailability
```

Forwards to `Acervo.availability`. **Does not acquire the per-model lock** — availability queries must not serialize behind an in-flight download.

### Exclusive Model Access

#### `withModelAccess(_:perform:)`

```swift
public func withModelAccess<T: Sendable>(
    _ modelId: String,
    perform: @Sendable (URL) throws -> T
) async throws -> T
```

Acquires the per-model lock, resolves the model directory URL, and invokes `perform` with the URL. Falls back to the component registry for short IDs (e.g., a component ID like `"t5-xxl-encoder-int4"` that lacks the `org/` prefix). Releases the lock when `perform` returns or throws.

```swift
let configURL = try await AcervoManager.shared.withModelAccess(
    "mlx-community/Qwen2.5-7B-Instruct-4bit"
) { dir in
    dir.appendingPathComponent("config.json")
}
```

### Component Access

#### `withComponentAccess(_:perform:)`

```swift
public func withComponentAccess<T: Sendable>(
    _ componentId: String,
    perform: @Sendable (ComponentHandle) throws -> T
) async throws -> T
```

Looks up the component in the registry, verifies all declared files are present on disk, re-verifies SHA-256 for any file with a declared checksum, then acquires the per-component lock and invokes `perform` with a `ComponentHandle`. Throws `AcervoError.componentNotRegistered`, `AcervoError.componentNotDownloaded`, or `AcervoError.integrityCheckFailed`.

```swift
let weights = try await AcervoManager.shared.withComponentAccess("t5-xxl-encoder-int4") { handle in
    let url = try handle.url(matching: ".safetensors")
    return try Data(contentsOf: url)
}
```

#### `withLocalAccess(_:perform:)`

```swift
public func withLocalAccess<T: Sendable>(
    _ url: URL,
    perform: @Sendable (LocalHandle) throws -> T
) async throws -> T
```

Provides scoped access to a caller-supplied local path not registered in the component registry (e.g., a user-supplied LoRA adapter). Validates the path exists and provides a `LocalHandle`. Throws `AcervoError.localPathNotFound(url:)`.

```swift
let weights = try await AcervoManager.shared.withLocalAccess(loraAdapterURL) { handle in
    let url = try handle.url(matching: ".safetensors")
    return try loadSafetensors(from: url)
}
```

### Component Lifecycle (Manager-level)

These methods forward to their `Acervo.*` counterparts, routing telemetry through the manager-attached reporter.

#### `ensureComponentReady(_:progress:)`

```swift
public func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
) async throws
```

#### `ensureComponentsReady(_:progress:)`

```swift
public func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
) async throws
```

#### `downloadComponent(_:force:progress:)`

```swift
public func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
) async throws
```

#### `hydrateComponent(_:)`

```swift
public func hydrateComponent(_ componentId: String) async throws
```

### Statistics

#### `getDownloadCount(for:)`

```swift
public func getDownloadCount(for modelId: String) -> Int
```

Returns the number of times `download()` has been called for the model.

#### `getAccessCount(for:)`

```swift
public func getAccessCount(for modelId: String) -> Int
```

Returns the number of times `withModelAccess()` has been called for the model.

#### `printStatisticsReport()`

```swift
public func printStatisticsReport()
```

Prints a formatted report of the top 10 downloaded and top 10 accessed models to standard output.

#### `resetStatistics()`

```swift
public func resetStatistics()
```

Resets all download and access counters to zero.

---

## ModelDownloadManager (Batch Orchestrator)

`ModelDownloadManager` is a higher-level actor over `AcervoManager` for orchestrating multi-model downloads with a single aggregated progress stream.

### `ModelDownloadManager.shared`

```swift
public static let shared: ModelDownloadManager
```

### `setTelemetry(_:)`

```swift
public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)
```

### `validateCanDownload(_:)`

```swift
public func validateCanDownload(_ modelIds: [String]) async throws -> Int64
```

Fetches and validates the CDN manifest for each model and returns the total declared bytes across the entire batch. Use as a pre-flight check before showing a disk-space warning. Models already present locally are still counted.

```swift
let totalBytes = try await ModelDownloadManager.shared.validateCanDownload([
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
])
print("Will require \(totalBytes / (1024 * 1024 * 1024)) GB")
```

### `ensureModelsAvailable(_:progress:)`

```swift
public func ensureModelsAvailable(
    _ modelIds: [String],
    progress: @escaping @Sendable (ModelDownloadProgress) -> Void
) async throws
```

Fetches every model's manifest up front (so `bytesTotal` is stable from the first callback), then downloads each model in sequence. Already-local models are skipped but their bytes are credited toward the cumulative total. Downloads within a single model may be parallelized by `AcervoDownloader`. Errors are logged and re-thrown unchanged; subsequent models in the batch are not attempted after a failure.

```swift
try await ModelDownloadManager.shared.ensureModelsAvailable(
    ["mlx-community/Qwen2.5-7B-Instruct-4bit"]
) { progress in
    print("\(progress.model) — \(progress.currentFileName): \(Int(progress.fraction * 100))%")
}
```

---

## Supporting Types

### `ModelAvailability`

```swift
public enum ModelAvailability: Sendable, Equatable {
    case notAvailable
    case downloading(progress: Double)    // 0.0...1.0, clamped
    case partial(missing: [String])       // manifest-relative paths of missing files
    case available
}
```

Four-state enum returned by `Acervo.availability(_:)`, `Acervo.availability(slug:url:)`, and `AcervoManager.availability(_:)`.

- `.notAvailable` — never downloaded or wholly deleted; no download in flight.
- `.downloading(progress:)` — a download Task is currently registered in the in-flight registry.
- `.partial(missing:)` — model was downloaded, but at least one declared file is now missing or wrong-size. The `missing` array is sorted in manifest-declaration order. Consumers may re-invoke `ensureAvailable` to fill the gaps.
- `.available` — all manifest files are on disk at their recorded sizes.

---

### `AcervoModel`

```swift
public struct AcervoModel: Identifiable, Equatable, Codable, Sendable {
    public let id: String           // "org/repo"
    public let path: URL            // local filesystem URL
    public let sizeBytes: Int64
    public let downloadDate: Date   // directory creation date
    public var formattedSize: String // "4.4 GB"
    public var slug: String         // "org_repo"
    public var baseName: String     // base name with suffixes stripped
    public var familyName: String   // "org/baseName"
}
```

---

### `ComponentDescriptor`

```swift
public struct ComponentDescriptor: Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public let type: ComponentType
    public let displayName: String
    public let repoId: String
    public var files: [ComponentFile]         // [] for un-hydrated descriptors
    public var estimatedSizeBytes: Int64       // 0 for un-hydrated
    public let minimumMemoryBytes: Int64
    public let metadata: [String: String]
    public var isHydrated: Bool               // true when file list is populated
    public var needsHydration: Bool           // inverse of isHydrated

    // Pre-hydrated initializer (for bundle-pattern or known-file-list components)
    public init(id:type:displayName:repoId:files:estimatedSizeBytes:minimumMemoryBytes:metadata:)

    // Un-hydrated initializer (file list fetched from CDN manifest on first use)
    public init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)
}
```

Two descriptors are equal (`Equatable`) if and only if they share the same `id`.

---

### `ComponentType`

```swift
public enum ComponentType: String, Sendable, CaseIterable, Codable {
    case encoder       // Text encoders (T5, CLIP, Qwen3, Mistral)
    case backbone      // Core model (DiT, autoregressive, etc.)
    case decoder       // Latent-to-data conversion (VAE, vocoder)
    case scheduler     // Noise schedulers
    case tokenizer     // Tokenizer files
    case auxiliary     // LoRA adapters, config files, etc.
    case languageModel // Autoregressive LLMs (e.g., TTS models)
}
```

---

### `ComponentFile`

```swift
public struct ComponentFile: Sendable, Equatable {
    public let relativePath: String
    public let expectedSizeBytes: Int64?
    public let sha256: String?

    public init(relativePath: String, expectedSizeBytes: Int64? = nil, sha256: String? = nil)
}
```

---

### `ComponentHandle`

Opaque handle provided inside `AcervoManager.withComponentAccess`. Valid only for the duration of the enclosing closure.

```swift
public struct ComponentHandle: Sendable {
    public let descriptor: ComponentDescriptor
    public var rootDirectoryURL: URL

    public func url(for relativePath: String) throws -> URL
    public func url(matching suffix: String) throws -> URL        // first match
    public func urls(matching suffix: String) throws -> [URL]     // all matches
    public func availableFiles() -> [String]
}
```

---

### `LocalHandle`

Opaque handle provided inside `AcervoManager.withLocalAccess`. Valid only for the duration of the enclosing closure.

```swift
public struct LocalHandle: Sendable {
    public let rootURL: URL

    public func url(for relativePath: String) throws -> URL
    public func url(matching suffix: String) throws -> URL
    public func urls(matching suffix: String) throws -> [URL]
}
```

---

### `AcervoDownloadProgress`

```swift
public struct AcervoDownloadProgress: Sendable {
    public let fileName: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64?
    public let fileIndex: Int
    public let totalFiles: Int
    public var overallProgress: Double    // 0.0...1.0, byte-accurate across all files
}
```

Delivered to the `progress:` callback of `Acervo.download`, `Acervo.ensureAvailable`, and their component-level counterparts.

---

### `ModelDownloadProgress`

```swift
public struct ModelDownloadProgress: Sendable {
    public let model: String
    public let fraction: Double          // 0.0...1.0, cumulative across the batch
    public let bytesDownloaded: Int64
    public let bytesTotal: Int64
    public let currentFileName: String
}
```

Delivered to `ModelDownloadManager.ensureModelsAvailable(_:progress:)`.

---

### `AcervoPublishProgress`

```swift
public enum AcervoPublishProgress: Sendable {
    case generatingManifest
    case verifyingManifest
    case listingExistingKeys(found: Int)
    case uploadingFile(name: String, bytesSent: Int64, bytesTotal: Int64)
    case uploadingManifest
    case verifyingPublic(stage: String)
    case pruningOrphans(count: Int)
    case complete
}
```

---

### `AcervoDeleteProgress`

```swift
public enum AcervoDeleteProgress: Sendable {
    case listingPrefix
    case deletingBatch(count: Int, deletedSoFar: Int)
    case complete
}
```

---

### `AcervoCDNCredentials`

```swift
public struct AcervoCDNCredentials: Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let region: String       // default "auto" (Cloudflare R2)
    public let bucket: String       // default "intrusive-memory-models"
    public let endpoint: URL
    public let publicBaseURL: URL
}
```

Credentials for operator-side CDN mutations. The library never reads from `ProcessInfo.environment`; callers must populate and pass an instance explicitly.

---

### `CDNManifestConsumer`

```swift
public struct CDNManifestConsumer: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case library
        case app
    }

    public let name: String   // publicly-visible project name
    public let kind: Kind
    public let url: String?   // optional homepage / docs link; omitted when nil

    public init(name: String, kind: Kind, url: String? = nil)
}
```

Identifies a library or application that consumes a CDN-hosted model. Surfaces on `CDNManifest` as:

```swift
public let consumers: [CDNManifestConsumer]
```

**Naming convention.** Entries are identified by **project name** — the publicly-visible product/library name — not the GitHub `org/repo`. This is deliberate: some consuming repos are private, and the project name is the stable, public identifier. Examples:

| `name` | `kind` |
| --- | --- |
| `"SwiftVinetas"` | `.library` |
| `"Vinetas"` | `.app` |
| `"mlx-audio-swift"` | `.library` |

**Wire schema.** Optional on the wire, defaults to `[]`. Existing pre-`consumers` manifests on the CDN continue to decode cleanly — there is no migration shim required for readers. Producers are expected to populate at least one entry; that invariant will be enforced at upload time (CLI / spec) rather than at the decode boundary.

> **No public producer API yet.** As of this release, `Acervo.publishModel(...)` and `Acervo.recache(...)` do **not** accept a `consumers:` parameter and emit `consumers: []` on every publish. The internal `ManifestGenerator` accepts a `consumers:` argument (`Sources/SwiftAcervo/ManifestGenerator.swift`), but that type is not part of the public documented surface. Wiring `consumers` onto `publishModel` / `recache` (and the `acervo ship` CLI / spec file) is tracked as the next step. Until then, consumers can **read** the field via `Acervo.fetchManifest(...)` but cannot set it through the public library API.

---

### `AcervoTelemetryReporter`

```swift
public protocol AcervoTelemetryReporter: Sendable {
    func capture(_ event: AcervoTelemetryEvent) async
}

// Concrete no-op implementation:
public struct NoopAcervoTelemetryReporter: AcervoTelemetryReporter {
    public init()
    public func capture(_ event: AcervoTelemetryEvent) async
}
```

Conform to `AcervoTelemetryReporter` and pass an instance as `telemetry:` to any API that accepts one. `NoopAcervoTelemetryReporter` is provided for testing.

---

### `AcervoTelemetryEvent`

```swift
public enum AcervoTelemetryEvent: Sendable {
    // Lifecycle
    case downloadOperationStart(modelID: String, requestedFiles: [String], offlineMode: Bool)
    case downloadOperationComplete(modelID: String, totalBytes: Int64, durationSeconds: Double)

    // Per-file download
    case componentDownloadStart(modelID: String, fileName: String, expectedBytes: Int64?, sourceURL: String)
    case componentDownloadComplete(modelID: String, fileName: String, actualBytes: Int64, durationSeconds: Double, throughputMBps: Double)

    // Manifest fetch
    case manifestFetchStart(modelID: String, manifestURL: String)
    case manifestFetchComplete(modelID: String, manifestVersion: String, fileCount: Int, totalDeclaredBytes: Int64)

    // Integrity
    case integrityVerifyStart(modelID: String, fileName: String, expectedSHA: String, declaredBytes: Int64)
    case integrityVerifyComplete(modelID: String, fileName: String, actualSHA: String, actualBytes: Int64, passed: Bool, durationSeconds: Double)

    // Cache
    case cacheHit(modelID: String, fileName: String, onDiskBytes: Int64, ageSeconds: Double)
    case cacheMiss(modelID: String, fileName: String, reason: CacheMissReason)

    // Component lifecycle
    case componentResolveStart(componentID: String, repoID: String)
    case componentResolveComplete(componentID: String, repoID: String, fileCount: Int, totalBytes: Int64, cacheState: ComponentCacheState, durationSeconds: Double)

    // File access
    case componentFileAccessOpened(componentID: String, repoID: String, baseDirectory: String, fileCount: Int)

    // CDN HTTP
    case cdnRequest(method: String, url: String, statusCode: Int, latencyMS: Double, byteCount: Int64?)

    // Memory
    case modelLoadComplete(modelID: String, totalSizeMB: Double, componentCount: Int)

    // Availability resolution
    case modelAvailabilityResolved(slug: String, manifestURL: String, componentCount: Int, result: String)

    // Error side-channel
    case errorThrown(phase: ErrorPhase, errorDescription: String, modelID: String?, fileName: String?)

    public enum ComponentCacheState: String, Sendable {
        case alreadyReady, downloaded, hydratedOnly
    }
    public enum CacheMissReason: String, Sendable {
        case notPresent, shaChangedRemote, sizeChangedRemote, corrupted, forcedRefresh
    }
    public enum ErrorPhase: String, Sendable {
        case manifestDownload, manifestDecode, manifestVersionUnsupported, manifestIntegrity
        case fileDownload, fileDownloadSize, fileDownloadIntegrity, directoryCreation
        case offlineMode, s3Request, other
    }
}
```

---

### `AcervoError`

All errors from SwiftAcervo conform to `LocalizedError` and `Sendable`. `errorDescription` returns a human-readable string.

| Case | Thrown by |
|------|-----------|
| `invalidModelId(String)` | Any API that validates an `"org/repo"` format |
| `modelNotFound(String)` | `modelInfo`, `deleteModel` |
| `directoryCreationFailed(String)` | `download`, `ensureModelDirectory` |
| `downloadFailed(fileName:statusCode:)` | File download HTTP errors |
| `networkError(Error)` | Wraps underlying transport errors |
| `modelAlreadyExists(String)` | Conflict during publish-side operations |
| `fileNotInManifest(fileName:modelId:)` | Requesting a file not declared in the manifest |
| `downloadSizeMismatch(fileName:expected:actual:)` | Post-download size verification |
| `integrityCheckFailed(file:expected:actual:)` | SHA-256 mismatch |
| `manifestDownloadFailed(statusCode:)` | Manifest HTTP error (repo-keyed path) |
| `manifestDecodingFailed(Error)` | JSON decode failure |
| `manifestIntegrityFailed(expected:actual:)` | Manifest checksum-of-checksums mismatch |
| `manifestVersionUnsupported(Int)` | Manifest version the client cannot handle |
| `manifestModelIdMismatch(expected:actual:)` | Server returned wrong manifest |
| `invalidManifestPath(String)` | Manifest entry with empty, absolute, or traversal path |
| `localPathNotFound(url:)` | `withLocalAccess` when the URL does not exist |
| `componentNotRegistered(String)` | Any component API with an unknown ID |
| `componentNotDownloaded(String)` | `withComponentAccess`, `verifyComponent` |
| `componentFileNotFound(component:file:)` | `ComponentHandle.url(for:)`, `ComponentHandle.url(matching:)` |
| `componentNotHydrated(id:)` | Operations requiring a populated file list |
| `offlineModeActive` | Any CDN fetch when `ACERVO_OFFLINE=1` |
| `cdnAuthorizationFailed(operation:)` | HTTP 401/403 from the CDN (operator-side) |
| `cdnOperationFailed(operation:statusCode:body:)` | Other non-2xx CDN responses (operator-side) |
| `publishVerificationFailed(stage:)` | CHECK 4/5/6 during `publishModel` |
| `fetchSourceFailed(modelId:underlying:)` | `fetchSource` closure threw during `recache` |
| `manifestZeroByteFile(path:)` | CHECK 2 during `publishModel` |
| `manifestPostWriteCorrupted(path:)` | CHECK 3 during `publishModel` |
| `manifestRelativePathOutsideBase(file:base:)` | Manifest generation path resolution failure |
| `urlRequiredForSlug(String)` | Slug-keyed API with opaque slug and no `url:` |
| `manifestFetchFailed(slug:status:)` | Non-2xx manifest HTTP response (slug-keyed path) |
| `publishOrphanPruneFailed(failedKeys:publishedManifest:)` | Orphan prune failures after successful publish |

---

## Common Patterns

### Pattern 1: SwiftBruja-style usage — ensure then load

```swift
import SwiftAcervo

func prepareModel() async throws -> URL {
    let modelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"

    // Ensure the model is present (no-op if already cached)
    try await AcervoManager.shared.ensureComponentsReady(
        [modelId],
        progress: { p in
            print("\(p.fileName): \(Int(p.overallProgress * 100))%")
        }
    )

    // Return the resolved directory; hand to MLX or your inference framework
    return try Acervo.modelDirectory(for: modelId)
}
```

---

### Pattern 2: Opt-in SHA-256 verification (bit-rot audit)

Reserve this for scheduled integrity checks, not interactive use — cost is proportional to total bytes on disk.

```swift
let state = await Acervo.availability(
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    verifyHashes: true
)
switch state {
case .available:
    print("All hashes verified")
case .partial(let missing):
    print("Corrupted or missing: \(missing)")
default:
    break
}
```

---

### Pattern 3: Slug-keyed multi-component bundle

```swift
// Check availability of a multi-component slug
let state = try await Acervo.availability(
    slug: "black-forest-labs/FLUX.2-klein-4B"
)

// Download all components (sequential, bytes-weighted progress)
try await Acervo.ensureAvailable(
    slug: "black-forest-labs/FLUX.2-klein-4B",
    files: [],
    progress: { aggregate in
        if case .downloading(let p) = aggregate {
            print("Overall: \(Int(p * 100))%")
        }
    }
)
```

---

### Pattern 4: Pre-warm at app launch with explicit progress reporting

```swift
func applicationDidFinishLaunching() {
    Task {
        // Warm the URL cache from whatever is already on disk
        try? await AcervoManager.shared.preloadModels()

        // Batch-download a fixed model set, with cumulative progress
        try await ModelDownloadManager.shared.ensureModelsAvailable(
            [
                "mlx-community/Qwen2.5-7B-Instruct-4bit",
                "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
            ]
        ) { progress in
            DispatchQueue.main.async {
                self.progressBar.doubleValue = progress.fraction
                self.statusLabel.stringValue = progress.model
            }
        }
    }
}
```

---

### Pattern 5: Cleanup local cache via `gcEmptyModelDirectories()`

Stub directories (from cancelled or partially-started downloads) do not appear in `listModels()` but do occupy filesystem entries. Prune them at a convenient maintenance point.

```swift
func cleanupStubs() throws {
    let removed = try Acervo.gcEmptyModelDirectories()
    if !removed.isEmpty {
        print("Removed \(removed.count) stub director(ies):")
        removed.forEach { print("  \($0.lastPathComponent)") }
    }
}
```

---

## Requirements

| Requirement | Value |
|-------------|-------|
| iOS | 26.0+ |
| macOS | 26.0+ |
| Swift | 6.0+ |
| Dependencies | Foundation + CryptoKit only (zero third-party) |
| App Group entitlement | `com.apple.security.application-groups` (UI apps) |
| Env var | `ACERVO_APP_GROUP_ID` (CLI tools, test runners, iOS) |

**Offline mode.** Set `ACERVO_OFFLINE=1` in the process environment to block all outbound CDN fetches. Only the literal string `"1"` activates offline mode. Read-only filesystem operations (e.g., `modelDirectory`, `isModelAvailable`, `listModels`) are unaffected. Any code path that would contact the CDN throws `AcervoError.offlineModeActive`.

---

## Regenerating This File

This document is compiled from `Sources/SwiftAcervo/*.swift` and `Sources/SwiftAcervo/Telemetry/*.swift`. After any public-API change, regenerate by re-reading every source file listed above and updating the corresponding section. Every `public` symbol must appear; every example must reference only signatures that exist in source. Do not auto-generate via a code tool — regenerate manually by reading the source.

---

## See Also

- [USAGE-cli.md](./USAGE-cli.md) — companion reference for the `acervo` command-line tool.
- [Docs/DESIGN_PATTERNS.md](./DESIGN_PATTERNS.md) — architectural patterns (Static+Actor, streaming SHA-256, per-model locking, atomic downloads).
- [Docs/CDN_ARCHITECTURE.md](./CDN_ARCHITECTURE.md) — how downloads work, verification, security properties.
