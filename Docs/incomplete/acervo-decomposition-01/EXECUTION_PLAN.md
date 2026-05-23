---
operation_name: TBD — assigned at /mission-supervisor start (THE RITUAL)
iteration: 01
state: refined
status: refined 2026-05-23 — 15 sorties, one extraction per sortie + closure; ready for /mission-supervisor start
source_requirements: ./REQUIREMENTS.md
source_plan: ../acervo-swift-decomposition-plan.md
created: 2026-05-23
---

# EXECUTION_PLAN.md — Acervo.swift decomposition iteration 01

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.
> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.
> **Work Unit** — A grouping of sorties (here: a single work unit, since every sortie touches `Acervo.swift` sequentially).

## Mission Synopsis

Decompose the 2780-line `Sources/SwiftAcervo/Acervo.swift` into 14 sibling `Acervo+<Concern>.swift` files (mechanical cut-and-paste, zero public-API breakage) following the existing `Acervo+CDNMutation.swift` / `ValidityOracle.swift` template. One sortie per extracted file. Each sortie also reorganizes companion test files where the new source layout suggests a 1-to-1 test file. Closure sortie verifies the residual `Acervo.swift` is the enum shell only (~55 lines) and that no public API symbol moved.

**Precondition**: OPERATION EIGHTH-MASTER must have shipped its EM-3 work (commit `6275e54` or descendants) so `Acervo.localModels()` filter + `gcEmptyModelDirectories()` are in the tree before S10 (Discovery extraction) runs.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| acervo-decomposition | Docs/incomplete/acervo-decomposition-01/ | 15 | 1 | EIGHTH-MASTER EM-3 merged to base branch |

Single sequential work unit. No parallelism is possible — every sortie touches `Acervo.swift` and would cause merge conflicts if run concurrently.

---

## Sortie sequencing principles

1. **Bottom-up**: leaves first (no inbound dependencies from sibling extensions), then facades, then behavioral, then largest.
2. **One sortie = one extracted file = one logical extraction commit** (the sortie may produce a small ordered sequence: source extraction commit, then test reorg commit if applicable, then state-update commit).
3. **F3 (`Acervo+Discovery.swift`) is deferred to S10** because EM-3's housekeeping additions land in that section. Earlier slots cannot touch Discovery without rebasing onto EM-3 first.
4. **F6 (`Acervo+EnsureAvailable.swift`) is the largest extraction at ~395 lines**. It is dispatched late (S13) after F7 lands so the slug-keyed helpers it consumes are already at their final `Acervo.*` addresses.
5. **F14 (`Acervo+ComponentDownloads.swift`) at ~310 lines** is dispatched last (S14) so every leaf dependency is in place before this large behavioral surface is moved.

---

## Sortie 1 — Extract `Acervo+ManifestAccess.swift` (F12)

**Priority**: Highest — smallest, leaf, validates the extraction template.

**Goal**: Move the four `fetchManifest(...)` overloads (§16 of inventory) into `Sources/SwiftAcervo/Acervo+ManifestAccess.swift`.

**Entry criteria**:
- [ ] Mission branch created from a base that includes EM-3 (`6275e54` or descendant).
- [ ] `Sources/SwiftAcervo/Acervo+CDNMutation.swift` and `Sources/SwiftAcervo/ValidityOracle.swift` exist (extraction templates).

