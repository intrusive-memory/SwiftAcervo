# SwiftAcervo TODO: Manifest-Driven Component Registration

## Background

The CDN manifest (`{CDN_BASE}/models/{slug}/manifest.json`) already contains the authoritative list of files, sizes, and SHA-256 checksums for every component. Acervo fetches and validates it on every download (`AcervoDownloader.downloadManifest`, `Acervo.swift:1316-1347` feeds `descriptor.files` into the download path alongside manifest validation).

Despite this, **every consuming library still has to hardcode the same file list twice**:

1. In Swift: `ComponentDescriptor(files: [ComponentFile(relativePath: "config.json"), ...])`
2. In CI YAML: a shell `FILES=(...)` array in `ensure-model-cdn.yml`

These two lists drift. When they drift, you either download files that don't exist on the CDN or skip files that do. The Swift list is also a lie of omission: it claims "these are the files" when the manifest is the real truth.

**The manifest is the source of truth. The registry should pull from it, not duplicate it.**

---

## Goal

A consumer should be able to declare a component with nothing more than `id`, `type`, `displayName`, `repoId`, and a memory estimate — no `files:` array. SwiftAcervo fetches the manifest and learns the file list itself.

**Desired consumer API (glosa-av's `ModelCatalog.swift` post-migration):**

```swift
public static let descriptors: [ComponentDescriptor] = [
    ComponentDescriptor(
        id: defaultModelId,
        type: .languageModel,
        displayName: "Qwen2.5 3B Instruct (4-bit MLX)",
        repoId: defaultModelId,
        minimumMemoryBytes: 2_400_000_000
        // no files: array
        // no estimatedSizeBytes (derived from manifest sum)
    )
]

Acervo.register(descriptors)
try await Acervo.ensureComponentReady(modelId)   // fetches manifest on first use, populates files
```

---

## Current State (v0.7.3)

What exists:

- `AcervoDownloader.downloadManifest(for: modelId) async throws -> CDNManifest` — fetches, validates version, validates id, validates checksum-of-checksums. **Internal-scoped** (not `public`).
- `CDNManifest.files: [CDNManifestFile]` — each with `{ path, sha256, sizeBytes }`, fully public.
- `ComponentRegistry` — in-memory, thread-safe, dedupe/merge semantics.
- `Acervo.ensureComponentReady` / `downloadComponent` — drive downloads from `descriptor.files.map(\.relativePath)`.

What's missing:

- `ComponentDescriptor.files` is required and non-optional in `init` (`ComponentDescriptor.swift:105-123`).
- `downloadComponent` always uses `descriptor.files` as the authoritative download list. If the descriptor is missing files present in the manifest, they are silently skipped.
- No public API path for "register a shell, hydrate from manifest."

---

## Work Items

### 1. Make `ComponentDescriptor.files` optional on the surface

Two approaches — pick one up front:

- **(a) Empty-array sentinel.** Keep `files: [ComponentFile]` non-optional but allow `[]`. "Empty" means "learn from manifest."
- **(b) New initializer.** Add a second `init` that omits `files` and `estimatedSizeBytes`, stores a nil-sentinel internally. Existing init remains the "I know exactly what I want" escape hatch.

Recommend **(b)**. It makes the two modes distinct at the call site and preserves the ability for a consumer to pin an exact file list + checksums when they want to (e.g. pre-release models not yet on CDN, or integrity-critical components).

Internal representation: convert `files` to `[ComponentFile]?` in the stored struct, or introduce a private `DescriptorShape` enum (`.declared(files: [...])` vs `.hydrateFromManifest`). Either way, `registeredComponents()` must never surface an un-hydrated descriptor without making that state visible — see item 4.

### 2. Add `Acervo.hydrateComponent(_:) async throws`

```swift
/// Fetches the CDN manifest for a registered component and populates its
/// `files`, per-file sizes, per-file SHA-256 hashes, and `estimatedSizeBytes`.
///
/// Idempotent: calling this on an already-hydrated component re-fetches and
/// replaces the stored file list (picks up CDN updates between launches).
///
/// - Throws: `AcervoError.componentNotRegistered`, `AcervoError.manifest*`.
public static func hydrateComponent(_ componentId: String) async throws
```

Implementation: fetch via `AcervoDownloader.downloadManifest`, map `CDNManifestFile` → `ComponentFile(relativePath: f.path, expectedSizeBytes: f.sizeBytes, sha256: f.sha256)`, rebuild the descriptor, re-register with merge semantics.

### 3. Auto-hydrate inside `ensureComponentReady` / `downloadComponent` / `isComponentReady`

A consumer should never have to call `hydrateComponent` explicitly. The pattern is:

```swift
func ensureComponentReady(_ id: String) async throws {
    guard var descriptor = ComponentRegistry.shared.component(id) else { throw ... }
    if descriptor.needsHydration {
        try await hydrateComponent(id)
        descriptor = ComponentRegistry.shared.component(id)!   // now hydrated
    }
    // ... existing logic using descriptor.files
}
```

`isComponentReady(_:)` is trickier — it is currently sync. Options:

- Make a new `isComponentReadyAsync(_:)` that hydrates first; leave the sync version returning `false` for unhydrated components (safe default: "not ready → ask for it").
- Document that `isComponentReady` on an unhydrated descriptor returns `false` until first `ensureComponentReady` call.

### 4. Expose hydration state

Add `ComponentDescriptor.isHydrated: Bool` (or equivalent computed property). Callers like dashboards / catalog views need to know whether the size/file info is real or pending first-use.

`pendingComponents()` and `totalCatalogSize()` both read `estimatedSizeBytes` and `files` — they must either (a) skip un-hydrated descriptors, (b) proactively hydrate, or (c) return a clearly-marked "unknown" state. Pick one and be consistent.

### 5. Make `AcervoDownloader.downloadManifest` public

It's already the right shape. Expose it. Consumers with esoteric needs (custom catalogs, cache warmers, CI verification tools) shouldn't have to go through the full download path just to read a manifest.

```swift
// BEFORE
static func downloadManifest(for modelId: String) async throws -> CDNManifest

// AFTER
public static func downloadManifest(for modelId: String) async throws -> CDNManifest
```

Consider also promoting it to `Acervo.fetchManifest(for:)` as the public entry point, with the `AcervoDownloader` version remaining the implementation detail.

### 6. Add an error case for hydration failure surfaced at registration-time expectations

```swift
case componentNotHydrated(id: String)
```

Throw it from any sync-only path where the descriptor hasn't been hydrated yet and the caller clearly expected real data (e.g., `verifyComponent` on an empty descriptor).

### 7. Cache manifests on disk with a TTL

Right now every `ensureComponentReady` call fetches the manifest from the CDN, even if the component is already downloaded. That's one extra network round-trip per startup. Cache the last-fetched manifest under the component's directory (`{modelDir}/manifest.json`) and re-use it for the hydration path unless it's older than N hours (suggest: 24h default, configurable).

This is a **nice-to-have**, not a blocker. Ship items 1-6 first, add caching after.

---

## Tests to Add

Under `Tests/SwiftAcervoTests/`:

1. **Register-without-files round trip.** Register a descriptor with no `files`, call `ensureComponentReady`, assert the registry now has a populated file list matching the manifest.
2. **Hydration picks up manifest drift.** Register a descriptor with stale declared files, call `hydrateComponent`, assert the files match the current manifest (not the declared list). Decide explicitly: does hydration *replace* a declared list, or only fill when empty? Test whichever behavior you pick.
3. **`isHydrated` transitions.** False before, true after.
4. **Manifest 404 on hydration.** Assert a clean `AcervoError.manifestDownloadFailed` bubbles up, no partial state left in registry.
5. **Concurrent hydration of the same component.** Two tasks call `ensureComponentReady` simultaneously — only one manifest fetch should occur, both should see hydrated state. (Use an actor or single-flight pattern.)
6. **Manifest id mismatch.** Register `foo/bar`, CDN serves a manifest whose `modelId` is `baz/qux`. Assert `AcervoError.manifestModelIdMismatch` is thrown.
7. **Backwards compatibility.** Existing descriptors that declare `files:` must still work identically — no regression in `downloadComponent`, `ensureComponentReady`, `verifyComponent`.

---

## Migration Path for Consumers

After this ships as v0.8.0, consumers migrate in two steps:

**Step 1** — drop the `files:` array from each `ComponentDescriptor`. No other code changes. `ensureComponentReady` hydrates transparently on first call.

**Step 2** — delete `estimatedSizeBytes` where it's just a placeholder (`0` today in glosa-av). Keep it where the consumer wants a pre-hydration estimate for UI.

Concrete: glosa-av's `Sources/GlosaDirector/ModelCatalog.swift:27-42` collapses from 16 lines to ~8.

---

## CI Workflow Is a Separate Problem

`ensure-model-cdn.yml` in each consumer repo also hardcodes a `FILES=(...)` array. That file is the *producer* of the manifest — it can never source files from the manifest it's about to create. Addressing it requires either:

- A separate convention: the CI discovers files via the HuggingFace repo API (`https://huggingface.co/api/models/{repoId}/tree/main`) with a documented filter for inference-relevant extensions.
- The `acervo ship` CLI grows a `--from-hf {repoId}` mode that does the discovery + filter + upload in one shot.

Recommend the second — it pulls the logic into one place (this repo) instead of leaving every consumer's YAML to reinvent it. Track separately from this TODO; the Swift-side work above is the prerequisite.

---

## Open Decisions (resolve before coding)

1. **Hydration semantics on a partially-declared descriptor.** If a consumer declares `files: [ComponentFile(relativePath: "model.safetensors")]` but the manifest has 4 files — does hydration *merge* (add the 3 missing), *replace* (use only manifest), or *error* (mismatch)? Recommend replace, with a warning logged on drift. Revisit if a consumer has a legitimate "I only want a subset" use case.
2. **Whether to cache manifests on disk.** See item 7. Ship without it first; add if startup latency becomes a real complaint.
3. **Naming.** `hydrateComponent` vs `refreshComponent` vs `loadManifestFor`. Pick one and stick with it across the API.
