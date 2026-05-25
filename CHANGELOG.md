# Changelog

All notable changes to SwiftAcervo are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.17.0] - Unreleased

### Fixed

- **`Acervo.ensureComponentReady(_:)` now registers with `InFlightDownloads.shared` for the duration of the underlying download.** Through 0.16.x the component-keyed download path bypassed the in-flight registry entirely, so `Acervo.availability(repoId)` returned `.partial` or `.notAvailable` while a download was in flight instead of the documented `.downloading(progress:)`. UI consumers polling `availability(_:)` saw no progress and no state transitions for multi-component models (PixArt-Sigma XL, FLUX.2, etc.); progress bars stayed at zero and "Download failed" error rows persisted through subsequent successful downloads. The registry is cleared on both the success and failure paths via `defer`.

  Progress ticks now publish through the existing `InFlightDownloads.shared.publishProgress(_:for:)` actor. Dedup semantics match `Acervo.ensureAvailable`: concurrent `ensureComponentReady` calls for the same `repoId` converge on a single underlying Task; the joiner's caller-supplied `progress` callback does not receive ticks, but UI consumers polling `availability(_:)` see `.downloading` regardless.

  No API change at the call site — purely a behavior fix.

### Added

- **`AcervoTelemetryEvent.inFlightDownloadRegistered(modelID:componentID:role:)`.** Emitted once per `ensureComponentReady` call that performs a download (not on cache hit). The `role` field (`InFlightRole.originator | .joiner`) distinguishes the caller that started the underlying Task from concurrent callers that joined it.

- **`AcervoTelemetryEvent.inFlightDownloadCleared(modelID:componentID:outcome:)`.** Emitted from the originator's `defer` block when the registry entry is cleared, regardless of outcome. The `outcome` field (`InFlightOutcome.success | .failure`) reports whether the underlying Task threw.

- **Internal test seam: `session: URLSession? = nil`** on internal overloads of `downloadComponent`, `ensureComponentReady`, and `ensureComponentsReady` so tests can drive the component-keyed download path through `MockURLProtocol`. Public API surface is unchanged.

### Breaking changes

- **`AcervoTelemetryEvent` adds two cases.** `switch` statements over `AcervoTelemetryEvent` without `@unknown default` will fail to compile until `case .inFlightDownloadRegistered` and `case .inFlightDownloadCleared` arms are added. See [`Docs/UPGRADING-library.md`](Docs/UPGRADING-library.md) § "Upgrading to 0.17.0 (from 0.16.x)" for the migration recipe.

---

## [0.15.0] - 2026-05-23

### Changed

- **`acervo ship` and `acervo upload` no longer require the `aws` CLI.** CDN uploads now
  go through the library's native SigV4 client (`Acervo.publishModel`). The `aws` binary
  is not checked for, not invoked, and not listed as a runtime dependency. Only `hf`
  (HuggingFace CLI) is required, and only by `ship` and `download`.

- **Orphan prune is now the default for `ship` and `upload`.** After a successful publish,
  CDN keys not referenced by the new manifest are deleted. This matches the manifest-truth
  model that `recache` already follows. The previous additive-only behavior (no deletes) is
  preserved via a new `--keep-orphans` flag.

  > **Operator upgrade note**: If you have scripts or workflows that rely on the previous
  > additive-only behavior of `acervo ship` or `acervo upload` — for example, to keep
  > prior-version files on the CDN alongside a new upload — add `--keep-orphans` to your
  > invocation to restore the old behavior. Without the flag, keys not in the new manifest
  > are deleted after CHECK 6 passes.

- **`--keep-orphans` flag added to `acervo ship` and `acervo upload`.** Pass this flag to
  skip the orphan-prune step. Default (no flag) prunes.

### Removed

- **`CDNUploader` (internal).** The internal `CDNUploader` class that shelled out to
  `aws s3 sync` has been deleted. `ShipCommand` and `UploadCommand` now call
  `Acervo.publishModel` directly, which drives all CDN traffic through the native SigV4
  stack. There is no public API change — `CDNUploader` was always an internal implementation
  detail.

### Internal

- **CLI tests rewritten against `MockURLProtocol`.** `ShipCommandTests` and
  `UploadCommandTests` no longer test for `aws` subprocess invocations. All CDN-path
  assertions now drive a `MockURLProtocol`-backed `URLSession`, matching the pattern
  already established by `S3CDNClientTests` and `PublishModelTests`.

---

## [0.14.0] - 2026-05-18

> **Migrating from 0.13.x?** Read [`UPGRADING.md`](UPGRADING.md) for the per-call-site disposition guide.

