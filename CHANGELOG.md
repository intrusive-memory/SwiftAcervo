# Changelog

All notable changes to SwiftAcervo are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.11.0] - 2026-05-03

### Added

- **`acervo delete <model-id>`** — new subcommand that removes a model from one or more storage tiers. Scope flags: `--local` (implies both `--staging` and `--cache`), `--staging` (purges `$STAGING_DIR/<slug>`), `--cache` (purges the App Group cache via `Acervo.deleteModel`), `--cdn` (purges every object under `models/<slug>/` via `Acervo.deleteFromCDN`). `--cdn` prompts for TTY confirmation; `--yes` bypasses for CI/non-TTY runs. `--dry-run` previews without performing.
- **`acervo recache <model-id> [files...]`** — new subcommand that re-pulls a model from HuggingFace into the staging directory and atomically republishes it to the CDN via `Acervo.recache`. The orphan-prune step runs by default; pass `--keep-orphans` to retain stale keys. Off-TTY runs that would prune require `--yes`.
- **`TTYConfirm`** helper — shared confirmation primitive used by destructive subcommands. TTY → prompts. Non-TTY without `--yes` → throws `AcervoToolError.confirmationRequired` with a clear message instructing the user to pass `--yes`.
- **`CredentialResolver`** — resolves `AcervoCDNCredentials` from `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `R2_ENDPOINT` / `R2_PUBLIC_URL` (required) plus `R2_BUCKET` / `R2_REGION` (optional with defaults). The library never reads from `ProcessInfo.environment`; this lives in the CLI target only.

### Migration

The existing `acervo ship` / `upload` / `download` commands are unchanged and still work as before. The new `delete` and `recache` commands cover the workflow needed to retire CI-driven model caching in favor of doing it manually from a maintainer's machine.

---

## [0.10.1] - 2026-05-03

### Added

- **`Acervo.deleteFromCDN(modelId:credentials:progress:)`** — purges every object under `models/<slug>/` from the CDN. Iterative list/bulk-delete loop; idempotent on an empty prefix; non-atomic by design (nothing to be consistent with after a delete). Emits `AcervoDeleteProgress.listingPrefix` / `.deletingBatch` / `.complete`.
- **`Acervo.recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:)`** — composes a caller-supplied `fetchSource` closure with `Acervo.publishModel` so a script can re-pull a model from any source (the CLI shells out to `hf`, but a future caller could substitute git, S3, a tarball, etc.) and atomically republish it. A throwing `fetchSource` surfaces as `AcervoError.fetchSourceFailed(modelId:underlying:)`.

### Migration

Non-breaking. Both functions are additive. Consumers that already call `Acervo.publishModel` directly are unaffected.

---

## [0.10.0] - 2026-05-03

### Added

- **CDN mutation library** — internal SigV4-signing primitives plus `S3CDNClient` providing `list`, `head`, `delete`, `deleteObjects`, and multipart `putObject` against the private R2 bucket. Foundation-only (no `aws` CLI on the path), with canonical AWS test vectors covering every signing edge case.
- **`Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:)`** — orchestrator that walks the frozen 11-step ship sequence (verify-tree → upload-files → re-list → optional orphan-prune → upload-manifest LAST → public read-back). `manifest.json` is always the final PUT, so a publish that aborts mid-way leaves the CDN with no fresh manifest pointing at half-uploaded files.
- **`AcervoPublishProgress` / `AcervoDeleteProgress`** — typed progress streams emitted by `publishModel` / `deleteFromCDN` with per-file status, totals, and final summary.
- **New `AcervoError` cases** for CDN mutation failures: `manifestNotLast`, `corruptManifestUploaded`, `sampleFileMismatch`, `cdnSigningFailed`, `cdnPutObjectFailed`, `cdnListObjectsFailed`, `cdnDeleteObjectsFailed`, `partialPrune`, plus a `keepOrphans` opt-out for catalog migrations that intentionally leak files.
- **`ManifestGenerator`** lifted from `Sources/acervo/` into the public `SwiftAcervo` module so consumers can reuse manifest synthesis without depending on the CLI binary.

### Changed

- **Per-platform xctestplans** — `SwiftAcervo-macOS.xctestplan` runs `SwiftAcervoTests` + `AcervoToolTests`; `SwiftAcervo-iOS.xctestplan` runs `SwiftAcervoTests` only (the `acervo` CLI target uses `Foundation.Process`, which is unavailable on iOS). Each plan owns the `ACERVO_APP_GROUP_ID` env var. CI passes `-testPlan` per job.
- **Cross-platform manifest coverage** — `ManifestGeneratorTests` and the integrity invariants previously gated to macOS now run inside `SwiftAcervoTests`, exercising the lifted `ManifestGenerator` directly on iOS as well.

### Fixed

- **Cache-harden post-upload public-readback verification** — the final `publishModel` step that re-fetches the just-uploaded manifest from the public CDN now defeats edge caches that briefly served the prior generation, eliminating spurious `sampleFileMismatch` failures on tight publish loops.

---

## [0.9.0] - 2026-05-02

### Changed (Breaking)

- **Removed `Acervo.customBaseDirectory`** and the `~/Library/Application Support/SwiftAcervo/SharedModels/` fallback that previously lived behind it. `Acervo.sharedModelsDirectory` now resolves the App Group identifier from one of two sources, in order:
  1. `ACERVO_APP_GROUP_ID` environment variable (CLIs, scripts, test runners — typically set in `~/.zprofile`).
  2. First entry of the running binary's `com.apple.security.application-groups` entitlement (macOS UI apps; read via `SecTaskCopyValueForEntitlement`).
  If neither source supplies a value, the property traps with `fatalError` — there is no silent per-process fallback, on purpose.
- **macOS path layout** is now computed deterministically as `~/Library/Group Containers/<group-id>/SharedModels/`. Signed UI apps and unsigned CLIs land at the same directory by construction, so a model downloaded by either is immediately visible to the other.
- **iOS path layout** continues to resolve via `containerURL(forSecurityApplicationGroupIdentifier:)`. iOS consumers must supply the group ID through `ACERVO_APP_GROUP_ID` because `SecTaskCopyValueForEntitlement` is not part of the public iOS SDK.

### Migration

Consumers that referenced `Acervo.customBaseDirectory` (e.g. SwiftBruja and SwiftProyecto test suites) will not compile against this version. Replace test-time path overrides with the `ACERVO_APP_GROUP_ID` environment variable — set it to a unique value per test for isolation, and clean up the resolved Group Containers directory in teardown.

For interactive shells and CLI tools, export the canonical group ID in `~/.zprofile`:

```sh
export ACERVO_APP_GROUP_ID=group.intrusive-memory.models
```

`xcodebuild` does not propagate shell env vars into the xctest runner; SwiftAcervo's checked-in scheme at `.swiftpm/xcode/xcshareddata/xcschemes/SwiftAcervo-Package.xcscheme` declares `ACERVO_APP_GROUP_ID=group.acervo.testbundle.default` in its `<EnvironmentVariables>` block so `make test` and CI work without shell setup.

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