**Tasks**:
1. Create `Sources/SwiftAcervo/Acervo+ManifestAccess.swift` with the same header-comment shape as `Acervo+CDNMutation.swift`. Declare `extension Acervo { ... }` and move the four `fetchManifest(...)` overloads verbatim from `Acervo.swift` §16 (lines ~1749-1806 in the source plan's inventory).
2. Delete the moved block from `Acervo.swift`. Confirm no `// MARK:` header is orphaned.
3. Re-run `grep -n "fetchManifest" Sources/SwiftAcervo/ Tests/` to confirm every reference still resolves.
4. **Test reorganization**: `Tests/SwiftAcervoTests/ManifestFetchTests.swift` already aligns 1-to-1 with the new file. No test changes. Add a one-line header comment in the test file: `// Companion tests for Sources/SwiftAcervo/Acervo+ManifestAccess.swift`.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+ManifestAccess.swift` exists with all four `fetchManifest` overloads.
- [ ] The moved block is gone from `Acervo.swift`; the file is ~58 lines shorter.
- [ ] `grep -n "fetchManifest" Sources/SwiftAcervo/Acervo.swift` returns no results.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0 at sortie HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + COMPLETED in the same dispatch. (F2)

---

## Sortie 2 — Extract `Acervo+PathResolution.swift` (F1)

**Priority**: Foundation — every later sortie's `extension Acervo` files implicitly depend on `slugify` / `sharedModelsDirectory` / `modelDirectory` resolving via `Acervo.*`. After this extraction the residual file's top is much cleaner.

**Goal**: Move §2 (lines ~54-279) into `Sources/SwiftAcervo/Acervo+PathResolution.swift`.

**Entry criteria**:
- [ ] S1 COMPLETED with commit SHA recorded.

**Tasks**:
1. Move `appGroupEnvironmentVariable`, `sharedModelsDirectory`, `slugify(_:)`, `modelDirectory(for:)`, `ensureModelDirectory(for:)`, `excludeFromBackup(_:)` and any private path helpers into the new file. Keep private helpers `private` (file-scope) inside the new file.
2. Verify `AcervoManager.swift` still compiles — it references `Acervo.slugify`, `Acervo.modelDirectory`, `Acervo.sharedModelsDirectory`.
3. **Test reorganization**: `Tests/SwiftAcervoTests/AcervoPathTests.swift` already aligns. No test changes. Add header comment.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+PathResolution.swift` exists (~230 lines).
- [ ] `Acervo.swift` is ~230 lines shorter than at S1 HEAD.
- [ ] `AcervoManager.swift` unchanged.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 3 — Extract `Acervo+ComponentIntegrity.swift` (F11)

**Priority**: Small, self-contained leaf; precedes facade extractions.

**Goal**: Move §15 (lines ~1647-1747) into `Sources/SwiftAcervo/Acervo+ComponentIntegrity.swift`.

**Entry criteria**:
- [ ] S2 COMPLETED.

**Tasks**:
1. Move `verifyComponent(_:)`, `verifyAllComponents()`, and any file-private helpers into the new file.
2. Confirm the existing `IntegrityVerification` sibling type continues to be reachable.
3. **Test reorganization**: `Tests/SwiftAcervoTests/IntegrityVerificationTests.swift` aligns with the new file. No test changes. Add header comment.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+ComponentIntegrity.swift` exists (~110 lines).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 4 — Extract `Acervo+ComponentRegistration.swift` (F9)

**Priority**: Thin façade; required before S5 (Catalog) which consumes the registry facade.

**Goal**: Move §13 (lines ~1424-1476) into `Sources/SwiftAcervo/Acervo+ComponentRegistration.swift`.

**Entry criteria**:
- [ ] S3 COMPLETED.

**Tasks**:
1. Move `register(_:)` (both overloads), `unregister(_:)` into the new file. Document that this file is the API surface for "tell Acervo about a component".
2. **Test reorganization**: `Tests/SwiftAcervoTests/ComponentRegistryTests.swift` exercises both this file's registration façade and the underlying `ComponentRegistry` actor. **Action**: leave the test file as-is (it correctly spans both layers) and add a header comment naming both files it covers.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+ComponentRegistration.swift` exists (~55 lines).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 5 — Extract `Acervo+ComponentCatalog.swift` (F10)

**Priority**: Read-side catalog queries; depends on S4.

**Goal**: Move §14 (lines ~1478-1645) into `Sources/SwiftAcervo/Acervo+ComponentCatalog.swift`.

**Entry criteria**:
- [ ] S4 COMPLETED.

**Tasks**:
1. Move `registeredComponents()` (both overloads), `component(_:)`, `isComponentReady(_:)`, `isComponentReadyAsync(_:)`, `pendingComponents()`, `totalCatalogSize()`, `unhydratedComponents()`.
2. **Test reorganization**: tests are spread across `CatalogHydrationTests.swift`, `ComponentDownloadTests.swift`, and others. **Action**: do NOT rename existing test files; instead create a focused new file `Tests/SwiftAcervoTests/ComponentCatalogQueriesTests.swift` containing the catalog-query test cases (lift from `CatalogHydrationTests.swift` the tests that exercise *only* the catalog read-side, leave hydration-driven tests in place). Use `git mv` for any straight moves to preserve blame.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+ComponentCatalog.swift` exists (~175 lines).
- [ ] `Tests/SwiftAcervoTests/ComponentCatalogQueriesTests.swift` exists with the lifted tests.
- [ ] No test case lost in the move (test count is monotonic non-decreasing).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 6 — Extract `Acervo+Hydration.swift` (F13) — includes `HydrationCoalescer`

**Priority**: Mirrors the `ValidityOracle.swift` template (concern + helper type in one file).

**Goal**: Move §17 (lines ~1808-1921), including the `internal actor HydrationCoalescer`, into `Sources/SwiftAcervo/Acervo+Hydration.swift`.

**Entry criteria**:
- [ ] S5 COMPLETED.

**Tasks**:
1. Move the `extension Acervo` block AND the `internal actor HydrationCoalescer` declaration into the new file. Keep the actor `internal`.
2. Verify no external consumer references `HydrationCoalescer` (grep `Sources/`, `Tests/`, `Examples/` if any).
3. **Test reorganization**: hydration is currently exercised by `HydrateComponentTests.swift` and `HydrationTests.swift`. Add a NEW focused unit test file `Tests/SwiftAcervoTests/HydrationCoalescerTests.swift` that exercises the actor directly — at minimum two cases: (i) two concurrent calls for the same component coalesce into one underlying load, (ii) two concurrent calls for *different* components do NOT serialize against each other. This is the most concrete testability gain from the whole mission; do not skip it.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+Hydration.swift` exists (~120 lines including `HydrationCoalescer`).
- [ ] `Tests/SwiftAcervoTests/HydrationCoalescerTests.swift` exists with at least the two concurrency cases described.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 7 — Extract `Acervo+DeleteModel.swift` (F8)

**Priority**: Two related delete variants together; symmetric with the existing `Acervo+CDNMutation.swift`.

**Goal**: Move §11 + §12 (lines ~1259-1422) into `Sources/SwiftAcervo/Acervo+DeleteModel.swift`.

**Entry criteria**:
- [ ] S6 COMPLETED.

**Tasks**:
1. Move `deleteModel(_:)` (legacy repo-keyed) and `deleteModel(slug:url:)` (slug-keyed) into the new file. Both share the "remove from disk + clean registry/manifest cache" contract; co-locating them keeps the contract visible.
2. **Test reorganization**: `Tests/SwiftAcervoTests/SlugDeleteModelTests.swift` aligns with the slug variant; legacy variant is tested in `AcervoDownloadAPITests.swift`. **Action**: lift the legacy-delete tests from `AcervoDownloadAPITests.swift` into a new `Tests/SwiftAcervoTests/DeleteModelTests.swift` (use `git mv` followed by trimming + re-anchoring) — `AcervoDownloadAPITests.swift` becomes leaner; the delete contract gets a focused file. Keep `SlugDeleteModelTests.swift` for the slug variant.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+DeleteModel.swift` exists (~170 lines).
- [ ] `Tests/SwiftAcervoTests/DeleteModelTests.swift` exists with the lifted legacy-delete tests.
- [ ] Total test count is monotonic non-decreasing.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 8 — Extract `Acervo+Download.swift` (F5)

**Priority**: Standalone legacy download orchestration; precedes the larger ensure-available extractions.

**Goal**: Move §9 (lines ~935-1081) into `Sources/SwiftAcervo/Acervo+Download.swift`.

**Entry criteria**:
- [ ] S7 COMPLETED.

**Tasks**:
1. Move `download(_:files:progress:telemetry:)` (legacy) into the new file. The body is thin and delegates to `AcervoDownloader`.
2. **Test reorganization**: `Tests/SwiftAcervoTests/AcervoDownloadAPITests.swift` after S7's delete-lift now covers download + ensure-available. Leave it intact; the next sortie's lift will further trim it.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+Download.swift` exists (~150 lines).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 9 — Extract `Acervo+Availability.swift` (F2) — legacy + 3-state combined

**Priority**: Combines the two `ValidityOracle` consumers in one file.

**Goal**: Move §3 + §20 (lines ~281-400 and ~2234-2324) into `Sources/SwiftAcervo/Acervo+Availability.swift`.

**Entry criteria**:
- [ ] S8 COMPLETED.

**Tasks**:
1. Move `isModelAvailable(_:)`, `isModelConfigPresent(_:)`, `modelFileExists(_:fileName:)` (legacy synchronous tier) AND `availability(_:verifyHashes:)` (async 3-state tier) into the new file.
2. **Test reorganization**: `Tests/SwiftAcervoTests/AcervoAvailabilityTests.swift` covers the legacy tier; `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift` covers the 3-state tier; `Tests/SwiftAcervoTests/EM2ValidityOracleTests.swift` covers the oracle plumbing. **Action**: leave the three test files as-is. Add a header comment in each naming `Acervo+Availability.swift` as the source-of-record.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+Availability.swift` exists (~215 lines).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 10 — Extract `Acervo+Discovery.swift` (F3) — includes EM-3's housekeeping

**Priority**: Larger file (~340 lines); deferred to S10 so it absorbs EM-3's listing-filter + GC additions cleanly.

**Goal**: Move §4 + §7 + §8 (lines ~402-639, ~836-884, ~886-933) into `Sources/SwiftAcervo/Acervo+Discovery.swift`.

**Entry criteria**:
- [ ] S9 COMPLETED.
- [ ] EM-3 (commit `6275e54` or descendant) is in the merge base. `git log --oneline | grep -i em.3` finds it.

**Tasks**:
1. Move `listModels()` (with EM-3's validity-marker filter), `gcEmptyModelDirectories()` (EM-3's destructive GC), `modelInfo(_:)`, `modelFamilies()`, plus the private `hasModelValidityMarker(in:fm:)` helper and `directorySize(of:)` helper.
2. **Test reorganization**:
   - `Tests/SwiftAcervoTests/AcervoDiscoveryTests.swift` → leave name; add header comment.
   - `Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` → leave name; add header comment.
   - `Tests/SwiftAcervoTests/EM3LocalModelsHousekeepingTests.swift` → **rename via `git mv` to `Tests/SwiftAcervoTests/LocalModelsHousekeepingTests.swift`** (the EM3 mission tag is no longer load-bearing now that EM-3 has shipped; the test contents stay identical, only the filename and the type name change). Update any imports / Suite-name annotations.
   - `Tests/SwiftAcervoTests/AcervoFuzzySearchTests.swift`'s `modelFamilies()` test cases stay in fuzzy-search file (they exercise the families API via the search lens). No move.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+Discovery.swift` exists (~340 lines).
- [ ] `Tests/SwiftAcervoTests/LocalModelsHousekeepingTests.swift` exists; `EM3LocalModelsHousekeepingTests.swift` is gone (via `git mv`, blame preserved).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] CIH-2's shape gate still passes against the renamed test file (no class is wrongly listed in `skippedTests`).
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 11 — Extract `Acervo+Search.swift` (F4) — pattern + fuzzy

