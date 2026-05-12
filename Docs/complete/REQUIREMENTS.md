# SwiftAcervo — Requirements (v2: Component Registry)

**Status**: DRAFT — debate and refine before implementation.
**Parent project**: [`PROJECT_PIPELINE.md`](../PROJECT_PIPELINE.md) — Unified MLX Inference Architecture (§1. SwiftAcervo, Wave 0)
**Scope**: Evolve SwiftAcervo from a filesystem discovery layer into the declarative component registry for the entire MLX ecosystem. Model plugins register what exists; Acervo manages the full lifecycle — catalog, download, cache, access. Consumers (SwiftTubería, SwiftVoxAlta) address models exclusively through Acervo's abstractions, never through file paths.
**Supersedes**: `docs/archive/REQUIREMENTS_V1.md` (v1 filesystem-only spec, complete and implemented)

---

## Motivation

SwiftAcervo v1 answers one question: **"What's on disk?"** It scans `~/Library/SharedModels/` and reports what it finds. This works, but every consumer must independently know:
- Which repos to download
- Which files each model needs
- Expected sizes and whether a download is complete
- How to verify integrity

Each consumer reinvents this knowledge. flux-2-swift-mlx has a `ModelRegistry`. pixart-swift-mlx planned one. SwiftVoxAlta's `VoxAltaModelManager` hardcodes `Qwen3TTSModelRepo` variants. The result: model knowledge is scattered across packages, and the "what can I download?" question has no central answer.

Acervo v2 adds a second question: **"What exists in the world?"** Model plugins register their components declaratively. Acervo becomes the single source of truth for both "what's available" and "what's cached." SwiftTubería then addresses models purely through Acervo — no file paths, no hardcoded URLs, no hardcoded repo strings.

### Design Principle: Abstracted Access

**SwiftTubería should only ever address a model from the Acervo context and with abstraction, never with individual file paths.**

This means:
- Pipeline says: "I need component `t5-xxl-encoder-int4`"
- Acervo says: "It's available. Here's scoped access to load it."
- Pipeline loads weights through Acervo's access handle
- Pipeline never constructs, stores, or passes file system URLs for model data

If Acervo moves the storage location, changes the caching strategy, or adds integrity checks — no consumer code changes.

---

## What's New in v2 vs v1

| Capability | v1 (current) | v2 (this spec) |
|---|---|---|
| Filesystem discovery | Yes | Yes (unchanged) |
| Download from CDN | Yes (caller specifies files) | Yes (registry knows files) |
| Fuzzy search | Yes | Yes (unchanged) |
| **Component catalog** | No | **Yes — declarative registry** |
| **"What can I download?"** | No (only "what's on disk?") | **Yes** |
| **Integrity verification** | No | **Yes — SHA-256 checksums** |
| **Abstracted model access** | Partial (withModelAccess gives URL) | **Yes — opaque component handles** |
| **Component type awareness** | No | **Yes — encoder, backbone, decoder, etc.** |
| **Cross-package deduplication** | No | **Yes — same component registered twice is one entry** |

### What Does NOT Change

- Zero external dependencies (Foundation only)
- `~/Library/SharedModels/` canonical path
- `config.json` validity marker
- Slugification rules (`org/repo` → `org_repo`)
- Existing `Acervo` static API (additive, not breaking)
- Existing `AcervoManager` actor API (additive, not breaking)
- `AcervoModel`, `AcervoError`, `AcervoDownloadProgress` types
- Migration from legacy paths

---

## A1. Component Registry

### A1.1 ComponentDescriptor

A declarative description of a downloadable model component. Model plugins create these and register them with Acervo.

