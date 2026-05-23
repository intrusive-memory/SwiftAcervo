# SwiftAcervo `Acervo.swift` Decomposition Plan

## Provenance

- **Analyzed against HEAD SHA**: `5c7163c5771895d651ffb0587d67696e2f15c096`
  ("state(em-2): mark COMPLETED at commit b10cdb2")
- **`Acervo.swift` size at that SHA**: 2777 lines, 110,101 bytes
- **EM-3 status**: Not committed at time of analysis. Working tree has uncommitted edits to `Acervo.swift` and a new `Tests/SwiftAcervoTests/EM3LocalModelsHousekeepingTests.swift` (614 lines) that references a new `Acervo.localModels` method and exercises `Acervo.gcEmptyModelDirectories` heavily. Polled for ~3 minutes after instructions, then proceeded against the committed HEAD rather than continue waiting. **Caveat**: when EM-3 lands, the section that grew most is likely *Discovery* (gc + localModels housekeeping). The plan below already places those in `Acervo+Discovery.swift`, so EM-3's additions will fit the proposed split unchanged. Re-confirm post-EM-3 by re-running the inventory grep.

---

## 1. Inventory of `Acervo.swift`

| # | Section (MARK) | Lines | ~LOC | Visibility mix | Functional category | Test coverage |
|---|---|---|---|---|---|---|
| 1 | Enum root: `version`, offline env helpers | 28-52 | 25 | public/internal | meta | indirect (OfflineModeGateTests) |
| 2 | **Path Resolution** | 54-279 | 226 | public + private | path resolution | AcervoPathTests, AcervoAvailabilityTests (slugify) |
| 3 | **Availability** (legacy/cached) | 281-400 | 120 | public + internal | availability (offline) | AcervoAvailabilityTests, AcervoDownloadAPITests |
| 4 | **Model Discovery** | 402-639 | 238 | public + internal/private | discovery, listing, gc | AcervoDiscoveryTests, AcervoFilesystemEdgeCaseTests, EM3LocalModelsHousekeepingTests |
| 5 | **Pattern Matching** | 641-687 | 47 | public + internal | search (glob) | AcervoSearchTests |
| 6 | **Fuzzy Search** | 689-834 | 146 | public + private | search (fuzzy) | AcervoFuzzySearchTests |
| 7 | **Model Families** | 836-884 | 49 | public + internal | families | AcervoFuzzySearchTests |
| 8 | **Directory Size Calculation** | 886-933 | 48 | public + private | sizing | indirect (CatalogHydrationTests via totalCatalogSize) |
| 9 | **Download API** (legacy) | 935-1081 | 147 | public + internal | download orchestration | AcervoDownloadAPITests |
| 10 | **Ensure Available** (legacy, repo-keyed) | 1083-1257 | 175 | public + internal | ensure-available orchestration | AcervoDownloadAPITests, AvailabilityThreeStateTests, EnsureAvailableEmptyFilesTests |
| 11 | **Delete Model** (legacy) | 1259-1314 | 56 | public + internal | mutation (delete) | AcervoDownloadAPITests |
| 12 | **Delete Model (slug-keyed)** | 1316-1422 | 107 | public + internal | mutation (delete, slug) | SlugDeleteModelTests |
| 13 | **Component Registration** | 1424-1476 | 53 | public | registry facade | ComponentRegistryTests, HydrateComponentTests, HydrationTests, ManifestFetchTests |
| 14 | **Component Catalog** | 1478-1645 | 168 | public + internal | catalog queries | CatalogHydrationTests, ComponentDownloadTests |
| 15 | **Integrity Verification** | 1647-1747 | 101 | public + internal | integrity | IntegrityVerificationTests |
| 16 | **Manifest Access** | 1749-1806 | 58 | public | manifest fetch facade | ManifestFetchTests |
| 17 | **Hydration** (+`HydrationCoalescer` actor) | 1808-1921 | 114 | public + internal/private + actor | hydration | HydrateComponentTests, HydrationTests |
| 18 | **Component Downloads** | 1923-2166 | 244 | public + internal | component download orchestration | ComponentDownloadTests, DownloadComponentAutoHydrationTests, ComponentIntegrationTests |
| 19 | **Component Deletion** | 2168-2232 | 65 | public + internal | mutation (delete component) | ComponentDownloadTests |
| 20 | **Availability (three-state)** | 2234-2324 | 91 | public + internal | availability (live, 3-state) | AvailabilityThreeStateTests |
| 21 | **Availability (slug-keyed, multi-component)** | 2326-2560 | 235 | public + internal | slug availability + manifest fetch | SlugAvailabilityTests |
| 22 | **Ensure Available (slug-keyed, multi-component)** | 2562-2777 | 216 | public + internal | slug ensure-available | SlugEnsureAvailableTests |