**Priority**: Pure query-over-listing; reads from S10's discovery surface.

**Goal**: Move §5 + §6 (lines ~641-687 and ~689-834) into `Sources/SwiftAcervo/Acervo+Search.swift`.

**Entry criteria**:
- [ ] S10 COMPLETED.

**Tasks**:
1. Move `findModels(matching:)` (glob), `findModels(matching:tolerance:in:)` (fuzzy), `closestModel(to:in:tolerance:)`, plus private helpers `commonPrefixes`, `stripCommonPrefixes`.
2. **Test reorganization**: `Tests/SwiftAcervoTests/AcervoSearchTests.swift` covers glob; `Tests/SwiftAcervoTests/AcervoFuzzySearchTests.swift` covers fuzzy + families. Leave both names. Add header comments naming `Acervo+Search.swift` as source-of-record.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+Search.swift` exists (~200 lines).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 12 — Extract `Acervo+SlugAvailability.swift` (F7)

**Priority**: Pulls slug-keyed helpers (`isOrgRepoSlug`, `componentTotalBytes`, `fetchSlugManifest`) along with the slug-keyed availability API. F6 (S13) depends on these being at their final `Acervo.*` addresses.

**Goal**: Move §21 (lines ~2326-2560) into `Sources/SwiftAcervo/Acervo+SlugAvailability.swift`.

**Entry criteria**:
- [ ] S11 COMPLETED.

**Tasks**:
1. Move `availability(slug:url:telemetry:)` and the `internal static` helpers `isOrgRepoSlug(_:)`, `componentTotalBytes(...)`, `fetchSlugManifest(...)`. **Keep these helpers `internal static`** — F6 (next sortie) and any other future file in the module reaches them via `Acervo.<helper>`.
2. Add a comment in the new file: `// internal static helpers below are intentionally module-visible — used by Acervo+EnsureAvailable.swift (slug-keyed variant). Do not narrow to private.`
3. **Test reorganization**: `Tests/SwiftAcervoTests/SlugAvailabilityTests.swift` aligns 1-to-1. No move. Add header comment.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+SlugAvailability.swift` exists (~240 lines).
- [ ] `isOrgRepoSlug` / `componentTotalBytes` / `fetchSlugManifest` remain `internal static` (verify with `grep`).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 13 — Extract `Acervo+EnsureAvailable.swift` (F6) — legacy + slug-keyed combined

**Priority**: Largest single extraction (~395 lines). Both repo-keyed and slug-keyed ensure-available share the `progress` aggregator contract; co-locating prevents drift. **Close to the 400-line ceiling — if extraction exceeds 450 lines after move, STOP and report PARTIAL with a recommendation to split into F6a (legacy) + F6b (slug) + F6c (shared aggregator).**

**Goal**: Move §10 + §22 (lines ~1083-1257 and ~2562-2777) into `Sources/SwiftAcervo/Acervo+EnsureAvailable.swift`.

**Entry criteria**:
- [ ] S12 COMPLETED. (Slug-keyed helpers at their final `Acervo.*` addresses.)

**Tasks**:
1. Move `ensureAvailable(_:files:progress:telemetry:)` (legacy repo-keyed) and `ensureAvailable(slug:url:files:progress:telemetry:)` (slug-keyed multi-component).
2. Move the slug-keyed `ComponentStateBox` aggregator helper (currently file-private in `Acervo.swift`'s slug-ensure-available section).
3. After extraction, run `wc -l Sources/SwiftAcervo/Acervo+EnsureAvailable.swift`. If > 450 lines: STOP, report PARTIAL, recommend the F6a/F6b/F6c split.
4. **Test reorganization**: `Tests/SwiftAcervoTests/EnsureAvailableEmptyFilesTests.swift` and `Tests/SwiftAcervoTests/SlugEnsureAvailableTests.swift` already exist and align. Add header comments. **Optional new test**: if extraction surfaces the `ComponentStateBox` as a testable type (it currently is buried), add `Tests/SwiftAcervoTests/EnsureAvailableProgressAggregationTests.swift` with at least one thread-safety test. Optional, not required.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+EnsureAvailable.swift` exists, ≤ 450 lines, OR sortie reports PARTIAL with the split recommendation.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 14 — Extract `Acervo+ComponentDownloads.swift` (F14) — downloads + deletion