```swift
public struct ComponentDescriptor: Sendable, Identifiable {
    public let id: String                      // e.g. "t5-xxl-encoder-int4"
    public let type: ComponentType             // .encoder, .backbone, .decoder, .vocoder, .tokenizer
    public let displayName: String             // "T5-XXL Text Encoder (int4)"
    public let repoId: String         // "intrusive-memory/t5-xxl-int4-mlx"
    public let files: [ComponentFile]          // required files with checksums
    public let estimatedSizeBytes: Int64       // total expected download size
    public let minimumMemoryBytes: Int64       // RAM needed to load this component
    public let metadata: [String: String]      // model-specific key-value pairs
}

public struct ComponentFile: Sendable {
    public let relativePath: String            // "model.safetensors" or "speech_tokenizer/config.json"
    public let expectedSizeBytes: Int64?       // nil if unknown
    public let sha256: String?                 // nil to skip verification
}
```

**Sharded weights**: Sharded safetensors files (e.g., `model-00001-of-00003.safetensors`) are listed as separate `ComponentFile` entries. Each shard has its own size and optional checksum.

**Quantization variants**: Each quantization level is a separate `ComponentDescriptor` with its own ID. Different quantizations produce different files with different sizes and checksums. Naming pattern: `{model}-{quantization}`, e.g., `flux2-klein-4b-dit-bf16`, `flux2-klein-4b-dit-int4`, `flux2-klein-4b-dit-qint8`. Pre-quantized safetensors are the norm; on-the-fly quantization by WeightLoader is a fallback, not the default path.

**Well-known metadata keys**: To ensure consistency across model plugins, the following metadata keys are standardized:

| Key | Values | Purpose |
|---|---|---|
| `deprecated` | `"true"` | Component should be hidden from default UI/CLI |
| `quantization` | `"int4"`, `"int8"`, `"bf16"`, `"fp16"` | Quantization level (informational, not used by WeightLoader) |
| `architecture` | e.g., `"dit"`, `"unet"`, `"llm"` | Model architecture family |

Plugins MAY add additional keys beyond this list. Unknown keys are preserved and passed through — Acervo does not validate metadata contents.

```swift
public enum ComponentType: String, Sendable, CaseIterable {
    case encoder        // text encoders (T5, CLIP, Qwen3, Mistral)
    case backbone       // core model (DiT, autoregressive, etc.)
    case decoder        // latent → data (VAE, vocoder)
    case scheduler      // noise scheduling (weights are rare, but some are learned)
    case tokenizer      // tokenizer files (often bundled with encoder, but separable)
    case auxiliary      // anything else (LoRA adapters, config files, etc.)
    case languageModel  // autoregressive LLMs used for non-diffusion inference (e.g., TTS)
}
```

**`ComponentType` guidance**: Use `.backbone` for the primary neural network in diffusion pipelines (DiT, U-Net). Use `.languageModel` for autoregressive models that don't participate in diffusion (e.g., Qwen3-TTS). Use `.encoder` for text encoders regardless of their underlying architecture (T5, CLIP, Qwen3-as-encoder, Mistral-as-encoder).

### A1.2 Registration API

Model plugins register their components at import time or at pipeline assembly time.

```swift
extension Acervo {
    /// Register a component descriptor. Idempotent — re-registering the same ID updates the entry.
    public static func register(_ descriptor: ComponentDescriptor)

    /// Register multiple descriptors at once.
    public static func register(_ descriptors: [ComponentDescriptor])

    /// Remove a registration (does NOT delete downloaded files).
    public static func unregister(_ componentId: String)
}
```

**Deduplication**: If two model plugins both register `sdxl-vae-decoder-fp16` with the same repo and files, it's one entry. The registry deduplicates by `id`. Deduplication rules:
- Same `id`, same `repoId` and `files` → silent deduplicate (identical component)
- Same `id`, different `repoId` or `files` → warning logged, last registration wins
- `metadata` dictionaries are merged (newer keys overwrite on conflict)
- `estimatedSizeBytes` and `minimumMemoryBytes` take the max of both values

**Registration timing**: Standardized on import time via Swift static `let` initialization. Each plugin defines a static registration block that runs exactly once, thread-safely, when the module is first imported. Pipeline assembly can call `_ = PluginComponents.registered` as a defensive trigger.

