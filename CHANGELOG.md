# Changelog

All notable changes to SwiftAcervo are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.8.0] - 2026-04-22

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

### Migration

Non-breaking. All existing consumers continue to work without changes.

To adopt the new bare-descriptor pattern, drop `files:` and (optionally) `estimatedSizeBytes` from each `ComponentDescriptor`. `ensureComponentReady` hydrates transparently on first call. See [USAGE.md](USAGE.md) for a before/after example.

---

## [0.7.3] and earlier

See git log for history prior to v0.8.0.