**Priority**: Largest behavioral surface (~310 lines); dispatched last so every leaf dependency is in place.

**Goal**: Move §18 + §19 (lines ~1923-2166 and ~2168-2232) into `Sources/SwiftAcervo/Acervo+ComponentDownloads.swift`.

**Entry criteria**:
- [ ] S13 COMPLETED.

**Tasks**:
1. Move `downloadComponent(_:progress:telemetry:)`, `ensureComponentReady(_:progress:telemetry:)`, `ensureComponentsReady(_:progress:telemetry:)`, `deleteComponent(_:)`. All four operate on the same component-directory layout and delegate to `AcervoDownloader.downloadComponent`.
2. **Test reorganization**: tests live in `ComponentDownloadTests.swift`, `DownloadComponentAutoHydrationTests.swift`, `ComponentIntegrationTests.swift`. Three test files for one source file is fine — they slice the behavioral surface by intent (basic download, auto-hydrate, integration). Leave all three; add header comments naming `Acervo+ComponentDownloads.swift` as source-of-record in each.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo+ComponentDownloads.swift` exists (~310 lines).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0. (F3)
- [ ] `SUPERVISOR_STATE.md` updated. (F2)

---

## Sortie 15 — Closure: verify residual `Acervo.swift`, document, update PROJECT_STRUCTURE

**Priority**: Final closure — no source code moves; verification + docs.

**Goal**: Verify the residual `Acervo.swift` is the enum shell only (~55-100 lines); update `Docs/PROJECT_STRUCTURE.md`; tally the public-API surface to confirm zero symbol drift.

**Entry criteria**:
- [ ] S14 COMPLETED.

**Tasks**:
1. Confirm `Sources/SwiftAcervo/Acervo.swift` line count is ≤ 100 lines and contains: `public enum Acervo { ... }` shell, `version`, offline-mode env helpers, and nothing else.
2. Walk `Sources/SwiftAcervo/Acervo+*.swift` files; produce a count and total line tally.
3. Run a public-API delta check: `grep -REn 'public (static (func|var|let))' Sources/SwiftAcervo/Acervo*.swift | sort > /tmp/api-after.txt`. Compare to the pre-mission tally (capture at S1 start) — every symbol present pre-mission must be present post-mission. No symbol renamed.
4. Update `Docs/PROJECT_STRUCTURE.md` to list the new `Acervo+*.swift` files under the existing source-tree section. One-line per file: filename, one-sentence concern.
5. Update `Docs/API_REFERENCE.md` source-of-record references if the document points at line numbers in the monolithic `Acervo.swift` (rewrite to point at filenames instead; do not add new doc content).
6. Run `make build` + `make test` + `make test-plan-shape` one final time.

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/Acervo.swift` ≤ 100 lines.
- [ ] Public-API delta is empty (every pre-mission symbol present post-mission with identical signature).
- [ ] `Docs/PROJECT_STRUCTURE.md` updated.
- [ ] `Docs/API_REFERENCE.md` line-number references updated to filename references (if any existed).
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0 at mission HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated; work unit COMPLETED. (F2)