### Added

- **`ModelAvailability` enum** — Three-state availability marker with cases `.notAvailable`, `.downloading(progress: Double)`, and `.available`. Conforms to `Sendable` and `Equatable`.
- **`Acervo.availability(_:)` and `AcervoManager.availability(_:)`** — The canonical three-state read API for model status. Non-throwing, performs no network I/O. For models with downloads in flight (tracked by `InFlightDownloads`), returns `.downloading(progress:)`. See [USAGE-library.md](Docs/USAGE-library.md) for the design contract.
- **`Acervo.isModelConfigPresent(_:)`** — Explicit escape hatch for callers that genuinely only want to probe for `config.json` at the model root. Does NOT imply usability or completeness. Callers migrating from the old `isModelAvailable` loose semantics may use this to retain the original behavior if required.
- **`InFlightDownloads` actor** (internal) — Process-wide registry of in-flight downloads. Two concurrent `ensureAvailable(modelId, ...)` calls for the same `modelId` now share a single underlying download task. The dedup key is `modelId` alone; a joiner that requests a different `files` subset rides on the originator's set. Production callers pass `files: []` (everything in the manifest), so this trade-off is rarely observable.
- **Manifest persistence on disk** — After each successful `downloadFiles`, the CDN manifest is cached at `{baseDirectory}/{slug}/.acervo-manifest.json`. Used by the new strict `isModelAvailable` (see Changed) and by `availability(_:)` to report file completeness.
- **`IntegrityVerification.allManifestFilesPresentBySize(manifest:in:)` and `IntegrityVerification.partialFileSize(at:)` (internal)**  — Helper functions for manifest-aware file completeness checks.

### Changed (BREAKING SEMANTIC)

- **`Acervo.isModelAvailable(_:)` now enforces strict verification.** Returns `true` only when every file declared in the cached manifest is present on disk at the manifest's recorded `sizeBytes`. The previous loose semantics — "returns `true` if `config.json` exists at the model root" — are now available exclusively via the new `isModelConfigPresent(_:)` escape hatch. Callers that intentionally want the loose probe (original behavior) must migrate to `isModelConfigPresent`. Callers that want "model is fully usable" should switch to `availability(_:)` for a three-state answer with observable in-flight downloads. See [USAGE-library.md](Docs/USAGE-library.md) § "2a. Status surfaces today" for migration guidance.
- **`ensureAvailable(_:files:...)` deduplication semantics.** Two concurrent callers requesting the same `modelId` now share the underlying download, even if they pass different `files` subsets. The joiner's `files` parameter is ignored; it rides on the originator's set. Production code passes `files: []` (everything in the manifest), so this is rarely observable. Tests that exercise narrow file subsets concurrently against the same model should be aware of the dedup behavior.

---

## [0.13.2] - 2026-05-18

### Changed

- **Resumable downloads via `.part` files.** Temp files now live at `{destination}.part` (same volume as the final file) and survive transient failures. On retry, downloads send `Range: bytes=<partial-size>-`; if the server responds 200 instead of 206, the partial bytes are discarded and the full body is consumed. The cross-volume `moveItem` (App Group container vs system temp directory) is incidentally avoided since the part file is co-located with the destination. (See `REQUIREMENTS.md` § 4.5.)
- **Removed cleanup-only paths in `streamDownloadFile`** that deleted partial bytes on every transient failure. Part files are now deleted only on validated corruption (oversize, SHA mismatch, size mismatch) or successful completion. (See `REQUIREMENTS.md` § 4.6.)

### Internal

- Added `IntegrityVerification.partialFileSize(at:)`.

### Not included (deferred to a follow-up release)

- **Chunked streaming** (REQUIREMENTS § 4.4). The per-byte `for try await byte in asyncBytes` loop is unchanged. A dedicated mission with its own perf bench will ship the `URLSessionDataDelegate`-based rewrite. Do not advertise chunking as a change in this release.

---

## [0.13.1] - 2026-05-16

### Added