**Thread safety**: All `Acervo` static methods (`register`, `registeredComponents`, `isComponentReady`, etc.) are thread-safe. The underlying `ComponentRegistry` uses internal synchronization (a lock or serial queue) to protect concurrent reads and writes. Callers can safely invoke these methods from any thread or task without external coordination. `AcervoManager` remains an actor for stateful operations (`withComponentAccess`, download tracking).

### A1.3 Catalog Queries

```swift
extension Acervo {
    /// All registered components (whether downloaded or not).
    public static func registeredComponents() -> [ComponentDescriptor]

    /// Filter by type.
    public static func registeredComponents(ofType type: ComponentType) -> [ComponentDescriptor]

    /// Look up a specific component.
    public static func component(_ id: String) -> ComponentDescriptor?

    /// Check if a registered component is fully downloaded and verified.
    public static func isComponentReady(_ id: String) -> Bool

    /// Components that are registered but not yet downloaded.
    public static func pendingComponents() -> [ComponentDescriptor]

    /// Total size of all registered components (downloaded + pending).
    public static func totalCatalogSize() -> (downloaded: Int64, pending: Int64)
}
```

This is the "what exists in the world?" API. A UI can show "3 of 7 components downloaded, 4.2 GB cached, 8.1 GB available to download."

---

## A2. Abstracted Component Access

### A2.1 ComponentHandle