---

## Parallelism Structure

**Critical Path**: S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8 → S9 → S10 → S11 → S12 → S13 → S14 → S15 (length: 15 sorties)

**Parallel Execution Groups**: none.

**Agent Allocation**: 1 supervising agent, 0 sub-agents.

**Rationale**: Every sortie modifies `Acervo.swift` (cuts a region out). Parallelism would force the supervising agent to resolve mechanical merge conflicts that cost more than serial execution. The sorties are individually small (most are pure cut-and-paste of a contiguous region), so sequential execution is fast.

**Missed Opportunities**: none. The mission is intentionally narrow-front.

---

## Process Controls (F1–F8) — Supervisor-Honored

| Control | Application |
|---------|-------------|
| **F1** Pre-dispatch working-tree audit | Before each dispatch: `git status --porcelain` clean; current branch = mission branch; HEAD descends from base branch. |
| **F2** State-write-before-completion | Every sortie above includes "Update `SUPERVISOR_STATE.md` with commit SHA + COMPLETED" in exit criteria. |
| **F3** Build-and-test gate at every sortie HEAD | Every sortie's exit criteria include `make build` + `make test` + `make test-plan-shape` exit 0 at the final HEAD. |
| **F4** No silent deferrals | A sortie that cannot complete is marked PARTIAL with a successor recommendation. Specifically: S13 has an explicit PARTIAL path if `Acervo+EnsureAvailable.swift` exceeds 450 lines. |
| **F5** No out-of-band shipping during mission window | Supervisor monitors `git log <base> ^HEAD --oneline` periodically; new commits to base touching `Sources/SwiftAcervo/Acervo*.swift` trigger halt-and-rebase. |
| **F6** Closeout requires brief + clean state | `Docs/incomplete/acervo-decomposition-01/BRIEF.md` covering Sections 1-6 (QM01 brief template) required before `/organize-agent-docs` promotes the mission to `Docs/complete/`. |
| **F7** "STOP if you find a production bug" | Most sorties are mechanical cut-and-paste; the F7 clause is included only on sorties that add new tests (S6 `HydrationCoalescerTests`, S13 optional `EnsureAvailableProgressAggregationTests`): *"If the test you're writing surfaces a real production bug, your job is to STOP and report PARTIAL with the bug location and a recommended fix. Do not modify the test to make the bug invisible."* |
| **F8** API-symbol verification at planning time | No Foundation / standard-library symbols are introduced by this mission (mechanical moves only). S15 includes the final public-API symbol delta check to catch any accidental drift. |