- **Telemetry on component-keyed APIs.** `Acervo.hydrateComponent`, `Acervo.downloadComponent`, `Acervo.ensureComponentReady`, and `Acervo.ensureComponentsReady` now accept a defaulted `telemetry: (any AcervoTelemetryReporter)?` parameter and route events (manifest fetch, component download, cache state, errors) through it. Hosts like SwiftVinetas that wire a reporter at the component layer now see `kind: "acervo"` events for the manifest-destiny flows.
- **`AcervoManager` component-lifecycle wrappers.** `ensureComponentReady(_:)`, `ensureComponentsReady(_:)`, `downloadComponent(_:force:)`, and `hydrateComponent(_:)` on `AcervoManager` forward `self.telemetry` to the static surface, so a single `AcervoManager.shared.setTelemetry(reporter)` call is sufficient to capture component-keyed events without threading a reporter through every call site.
- **Three new `AcervoTelemetryEvent` cases:**
  - `componentResolveStart(componentID:repoID:)` — fires at the top of `ensureComponentReady`.
  - `componentResolveComplete(componentID:repoID:fileCount:totalBytes:cacheState:durationSeconds:)` — fires on the cache-hit short-circuit and on the post-download path; `cacheState` is one of `.alreadyReady`, `.downloaded`, `.hydratedOnly`.
  - `componentFileAccessOpened(componentID:repoID:baseDirectory:fileCount:)` — fires from `AcervoManager.withComponentAccess` immediately before the closure runs, naming the on-disk directory that backs the handle.
- **`AcervoManager.currentTelemetry` accessor** for tests that need to snapshot/restore the attached reporter around mutating code paths.

### Changed

- `AcervoTelemetryMockReporterTests.testSetTelemetryNilSilencesEvents` now asserts a zero *delta* on the detached reporter rather than an absolute zero count. Parallel suites that exercise `AcervoManager.shared.withComponentAccess` (which now emits) can transiently observe events during the brief window the reporter is attached; the contract being tested — "downloadFiles with telemetry: nil does not push events into a detached reporter" — is unchanged.

---

## [0.13.0] - 2026-05-12

### Added

- **`AcervoTelemetryEvent` public enum** — 14 cases covering the full download lifecycle: `downloadOperationStart`, `downloadOperationComplete`, `componentDownloadStart`, `componentDownloadComplete`, `manifestFetchStart`, `manifestFetchComplete`, `integrityVerifyStart`, `integrityVerifyComplete`, `cacheHit`, `cacheMiss`, `cdnRequest`, `modelLoadComplete`, `errorThrown`, plus nested `CacheMissReason` (5 cases: `.notPresent`, `.shaChangedRemote`, `.sizeChangedRemote`, `.corrupted`, `.forcedRefresh`) and `ErrorPhase` (11 cases: `.manifestDownload`, `.manifestDecode`, `.manifestVersionUnsupported`, `.manifestIntegrity`, `.fileDownload`, `.fileDownloadSize`, `.fileDownloadIntegrity`, `.directoryCreation`, `.offlineMode`, `.s3Request`, `.other`) enums. Conforms to `Sendable`.
- **`AcervoTelemetryReporter` public protocol** — single `async` non-throwing `capture(_:)` method; conforms to `Sendable`. Host adopters implement this to receive telemetry events.
- **`NoopAcervoTelemetryReporter` public struct** — zero-overhead no-op implementation (`async capture(_:) {}`) for consumers who want telemetry wired but not yet routed. The body is empty, so per-call cost is bounded by the `await` overhead (sub-microsecond).
- **`setTelemetry(_:)` on `AcervoManager`, `ModelDownloadManager`, `S3CDNClient`, and `ManifestGenerator`** — each accepts an optional `(any AcervoTelemetryReporter)?`; `nil` disables reporting with zero call-site overhead (guard-nil skip pattern at every emission site).
- **Defaulted `telemetry:` parameter on `Acervo.download`, `Acervo.publishModel`, `Acervo.deleteModel`/`Acervo.deleteFromCDN`, and `Acervo.ensureAvailable`** — all default to `nil`; existing call sites compile unchanged.
- **9 distinct emission sites** wired across `Acervo.swift`, `AcervoManager.swift`, `AcervoDownloader.swift`, `S3CDNClient.swift`, and `IntegrityVerification.swift`.
- **`errorThrown` wired at every throw site** in `AcervoDownloader.swift` and `ModelDownloadManager.swift` (24 throw sites, 24 paired emissions). Each emission fires immediately before the `throw`, satisfying event-before-throw ordering.
- **3 new test files** in `Tests/SwiftAcervoTests/`:
  - `AcervoTelemetryMockReporterTests.swift` — mock reporter, full lifecycle ordering assertions, and `setTelemetry(nil)` zero-event sanity check.
  - `AcervoTelemetryCacheMissReasonTests.swift` — drives each `CacheMissReason` case deterministically.
  - `AcervoTelemetryIntegrityFailureTests.swift` — injects a wrong-SHA file; asserts `integrityVerifyComplete(passed: false)` and `errorThrown(phase: .fileDownloadIntegrity)` fire before the throw propagates.

### Changed (non-breaking)