Total: 2777 lines. Heaviest sections: Discovery (238), Component Downloads (244), slug Availability (235), Ensure Available slug (216), Path Resolution (226), Ensure Available legacy (175), Component Catalog (168).

---

## 2. Proposed File Split

All new files follow the established convention already visible in `Sources/SwiftAcervo/`: top-level concerns become sibling files; `Acervo`-namespaced APIs use `extension Acervo { ... }` in a file named `Acervo+<Concern>.swift`. The existing sibling `Acervo+CDNMutation.swift` is the precedent template.

| # | Proposed file | Moves from §1 | Shape | Est. lines | Rationale |
|---|---|---|---|---|---|
| F1 | `Acervo+PathResolution.swift` | §2 (path resolution) | `extension Acervo` + private helpers | ~230 | Self-contained: entitlements, app group, `slugify`, `modelDirectory`, `ensureModelDirectory`, `excludeFromBackup`. Read by everyone but has no inbound deps beyond Foundation. Single cleanest cut. |
| F2 | `Acervo+Availability.swift` | §3 + §20 (legacy + 3-state, repo-keyed) | `extension Acervo` | ~215 | Both legacy `isModelAvailable`/`isModelConfigPresent`/`modelFileExists` and the 3-state `availability(_:verifyHashes:)` are repo-keyed availability semantics that share `ValidityOracle` plumbing. Co-locating them keeps the oracle's two callers next to each other. |
| F3 | `Acervo+Discovery.swift` | §4 + §7 + §8 (listing, families, dir-size, gc) | `extension Acervo` | ~340 | Local filesystem enumeration. EM-3's incoming `localModels` and expanded gc work also belong here, so this is the home for that work. Largest of the new files but cohesive (all walk the SharedModels root). |
| F4 | `Acervo+Search.swift` | §5 + §6 (pattern + fuzzy) | `extension Acervo` | ~200 | Pure query-over-listing: glob `findModels`, fuzzy `findModels(matching:tolerance:)`, `closestModel`. Reads from §4's listings; one obvious boundary. |
| F5 | `Acervo+Download.swift` | §9 (Download API) | `extension Acervo` | ~150 | Legacy `Acervo.download(...)`. Pure orchestration; delegates real work to `AcervoDownloader`. Already thin. |
| F6 | `Acervo+EnsureAvailable.swift` | §10 (legacy) + §22 (slug-keyed) | `extension Acervo` | ~395 | Both repo-keyed and slug-keyed ensure-available share the same `progress`/aggregator contract and call each other (the slug-keyed variant fans out to the repo-keyed one). Co-locating prevents drift. Slightly over target — see §6 Risks. |
| F7 | `Acervo+SlugAvailability.swift` | §21 + the helpers `isOrgRepoSlug`, `componentTotalBytes`, `fetchSlugManifest` | `extension Acervo` | ~240 | Slug-keyed availability is a discrete public API surface introduced in slug-registry/S2. Helpers it owns are file-private to this concern (currently `internal static` at file scope, used by F6 as well). To preserve cross-file access, keep these `internal static` — Swift lets sibling files in the same module see them. |
| F8 | `Acervo+DeleteModel.swift` | §11 + §12 (legacy + slug-keyed) | `extension Acervo` | ~170 | Two delete variants share semantics ("remove from disk + clean up registry/manifest cache"). They sit next to `Acervo+CDNMutation.swift` (which deletes from CDN); the symmetry is intentional. |
| F9 | `Acervo+ComponentRegistration.swift` | §13 (registration façade) | `extension Acervo` | ~55 | Thin pass-through to `ComponentRegistry.shared`. Tiny; could merge with F10 if file-count is a concern. Recommending separate because it is the API surface for "tell Acervo about a component" — different audience than "query the catalog". |
| F10 | `Acervo+ComponentCatalog.swift` | §14 (catalog queries) | `extension Acervo` | ~175 | Read-side: `isComponentReady`, `pendingComponents`, `totalCatalogSize`, `unhydratedComponents`. Uses §13's registry; both small enough to live as siblings. |
| F11 | `Acervo+ComponentIntegrity.swift` | §15 (integrity) | `extension Acervo` | ~110 | `verifyComponent`/`verifyAllComponents`. Delegates to `IntegrityVerification` sibling type; the `extension Acervo` glue is small but cohesive. |
| F12 | `Acervo+ManifestAccess.swift` | §16 (manifest fetch facades) | `extension Acervo` | ~65 | Four `fetchManifest(...)` overloads. Pure passthroughs to `AcervoDownloader.downloadManifest`. |
| F13 | `Acervo+Hydration.swift` | §17 (hydration + `HydrationCoalescer`) | `extension Acervo` + `internal actor` | ~120 | Self-contained, mirrors the `ValidityOracle.swift` extraction template (concern + helper type in one file). |
| F14 | `Acervo+ComponentDownloads.swift` | §18 + §19 (component downloads + deletion) | `extension Acervo` | ~310 | Both call `AcervoDownloader.downloadComponent` and operate on the same component-directory layout. Largest of the new files. Could be split if §6's risk materializes. |
| **Residual** | `Acervo.swift` | §1 only | `public enum Acervo { ... }` | **~55** | Just the `Acervo` enum shell, `version`, and the offline-mode env vars. Every other concern lives in its own sibling extension. |