---

## Open Questions

_Three resolved during this refinement (2026-05-23). No blocking questions remain._

### Decisions Log (refinement)

| # | Affects | Decision | Rationale |
|---|---------|----------|-----------|
| OQ-1 | S13 | If `Acervo+EnsureAvailable.swift` exceeds 450 lines, sortie reports PARTIAL and recommends F6a/F6b/F6c split | Honors the source plan's flag that F6 is closest to the 400-line ceiling; explicit PARTIAL path avoids silent ceiling violation |
| OQ-2 | S10 | Rename `EM3LocalModelsHousekeepingTests.swift` → `LocalModelsHousekeepingTests.swift` via `git mv` | EM-3 mission tag is no longer load-bearing once EM-3 has shipped; the filename is permanent and should reflect the concern, not the historical sortie that authored it |
| OQ-3 | S6 | New `HydrationCoalescerTests.swift` is REQUIRED (not optional) | The actor's testability gain is the most concrete win of the mission; the source plan recommended it as optional, but a focused unit test for a single-flight coalescer is cheap and high-value — making it required ensures the testability dividend lands |

### Refinement Pass Lens Notes

- **Atomicity** (Pass 2): All 15 sorties fit comfortably in a single agent context (most are < 200-line edits to one source file, optional rename of one test file, state update). Estimated turns per sortie: 8-15.
- **Priority** (Pass 3): Bottom-up dependency order (leaves → facades → behavioral → largest → closure) was applied; priorities are implicit in the sortie number.
- **Parallelism** (Pass 4): Zero opportunities — every sortie touches `Acervo.swift`. Sequential execution is the right answer.
- **Vague criteria** (Pass 5): Every sortie's exit criteria are machine-verifiable (file exists, line count, `grep` returns specific result, `make` exits 0). No "works correctly" or "properly handles" phrasing.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 15 (14 extractions + 1 closure) |
| Open questions | 0 (3 resolved during refinement) |
| Dependency structure | sequential (one work unit, fully linear) |
| New source files | 14 (`Acervo+<Concern>.swift`) |
| Renamed test files | 1 (`EM3LocalModelsHousekeepingTests` → `LocalModelsHousekeepingTests` via `git mv`) |
| New test files | 1 required (`HydrationCoalescerTests.swift`); 1 optional (`EnsureAvailableProgressAggregationTests.swift`); 1 lifted (`ComponentCatalogQueriesTests.swift`); 1 lifted (`DeleteModelTests.swift`) |
| Public-API symbols moved | ~50 across 14 files, zero renamed |
| Estimated residual `Acervo.swift` | ≤ 100 lines (down from 2780) |