When a consumer (e.g., SwiftTubería's WeightLoader) needs to load a component's files, it requests a handle from Acervo. The handle provides scoped access without exposing filesystem paths.

```swift
public struct ComponentHandle: Sendable {
    /// The component this handle provides access to.
    public let descriptor: ComponentDescriptor

    /// Access a file within the component by its relative path.
    /// Returns a URL valid for the duration of the enclosing `withComponentAccess` scope.
    public func url(for relativePath: String) throws -> URL

    /// Convenience: access the first file matching a suffix (e.g., ".safetensors").
    public func url(matching suffix: String) throws -> URL

    /// List all files available in this component.
    public func availableFiles() -> [String]

    /// Access all files matching a suffix (e.g., ".safetensors") for sharded weights.
    public func urls(matching suffix: String) throws -> [URL]
}
```

**URL lifetime**: Contractual, not runtime-enforced. The handle's URLs are valid for the duration of the enclosing `withComponentAccess` closure. Load data into memory within the closure; do not cache or store URLs beyond the closure scope. No runtime URL revocation — unnecessary overhead for filesystem URLs.

### A2.2 Scoped Access Pattern

```swift
extension AcervoManager {
    /// Provides scoped, exclusive access to a downloaded component.
    /// Throws if the component is not downloaded or fails integrity check.
    public func withComponentAccess<T: Sendable>(
        _ componentId: String,
        perform: @Sendable (ComponentHandle) throws -> T
    ) async throws -> T
}
```

**Contract**:
- The component MUST be downloaded and pass integrity checks before the closure is called
- The `ComponentHandle`'s URLs are valid only within the closure scope
- Access is serialized per component (same locking as existing `withModelAccess`)
- If the component is not registered, throws `AcervoError.componentNotRegistered`
- If the component is not downloaded, throws `AcervoError.componentNotDownloaded`

**Locking**: Exclusive lock per component ID. Different component IDs do not block each other (matches existing `AcervoManager` per-model locking). Reader-writer locking is unnecessary — weight loading (the primary access pattern) is a one-time operation per generation session.

### A2.3 How Pipeline Uses This

```swift
// In SwiftTubería's WeightLoader — no file paths, no repo strings
let weights = try await AcervoManager.shared.withComponentAccess("t5-xxl-encoder-int4") { handle in
    let safetensorsURL = try handle.url(matching: ".safetensors")
    return try loadArrays(url: safetensorsURL)
}
```

The WeightLoader knows it needs safetensors data. It doesn't know where on disk that data lives, which repo it came from, or how it was cached. That's Acervo's business.

---

## A3. Registry-Aware Downloads

### A3.1 Component Download

```swift
extension Acervo {
    /// Download a registered component. Uses the descriptor's file list and repo ID.
    /// No need for the caller to specify files — the registry knows.
    public static func downloadComponent(
        _ componentId: String,
        token: String? = nil,
        force: Bool = false,
        progress: @Sendable (AcervoDownloadProgress) -> Void = { _ in }
    ) async throws

    /// Ensure a registered component is downloaded. No-op if already cached and verified.
    public static func ensureComponentReady(
        _ componentId: String,
        token: String? = nil,
        progress: @Sendable (AcervoDownloadProgress) -> Void = { _ in }
    ) async throws

    /// Download all files needed for a set of components (e.g., a full pipeline recipe).
    public static func ensureComponentsReady(
        _ componentIds: [String],
        token: String? = nil,
        progress: @Sendable (AcervoDownloadProgress) -> Void = { _ in }
    ) async throws
}
```

**Partial download handling**:
- Resume by default: only download files not yet present on disk
- Size mismatch vs `ComponentFile.expectedSizeBytes` → delete file and re-download
- SHA-256 mismatch (if declared) → delete file and re-download
- `isComponentReady()` returns `true` only when ALL files in the descriptor are present and pass integrity checks
- `ensureComponentReady()` downloads only missing or corrupted files, not the entire component

**Key difference from v1**: Callers no longer specify file lists. The registry knows what files each component needs. This eliminates the most common source of errors — mismatched or incomplete file lists.

### A3.2 Pipeline Recipe Downloads

A pipeline recipe declares which components it needs (e.g., T5 encoder + PixArt backbone + SDXL VAE). A single call ensures everything is ready:

```swift
// In SwiftTubería, before generation:
let componentIds = recipe.allComponentIds  // ["t5-xxl-encoder-int4", "pixart-dit-int4", "sdxl-vae-fp16"]
try await Acervo.ensureComponentsReady(componentIds) { progress in
    reportProgress(.downloading(component: progress.fileName, fraction: progress.overallProgress))
}
```

### A3.3 Component Deletion

```swift
extension Acervo {
    /// Delete a downloaded component's files from disk.
    /// Does NOT unregister the component — it remains in the registry as "not downloaded."
    /// Throws AcervoError.componentNotRegistered if the ID is unknown.
    /// If the component is registered but not downloaded, this is a no-op (nothing to delete).
    public static func deleteComponent(_ componentId: String) throws
}
```

---

## A4. Integrity Verification

### A4.1 SHA-256 Checksums

Each `ComponentFile` can declare an expected SHA-256 hash. When present, Acervo verifies the file after download and before granting access.

```
Download → Write to disk → Compute SHA-256 → Compare to expected → Accept or reject
```

### A4.2 Verification Points

- **After download**: Verify immediately. If mismatch, delete the file and throw `AcervoError.integrityCheckFailed`.
- **Before access**: When `withComponentAccess` is called, verify all files with declared checksums. If a file has been corrupted or tampered with, throw before the closure runs.
- **Optional**: Checksums are optional per file. Files without a declared checksum skip verification (backward compatible with v1 behavior).

### A4.3 Re-verification

```swift
extension Acervo {
    /// Verify integrity of a downloaded component without re-downloading.
    /// Throws `AcervoError.componentNotRegistered` if the ID is unknown.
    /// Throws `AcervoError.componentNotDownloaded` if files are missing.
    /// Returns `false` if any file fails its SHA-256 checksum.
    /// Returns `true` if all checksums pass (or if no checksums are declared).
    public static func verifyComponent(_ componentId: String) throws -> Bool

    /// Verify all downloaded components. Returns IDs of any that fail checksum verification.
    /// Skips components that are registered but not downloaded.
    public static func verifyAllComponents() throws -> [String]
}
```

---

## A5. Backward Compatibility

### A5.1 Existing API Unchanged

All v1 API methods continue to work exactly as before:

```swift
// These all still work, unchanged:
Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit")
Acervo.listModels()
Acervo.download("org/repo", files: [...])
AcervoManager.shared.withModelAccess("org/repo") { url in ... }
```

The registry is an additive layer. Models that are on disk but not registered still show up in `listModels()`. Registered components that are downloaded appear in both `listModels()` (filesystem view) and `registeredComponents()` (registry view).

**Relationship between `AcervoModel` (v1) and `ComponentDescriptor` (v2)**:

Two views of the same storage:
- `listModels()` → filesystem view → `[AcervoModel]` (anything in `~/Library/SharedModels/`)
- `registeredComponents()` → registry view → `[ComponentDescriptor]` (declared by plugins)
- Cross-reference via `isComponentReady(id)` — checks if a registered component's files exist on disk
- `AcervoModel.sizeBytes` = filesystem ground truth (actual bytes on disk)
- `ComponentDescriptor.estimatedSizeBytes` = advisory (declared by plugin, may not match exactly)

Three possible states for a model directory:
1. **Registered + downloaded** (normal) — appears in both views
2. **Not registered + on disk** (legacy/manual download) — appears only in `listModels()`
3. **Registered + not downloaded** — appears only in `registeredComponents()` with `isComponentReady = false`

### A5.2 Migration for Existing Consumers

Consumers can adopt the registry incrementally:
1. **Phase 1**: Keep using `Acervo.download(modelId, files: [...])` as before
2. **Phase 2**: Register their components and switch to `Acervo.ensureComponentReady(componentId)`
3. **Phase 3**: Switch to `withComponentAccess` for abstracted file access

No consumer is forced to migrate. The v1 API is not deprecated.

---

## A6. Error Types (Additions)

```swift
// New cases added to AcervoError:
case componentNotRegistered(String)           // component ID not in registry
case componentNotDownloaded(String)           // registered but files missing
case integrityCheckFailed(file: String, expected: String, actual: String)
case componentFileNotFound(component: String, file: String)
```

Existing error cases unchanged.

---

## A7. What Acervo Still Is NOT

Even with the registry, Acervo maintains its boundaries:

1. **Not a model loader** — Does not import MLX or load weights into GPU memory. The `ComponentHandle` provides file access; consumers do the loading.
2. **Not a model hub client** — Downloads via direct CDN URLs, not any hub API. The registry provides the URLs; the download logic is the same as v1.
3. **Not a cache evictor** — Does not automatically delete models to free space. Explicit deletion via `deleteModel()` or `deleteComponent()`.
4. **Not a model converter** — Does not quantize or transform files.
5. **Zero external dependencies** — Foundation only. The registry is just in-memory data structures.

---

## A8. Storage of Registry State

The component registry is **in-memory only**. It is populated at process startup when model plugins register their components. There is no persistent registry database.

**Rationale**: The registry is a declaration of "what exists in the world" — this is static knowledge compiled into the model plugin packages. It doesn't need persistence because it's rebuilt from code every launch. Filesystem state (what's downloaded) is the persistent layer, and that already exists.

If a component is registered but not downloaded, it shows as "available to download." If a model directory exists on disk but no component is registered for it, it shows in `listModels()` as an unregistered model (v1 behavior).

---

## A9. Package Structure (Updated)

```
SwiftAcervo/
├── Sources/
│   └── SwiftAcervo/
│       ├── Acervo.swift                  # Static API (v1 + registry additions)
│       ├── AcervoManager.swift           # Actor (v1 + withComponentAccess)
│       ├── AcervoModel.swift             # Filesystem metadata (unchanged)
│       ├── AcervoError.swift             # Error types (extended)
│       ├── AcervoDownloader.swift        # Download implementation (unchanged)
│       ├── AcervoDownloadProgress.swift  # Progress tracking (unchanged)
│       ├── AcervoMigration.swift         # Legacy path migration (unchanged)
│       ├── LevenshteinDistance.swift      # Fuzzy search (unchanged)
│       ├── ComponentDescriptor.swift     # NEW — registry types
│       ├── ComponentHandle.swift         # NEW — abstracted access
│       └── ComponentRegistry.swift       # NEW — in-memory catalog
```

**Zero new dependencies.** The registry is pure Swift data structures and logic.

---

## A10. Interaction with SwiftTubería

```
Model Plugin (e.g., pixart-swift-mlx)
    │
    │ registers ComponentDescriptors at import time
    ▼
SwiftAcervo ◀──────── SwiftTubería
    │                       │
    │ catalog queries        │ "is component ready?"
    │ download management    │ "ensure these components"
    │ abstracted access      │ "give me access to load weights"
    │                       │
    ▼                       ▼
~/Library/SharedModels/    WeightLoader (loads through ComponentHandle)
```

**Dependency direction**: SwiftTubería depends on SwiftAcervo. Model plugins depend on SwiftAcervo (for registration) and SwiftTubería (for protocols). Acervo depends on nothing.

```
pixart-swift-mlx ──▶ SwiftTubería ──▶ SwiftAcervo
                  └────────────────────▶ SwiftAcervo  (also directly, for registration)
```

---

## A11. Testing Strategy

### A11.1 Existing Tests (Unchanged)
- Path construction, slugification
- Filesystem discovery and enumeration
- Fuzzy search and pattern matching
- Download URL construction
- Migration logic
- Manager locking

### A11.2 New Tests

**Registry Tests**:
- Register a component → appears in `registeredComponents()`
- Register same ID twice → deduplicates (last wins)
- Unregister → removed from catalog
- Filter by type → correct subset
- `isComponentReady` returns false for registered-but-not-downloaded
- `isComponentReady` returns true after download
- `pendingComponents` returns only undownloaded registered components

**Access Tests**:
- `withComponentAccess` for downloaded component → handle provides valid URLs
- `withComponentAccess` for not-downloaded component → throws `componentNotDownloaded`
- `withComponentAccess` for unregistered component → throws `componentNotRegistered`
- `handle.url(for:)` for existing file → valid URL
- `handle.url(for:)` for missing file → throws `componentFileNotFound`
- `handle.url(matching:)` finds file by suffix

**Integrity Tests**:
- Download file with correct checksum → accepted
- Download file with wrong checksum → rejected, file deleted
- `verifyComponent` on valid files → true
- `verifyComponent` on corrupted file → false
- `withComponentAccess` on corrupted file → throws before closure runs

**Integration Tests**:
- Register component → download → access → verify lifecycle
- `ensureComponentsReady` with mix of cached and pending → downloads only pending
- Registered component appears in both `registeredComponents()` and `listModels()`

### A11.3 Coverage and CI Stability Requirements

- All new code must achieve **≥90% line coverage** in unit tests. Coverage is measured per-target and enforced in CI.
- **No timed tests**: Tests must not use `sleep()`, `Task.sleep()`, `Thread.sleep()`, fixed-duration `XCTestExpectation` timeouts, or any wall-clock assertions. All asynchronous behavior must be validated via deterministic synchronization (`async`/`await`, `AsyncStream`, fulfilled expectations with immediate triggers).
- **No environment-dependent tests**: Tests must not depend on network access, GPU availability, or specific hardware. Use mock filesystems and injected dependencies for download and integrity verification tests. Tests requiring real CDN downloads are integration tests and must be clearly separated (separate test target or `#if INTEGRATION_TESTS` gate).
- **Flaky tests are test failures**: A test that passes intermittently is treated as a failing test until fixed. CI must not use retry-on-failure to mask flakiness.

---

## A12. Implementation Order

1. **ComponentDescriptor, ComponentType, ComponentFile** — Pure types, no logic
2. **ComponentRegistry** — In-memory dictionary, register/unregister/query
3. **Registration API on Acervo** — Static methods delegating to registry
4. **Catalog query API** — `registeredComponents()`, `isComponentReady()`, etc.
5. **Registry-aware downloads** — `downloadComponent()`, `ensureComponentReady()`
6. **ComponentHandle** — Abstracted file access
7. **withComponentAccess on AcervoManager** — Scoped access with locking
8. **Integrity verification** — SHA-256 on download and access
9. **New error cases** — Extend AcervoError