**Sanity check** — sum of estimated lines: 230+215+340+200+150+395+240+170+55+175+110+65+120+310+55 ≈ **2830** (vs original 2777). The ~50 line overhead is per-file headers (`import`, comment block matching the `ValidityOracle.swift` template).

**Target met**: no file proposed over ~400 lines. F6 (Ensure Available combined) is the closest to the 600-line ceiling and the most likely candidate to split further if review prefers.

---

## 3. Public-API Impact

Every public symbol moving is one of: `public static func`, `public static var`, `public static let`. All move into `extension Acervo { ... }` declared in a sibling file **within the same module**. Swift makes such moves **fully source-compatible** to all consumers — the symbol's fully-qualified name (`Acervo.foo(...)`) does not change, ABI does not change, doc references do not break.

**Symbols moving (public)** — grouped by destination file:

- F1: `appGroupEnvironmentVariable`, `sharedModelsDirectory`, `slugify(_:)`, `modelDirectory(for:)`, `ensureModelDirectory(for:)`
- F2: `isModelAvailable(_:)`, `isModelConfigPresent(_:)`, `modelFileExists(_:fileName:)`, `availability(_:verifyHashes:)`
- F3: `listModels()`, `gcEmptyModelDirectories()`, `modelInfo(_:)`, `modelFamilies()` *(plus EM-3's pending `localModels` when it lands)*
- F4: `findModels(matching:)`, `findModels(matching:tolerance:in:)`, `closestModel(to:in:tolerance:)`
- F5: `download(_:files:progress:telemetry:)`
- F6: `ensureAvailable(_:files:progress:telemetry:)`, `ensureAvailable(slug:url:files:progress:telemetry:)`
- F7: `availability(slug:url:telemetry:)`
- F8: `deleteModel(_:)`, `deleteModel(slug:url:)`
- F9: `register(_:)` ×2, `unregister(_:)`
- F10: `registeredComponents()` ×2, `component(_:)`, `isComponentReady(_:)`, `isComponentReadyAsync(_:)`, `pendingComponents()`, `totalCatalogSize()`, `unhydratedComponents()`
- F11: `verifyComponent(_:)`, `verifyAllComponents()`
- F12: `fetchManifest(for:)`, `fetchManifest(forComponent:)` (+ session overloads)
- F13: `hydrateComponent(_:telemetry:)`
- F14: `downloadComponent(_:progress:telemetry:)`, `ensureComponentReady(_:progress:telemetry:)`, `ensureComponentsReady(_:progress:telemetry:)`, `deleteComponent(_:)`

**Non-source-compatible movements**: **none** detected. All `internal static` helpers used cross-section (e.g., `isOrgRepoSlug`, `componentTotalBytes`, `fetchSlugManifest`, `isModelAvailable(_:in:)`, `slugify(_:)`) remain `internal static` and are reachable from any other file in the module. `private static` symbols (`hydrationCoalescer`, `commonPrefixes`, `stripCommonPrefixes`, `directorySize`, `hasModelValidityMarker`) are file-private and stay with their owning extension.

**One special case — `HydrationCoalescer`**: defined `internal actor` at top level of `Acervo.swift`. Moving it into `Acervo+Hydration.swift` keeps it `internal` and module-visible. No external consumer references it (verified by `git grep "HydrationCoalescer"` would be a sortie's first step). No API impact.

---

## 4. Testability Gains

| New file | Companion test file (existing or proposed) | What becomes easier to test |
|---|---|---|
| F1 `Acervo+PathResolution.swift` | `AcervoPathTests.swift` (exists) | Already well-covered; the split lets future entitlement/env-var edge-cases land without diff noise in a 2777-line file. |
| F2 `Acervo+Availability.swift` | `AcervoAvailabilityTests.swift` + `AvailabilityThreeStateTests.swift` (exist) | Co-locates legacy + 3-state behind one extension; future test additions for `ValidityOracle` plumbing get an obvious home. |
| F3 `Acervo+Discovery.swift` | `AcervoDiscoveryTests.swift`, `AcervoFilesystemEdgeCaseTests.swift`, `EM3LocalModelsHousekeepingTests.swift` (exist; the last is in-flight) | EM-3's housekeeping work gets a focused file — review of EM-3's diff stops being "diff in a 2777-line file". |
| F4 `Acervo+Search.swift` | `AcervoSearchTests.swift` + `AcervoFuzzySearchTests.swift` (exist) | Already well-covered; the split makes the fuzzy/glob separation visible in source layout. |
| F5 `Acervo+Download.swift` | `AcervoDownloadAPITests.swift` (exists) | Already thin; split mainly improves grep-ability. |
| F6 `Acervo+EnsureAvailable.swift` | `EnsureAvailableEmptyFilesTests.swift`, `SlugEnsureAvailableTests.swift` (exist) + proposed `EnsureAvailableProgressAggregationTests.swift` | The slug-keyed `ComponentStateBox` aggregation logic is currently buried at the bottom of a 2777-line file; extracting it into its own file makes it obvious that it deserves its own focused test for thread-safety. |
| F7 `Acervo+SlugAvailability.swift` | `SlugAvailabilityTests.swift` (exists) | `fetchSlugManifest`/`isOrgRepoSlug` get an obvious home — future regression tests for slug parsing land in one place. |
| F8 `Acervo+DeleteModel.swift` | `AcervoDownloadAPITests.swift`, `SlugDeleteModelTests.swift` (exist) | Symmetry with `Acervo+CDNMutation.swift` (delete-from-CDN) becomes visible; mocking just the local-delete path no longer requires importing the whole download surface. |
| F9 + F10 (component registration + catalog) | `ComponentRegistryTests.swift`, `CatalogHydrationTests.swift` (exist) | Catalog read-side becomes mockable without spinning up downloads. |
| F11 `Acervo+ComponentIntegrity.swift` | `IntegrityVerificationTests.swift` (exists) | No change in coverage; cleaner file boundaries. |
| F12 `Acervo+ManifestAccess.swift` | `ManifestFetchTests.swift` (exists) | All four `fetchManifest` overloads in one ~65-line file is a very fast read. |
| F13 `Acervo+Hydration.swift` | `HydrateComponentTests.swift`, `HydrationTests.swift` (exist) + proposed `HydrationCoalescerTests.swift` | Once `HydrationCoalescer` is in its own file, it earns its own unit test (currently exercised only through integration). |
| F14 `Acervo+ComponentDownloads.swift` | `ComponentDownloadTests.swift`, `DownloadComponentAutoHydrationTests.swift`, `ComponentIntegrationTests.swift` (exist) | Largest behavioral surface; isolating it makes the contract review for any future component-download change tractable. |

No existing test references a top-level declaration that is moving — every test calls `Acervo.something(...)`, and those calls are 100% source-compatible across the split. Verified by grepping `Acervo\.` across `Tests/` (see §1 mapping table).

---

## 5. Execution Plan

**Sequencing principles applied**:
- Pure mechanical cut-and-paste extractions come first. No logic changes, no signature changes, no symbol renames. `make build && make test` must pass at every intermediate HEAD.
- Bottom-up: extract leaves first (no other extension calls into them), then concerns that depend on them.
- One extraction = one commit (atomic).

**Recommended commit sequence** (each item is one commit):

| Step | Commit | Why this order |
|---|---|---|
| 1 | Extract F12 `Acervo+ManifestAccess.swift` | Smallest, zero internal callers from siblings; pure facade over `AcervoDownloader`. Lowest risk, validates the extraction template. |
| 2 | Extract F1 `Acervo+PathResolution.swift` | Foundation for everything; once moved, the residual file has a much cleaner top. Every later step still compiles because `slugify`/`sharedModelsDirectory` remain `Acervo.*`. |
| 3 | Extract F11 `Acervo+ComponentIntegrity.swift` | Small, self-contained, uses only `ComponentRegistry` + `IntegrityVerification` siblings. |
| 4 | Extract F9 `Acervo+ComponentRegistration.swift` | Thin façade; precedes F10 which consumes it. |
| 5 | Extract F10 `Acervo+ComponentCatalog.swift` | Reads from F9; both safe after F9. |
| 6 | Extract F13 `Acervo+Hydration.swift` (incl. `HydrationCoalescer`) | Pulls actor + extension out together. |
| 7 | Extract F8 `Acervo+DeleteModel.swift` | Two related delete variants together. |
| 8 | Extract F5 `Acervo+Download.swift` | Standalone; legacy download API. |
| 9 | Extract F2 `Acervo+Availability.swift` | Combines §3 + §20 so the `ValidityOracle` consumers live together. |
| 10 | Extract F4 `Acervo+Search.swift` | After F3 (discovery) ideally, but order-independent since fuzzy/glob delegate via `Acervo.listModels`. |
| 11 | Extract F3 `Acervo+Discovery.swift` | Done *after* EM-3 lands and merges; the file is large because of EM-3's additions. If EM-3 has not landed, do this step last. |
| 12 | Extract F7 `Acervo+SlugAvailability.swift` | Pulls slug-helpers along; F6 next will continue to call them via `Acervo.fetchSlugManifest(...)` etc. |
| 13 | Extract F6 `Acervo+EnsureAvailable.swift` | Largest single file; combines legacy + slug-keyed because they share the aggregator contract. Done after F7 so the helpers exist as `Acervo.*` references. |
| 14 | Extract F14 `Acervo+ComponentDownloads.swift` | Largest behavioral surface; deliberately last so all leaf dependencies are already in their final homes. |

After step 14, `Acervo.swift` is ~55 lines (the enum shell + offline-mode helpers).

**No genuine refactors are part of this plan.** Every step is a mechanical move. Any subsequent refactor (e.g., extracting `ComponentStateBox` from F6 into its own testable type, or factoring the slug+url resolution rule duplicated between F6 and F7 into a single helper) belongs to a **follow-up plan** and is explicitly out of scope here.

**Sortie estimate (if converted into a mission)**: **5 sorties**, batched:
- Sortie 1: steps 1-4 (F12, F1, F11, F9) — all trivial, parallel-safe in code but should be sequential commits.
- Sortie 2: steps 5-7 (F10, F13, F8).
- Sortie 3: steps 8-10 (F5, F2, F4).
- Sortie 4: steps 11-13 (F3 after EM-3 lands, F7, F6).
- Sortie 5: step 14 (F14) — the largest single move; review-heavy.

Each sortie: ~3 commits, `make build && make test` after every commit, force-validate no symbol drift via `swift build -Xswiftc -warnings-as-errors`.

---

## 6. Risks, Non-Goals, and What's Not Touched

### Explicitly NOT splitting

- **The `Acervo` enum shell itself** (lines 28-52, with `version` + offline env helpers). It's tiny, every sibling extension implicitly extends it, and consolidating it elsewhere would create circular import vibes (even though Swift modules don't have file-level imports).
- **`HydrationCoalescer` further into its own file**. It is a 17-line internal actor used only by `Acervo.hydrateComponent`; co-locating it with its sole caller in F13 is more readable than spreading it across two files. If/when more single-flight coalescers appear, that's the time to extract a generic `SingleFlight<Key, Value>` helper — not now.
- **Legacy + slug-keyed `ensureAvailable` into separate files**. They cross-call (the slug-keyed variant delegates to the repo-keyed variant for each component) and share the aggregator contract. Co-locating in F6 keeps the contract visible. F6 is ~395 lines — under the 600-line ceiling, but the largest. If review finds it unwieldy, the natural split is `Acervo+EnsureAvailable.swift` (legacy) + `Acervo+SlugEnsureAvailable.swift` (slug) with the shared aggregator helper extracted to a new `EnsureAvailableAggregation.swift` sibling type. Defer that to a follow-up plan.

### Risks

- **File proliferation**. Going from 1 file → 15 files (1 residual + 14 new). The existing `Sources/SwiftAcervo/` already has 30+ files, and the project clearly tolerates a fine-grained layout (see `AcervoDeleteProgress.swift`, `AcervoPublishProgress.swift`, `AcervoDownloadProgress.swift` as three separate ~3KB files). So this risk is low for this codebase specifically, but it does double the file count of the `Acervo`-namespaced surface.
- **Circular import concerns**. None at the module level (it's all one module). Within-module visibility of `internal static` helpers is unaffected by file location.
- **Slug-registry coupling between F6 and F7**. F6 references `Acervo.fetchSlugManifest`, `Acervo.isOrgRepoSlug` which live in F7. If F7's helpers ever become `private`, F6 breaks. Mitigation: keep these `internal static` (their current visibility) and add a `// Used by: Acervo+EnsureAvailable.swift` comment when moving them.
- **EM-3 race**. EM-3 is mid-edit on the file. If EM-3 introduces a new top-level type or non-extension declaration before this mission starts, the inventory (§1) must be re-run. Do not start step 11 (F3 Discovery extraction) until EM-3 has merged.
- **Manager call sites** (`Sources/SwiftAcervo/AcervoManager.swift` references `Acervo.listModels`, `Acervo.download`, `Acervo.ensureComponentReady`, `Acervo.hydrateComponent`, `Acervo.availability`, `Acervo.slugify`, `Acervo.modelDirectory`, `Acervo.sharedModelsDirectory`, `Acervo.component`, `Acervo.isOfflineModeActive`). All resolve unchanged across the split — verified above in §3.
- **Test impact**: zero. No test file imports anything below the `public Acervo.*` surface (verified by the test-to-method mapping in §1).

### What this plan does NOT touch

- `AcervoManager.swift` actor surface — out of scope. Its method signatures are stable and downstream-consumed.
- `AcervoDownloader.swift` (62KB sibling) — already extracted; this plan does not propose further sub-division of it.
- `S3CDNClient.swift` (47KB sibling) — already extracted; not touched.
- `Acervo+CDNMutation.swift` (21KB sibling) — already extracted in the same pattern this plan recommends; not touched.
- No method signatures change. No symbols are renamed. No new types are introduced. No tests are added or removed.
- The `EXECUTION_PLAN.md` and `SUPERVISOR_STATE.md` for OPERATION EIGHTH-MASTER are not touched.

---

## Summary

- **Analyzed HEAD**: `5c7163c` ("state(em-2): mark COMPLETED at commit b10cdb2"). EM-3 had not landed at analysis time; plan accommodates EM-3's pending Discovery additions by placing them in F3.
- **`Acervo.swift` size at that SHA**: 2777 lines.
- **Three-sentence summary**: This plan proposes **14 new `Acervo+<Concern>.swift` sibling files** following the established `Acervo+CDNMutation.swift` template, leaving a **residual `Acervo.swift` of ~55 lines** that is just the enum shell plus the offline-mode env helpers. The split is entirely mechanical cut-and-paste with **zero public API breakage** (every `Acervo.foo(...)` call remains valid) and **zero test changes required**. If converted into a follow-up mission, this would take an estimated **5 sorties** of ~3 commits each, with `make build && make test` green at every intermediate HEAD.
