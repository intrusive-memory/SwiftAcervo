# Changelog

All notable changes to SwiftAcervo are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.8.1] - 2026-04-25

### Added

- `ACERVO_OFFLINE` environment variable — when set to `"1"` in the process environment, every SwiftAcervo code path that would otherwise contact the CDN refuses the fetch and throws `AcervoError.offlineModeActive` instead. Read paths that touch only the local filesystem (`Acervo.modelDirectory(for:)`, `Acervo.isModelAvailable(_:)`, `LocalHandle`, hydrate-from-cache) are unaffected and continue to serve resources already present in the local SharedModels directory. The gate is checked unconditionally before any `URLSession` call in `AcervoDownloader.downloadManifest`, `streamDownloadFile`, and `fallbackDownloadFile`, covering every public entry point (`Acervo.fetchManifest`, `Acervo.hydrateComponent`, `Acervo.download`, etc.).
- `AcervoError.offlineModeActive` — new error case thrown by every gated entry point when `ACERVO_OFFLINE=1` is set. Carries no associated values; the localized description points consumers at the env-var contract.
- `Acervo.isOfflineModeActive` (internal) — single source of truth for the gate. Reads `ProcessInfo.processInfo.environment["ACERVO_OFFLINE"]` on every access so tests can flip the variable with `setenv` / `unsetenv` between cases.

### Migration

Non-breaking. Consumers that do not set `ACERVO_OFFLINE` see no behavioral change. Consumers that want to enforce offline-only operation (CI tests, sandboxed reference checks, air-gapped builds) can now set `ACERVO_OFFLINE=1` and rely on the typed error to short-circuit any code path that would otherwise hit the network.

---

## [0.8.0] - 2026-04-23

### Added

- `Acervo.hydrateComponent(_:)` — fetches CDN manifest for a registered component and populates its `files`, per-file sizes, SHA-256 hashes, and `estimatedSizeBytes`. Idempotent; concurrent calls for the same ID coalesce into one network fetch via `HydrationCoalescer` actor.
- `Acervo.fetchManifest(for modelId:)` — returns the raw `CDNManifest` for a model ID (`org/repo`). Bypasses the component registry. For custom catalogs, cache warmers, and CI verification tools.
- `Acervo.fetchManifest(forComponent componentId:)` — registry-aware companion. Looks up the component's `repoId` and fetches its manifest. Throws `AcervoError.componentNotRegistered` for unknown IDs.
- `Acervo.isComponentReadyAsync(_:)` — async readiness check that hydrates a bare descriptor first. Recommended for consumers using the new bare-descriptor pattern.
- `Acervo.unhydratedComponents()` — returns component IDs whose descriptors have no file list yet (pending first CDN hydration). Un-hydrated descriptors are excluded from `pendingComponents()` and `totalCatalogSize()`.
- `ComponentDescriptor.isHydrated` — `true` if the descriptor has a populated file list (declared or manifest-fetched).
- `ComponentDescriptor.needsHydration` — `true` if no file list is present; inverse of `isHydrated`.
- `ComponentDescriptor` bare-minimum initializer (omits `files:` and `estimatedSizeBytes`). Existing full initializer unchanged.
- `AcervoError.componentNotHydrated(id:)` — thrown from sync-only paths (e.g., `verifyComponent`) when the descriptor has no file list. Callers should use `hydrateComponent` or `ensureComponentReady` first.
- `AcervoDownloader.downloadManifest(for:session:)` — promoted to `public` with an injectable `URLSession` parameter (default: `SecureDownloadSession.shared`). Enables unit testing without CDN access.
- Internal `session:`-injectable overloads for `hydrateComponent`, `fetchManifest(for:)`, and `fetchManifest(forComponent:)`. Used by `MockURLProtocol`-based tests; public signatures are unchanged.
- `ComponentRegistry.replace(_:)` — internal method that overwrites a descriptor wholesale (used by hydration). The existing `register(_:)` merge semantics are unchanged.
- Test infrastructure: `Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` — `URLProtocol` subclass with static responder, request counter, and factory helper. Used by all hydration tests to stub CDN responses without network access.

### Changed

- Bare `ComponentDescriptor` (no `files:`) is now a first-class citizen. `ensureComponentReady` auto-hydrates on first call; no explicit `hydrateComponent` call is needed by consumers.
- `Acervo.isComponentReady(_:)` (sync) returns `false` for un-hydrated descriptors. This is the safe default — a sync method cannot perform a network fetch. Existing descriptors declared with `files:` are unaffected (they are hydrated from the start and continue to return an accurate value).
- `Acervo.pendingComponents()` and `Acervo.totalCatalogSize()` exclude un-hydrated descriptors from their results. Use `unhydratedComponents()` to enumerate them.
- Consumer documentation (USAGE.md, README.md, AGENTS.md, CLAUDE.md, GEMINI.md) restructured around the manifest-first contract: *consumers do not know what files exist in a model until the CDN manifest returns*. Hardcoded `files: [...]` arrays are now framed as an escape hatch, not the default pattern.

### Release Engineering

- `acervo` CLI version bumped from `0.7.0` to `0.8.0` to match the library.
- `Tests/AcervoToolIntegrationTests/` removed. The `acervo ship` roundtrip (HuggingFace → manifest → R2 upload → verify) is now exercised in each downstream repository's model-publish workflow against that repo's scoped credentials; SwiftAcervo itself never uploads.
- New `Tests/AcervoToolTests/CDNManifestFetchTests.swift` — no-credential read-only smoke against the public R2 URL. Fetches a known-published manifest, verifies the checksum-of-checksums, spot-checks one file's SHA-256. Wired into PR CI.
- `USAGE.md` now surfaces the `group.intrusive-memory.models` App Group entitlement setup as a first-class integration step. Apps without the entitlement silently fall back to a non-shared path — now called out up front.

### Migration

Non-breaking. All existing consumers continue to work without changes.

To adopt the new bare-descriptor pattern, drop `files:` and (optionally) `estimatedSizeBytes` from each `ComponentDescriptor`. `ensureComponentReady` hydrates transparently on first call. See [USAGE.md](USAGE.md) for a before/after example.

---

## [0.7.3] and earlier

See git log for history prior to v0.8.0.