- **`IntegrityVerification.verifyAgainstManifest` is now `async`** — internal-only signature change required to support `await telemetry.capture(...)` with event-before-throw ordering. The only internal caller (`AcervoDownloader.fallbackDownloadFile`) was updated. Public `Acervo.verifyComponent` / `Acervo.verifyAllComponents` API is unchanged.

### Known Limitations

- `downloadOperationComplete.totalBytes` is always `0`; consumers should sum `componentDownloadComplete.actualBytes` across a download operation.
- `componentDownload` duration includes TCP handshake (~50–100ms skew on cold CDN); the measurement point is just before the per-file `downloadFile` call, not at start-of-body-read.
- Verify-on-read API (`Acervo.verifyComponent`, `Acervo.verifyAllComponents`) does not emit telemetry; only the download-path integrity check emits `integrityVerifyStart` / `integrityVerifyComplete`.
- Two `CacheMissReason` cases (`.shaChangedRemote`, `.corrupted`) are not yet reachable from real code paths (cache check is size-only); they are present in the enum for forward compatibility.
- Streaming download integrity failures emit `errorThrown(.fileDownloadIntegrity)` only; the fallback download path emits the full `integrityVerifyComplete(passed: false)` + `errorThrown` pair.

### Migration

Non-breaking. All existing consumers continue to work without changes. To start receiving telemetry, implement `AcervoTelemetryReporter` and call `setTelemetry(_:)` on `AcervoManager` or `ModelDownloadManager`, or pass the reporter directly to `Acervo.download` / `Acervo.ensureAvailable` / `Acervo.publishModel` / `Acervo.deleteFromCDN`.

---

## [0.12.0] - 2026-05-06

### Added

- **Bundle component pattern** — multiple `ComponentDescriptor`s can now share a `repoId` (a single CDN manifest covering many logical components) as a documented, first-class supported shape. Registering N distinct component IDs against the same `repoId` never fires the re-register canary; the canary continues to fire only for genuine `id`-collisions. See [USAGE-library.md — Bundle Components](USAGE-library.md#bundle-components) for declaration examples and the full R1–R6 contract guarantees.

### Fixed

- **`deleteComponent` is now sibling-safe for bundle components** — previously, calling `deleteComponent` on any component removed the entire `org_repo/` slug directory, destroying all sibling components that shared the same `repoId`. The new implementation iterates the component's declared `files` and removes only those files, then prunes empty subdirectories up to (but not including) the slug directory. The slug directory itself is removed only when it is completely empty (all bundle components deleted). This behavioral change is **additive**: consumers using the existing 1:1 per-component-manifest pattern see identical results (their slug directory becomes empty after the single component is deleted, so it is removed exactly as before).

### Migration

Non-breaking. All existing consumers continue to work without changes. Plugin authors targeting bundled repos (such as `black-forest-labs/FLUX.2-klein-4B`) can now declare one `ComponentDescriptor` per logical component using the explicit-files initializer — see [USAGE-library.md](USAGE-library.md#bundle-components) for a worked example.

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
- Consumer documentation (USAGE-library.md, README.md, AGENTS.md, CLAUDE.md, GEMINI.md) restructured around the manifest-first contract: *consumers do not know what files exist in a model until the CDN manifest returns*. Hardcoded `files: [...]` arrays are now framed as an escape hatch, not the default pattern.

### Release Engineering

- `acervo` CLI version bumped from `0.7.0` to `0.8.0` to match the library.
- `Tests/AcervoToolIntegrationTests/` removed. The `acervo ship` roundtrip (HuggingFace → manifest → R2 upload → verify) is now exercised in each downstream repository's model-publish workflow against that repo's scoped credentials; SwiftAcervo itself never uploads.
- New `Tests/AcervoToolTests/CDNManifestFetchTests.swift` — no-credential read-only smoke against the public R2 URL. Fetches a known-published manifest, verifies the checksum-of-checksums, spot-checks one file's SHA-256. Wired into PR CI.
- `USAGE-library.md` now surfaces the `group.intrusive-memory.models` App Group entitlement setup as a first-class integration step. Apps without the entitlement silently fall back to a non-shared path — now called out up front.

### Migration

Non-breaking. All existing consumers continue to work without changes.

To adopt the new bare-descriptor pattern, drop `files:` and (optionally) `estimatedSizeBytes` from each `ComponentDescriptor`. `ensureComponentReady` hydrates transparently on first call. See [USAGE-library.md](USAGE-library.md) for a before/after example.

---

## [0.7.3] and earlier

See git log for history prior to v0.8.0.
