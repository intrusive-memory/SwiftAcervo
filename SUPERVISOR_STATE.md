# SUPERVISOR_STATE.md — OPERATION DRAWER DIVIDERS iteration 01

> **Worktree mission.** This state file is scoped to the `/Users/stovak/Projects/SwiftAcervo-decomp/` worktree on branch `mission/drawer-dividers/01`. The primary checkout at `/Users/stovak/Projects/SwiftAcervo/` runs OPERATION EIGHTH-MASTER on `mission/eighth-master/01` with its own SUPERVISOR_STATE.md. Do not cross-reference.

## Terminology

> **Mission** — A definable, testable scope of work; the whole campaign.
> **Sortie** — An atomic, testable unit of work executed by a single autonomous agent in one dispatch.
> **Work Unit** — A grouping of sorties (here: a single work unit `acervo-decomposition`, 15 sequential sorties).

## Mission Metadata

| Field | Value |
|-------|-------|
| Operation name | OPERATION DRAWER DIVIDERS |
| Iteration | 01 |
| Plan path | Docs/incomplete/acervo-decomposition-01/EXECUTION_PLAN.md |
| Starting point commit | 492d54f6c5a9a906196bda5b48cd8ca80c8b3e91 |
| Mission branch | mission/drawer-dividers/01 |
| Base branch | development (via mission/eighth-master/01 — see "Branch coupling" below) |
| Worktree path | /Users/stovak/Projects/SwiftAcervo-decomp |
| Launched | 2026-05-23 |
| Max retries per sortie | 3 |

## Branch coupling (important)

This mission's branch was created from `mission/eighth-master/01` tip (`492d54f`) — not from `development`. The reason: S10 (Discovery extraction) depends on EM-3's `localModels()` filter + `gcEmptyModelDirectories()` (commit `6275e54`), and EM-3 lives only on the eighth-master branch.

**Implication for the merge path**: this mission's PR will carry every EIGHTH-MASTER commit ahead of `development` as part of its diff. Effectively, the two missions ship together — either as one combined PR or as strictly sequential PRs (eighth-master first, then decomp). This is the explicit trade-off the user accepted when choosing "Start decomp now in a worktree, branched off eighth-master".

## Plan Summary

- Work units: 1
- Total sorties: 15 (14 extractions + 1 closure)
- Dependency structure: strictly sequential (every sortie touches `Sources/SwiftAcervo/Acervo.swift`)
- Dispatch mode: dynamic (no template; F7 verbatim clause appended only to test-authoring sorties S6 + S13 if optional aggregator test added)

## Work Units

| Name | Directory | Sorties | Dependencies | Layer |
|------|-----------|---------|--------------|-------|
| acervo-decomposition | Docs/incomplete/acervo-decomposition-01/ | 15 (S1–S15) | EM-3 on base (satisfied via branch coupling) | 1 |

## Overall Status

`RUNNING` — S13 COMPLETED (commit e9a1657); S14 PENDING.

---

## Per-Work-Unit State

### acervo-decomposition
- Work unit state: RUNNING (S1–S13 COMPLETED; S14–S15 queued)
- Current sortie: S14 of 15 (PENDING)
- Last completed: S13 — sortie state COMPLETED at commit e9a1657
- S1 summary: Extracted `Acervo+ManifestAccess.swift` (65 lines, 4 fetchManifest overloads). Acervo.swift reduced from 2777 to 2718 lines (59-line delta, matches plan estimate). All builds + tests + shape gate pass. ManifestFetchTests.swift marked with source-of-record comment.
- S2 summary: Extracted `Acervo+PathResolution.swift` (235 lines, 6 public symbols + 3 internal helpers). Acervo.swift reduced from 2718 to 2490 lines (228-line delta, within 2475-2510 estimate). import Security moved to new file. AcervoManager.swift untouched. All builds + tests + shape gate pass. AcervoPathTests.swift marked with source-of-record comment.
- S3 summary: Extracted `Acervo+ComponentIntegrity.swift` (107 lines, 2 public symbols + 2 internal baseDirectory overloads). Acervo.swift reduced from 2490 to 2387 lines (103-line delta, within 2380–2400 estimate). IntegrityVerification.swift untouched. All builds + tests + shape gate pass. IntegrityVerificationTests.swift marked with source-of-record comment.
- S4 summary: Extracted `Acervo+ComponentRegistration.swift` (58 lines, 3 public symbols: register×2 + unregister). Acervo.swift reduced from 2387 to 2333 lines (54-line delta, within estimate). ComponentRegistry.swift untouched. All builds + tests + shape gate pass. ComponentRegistryTests.swift header names both source files (facade + actor).
- S5 summary: Extracted `Acervo+ComponentCatalog.swift` (176 lines, 8 public symbols + internal overloads). Acervo.swift reduced from 2333 to 2165 lines (168-line delta, within 2155-2180 estimate). Created `ComponentCatalogQueriesTests.swift` with 8 tests (1 lifted + 7 new). CatalogHydrationTests.swift updated with header comment + lifted test removed (reserved for S6 hydration-driven tests). Pre-lift: 1 test in CatalogHydrationTests; post-lift: 8 tests total across both files. make build/test/test-plan-shape all pass (70 tests).
- S6 summary: Extracted `Acervo+Hydration.swift` (120 lines, including `HydrationCoalescer` actor). Acervo.swift reduced from 2165 to 2050 lines (115-line delta, within 2045–2065 estimate). Created `HydrationCoalescerTests.swift` with 4 tests using injectable fetch closure + AtomicCounter: Case A (same-key coalesces, counter==1), Case B (different-key runs independently, counter==2), sequential re-fetch, 10-concurrent coalescing. HydrateComponentTests.swift and HydrationTests.swift header comments added. HydrationCoalescer symbol ONLY in Acervo+Hydration.swift. Case A confirmed: counter==1 (F7 gate passed — no bug). Case B confirmed: counter==2. make build/test (646 Swift Testing + 70 XCTest)/test-plan-shape all pass.
- S7 summary: Extracted `Acervo+DeleteModel.swift` (~175 lines, §11 legacy deleteModel(_:) + §12 slug-keyed deleteModel(slug:url:)). Acervo.swift reduced from 2050 to 1885 lines (165-line delta, within 1880–1900 estimate). Created `DeleteModelTests.swift` (6 tests lifted from AcervoDownloadAPITests.swift). AcervoDownloadAPITests.swift: 15→9 tests (delete section removed, header updated). SlugDeleteModelTests.swift: header comment added. Pre-lift: 20 tests total (15+5+0); post-lift: 20 tests (9+6+5). make build/test (70 XCTest)/test-plan-shape all pass.
- S8 summary: Extracted `Acervo+Download.swift` (171 lines, §9 public download(_:files:progress:telemetry:) + internal test-support overload). Acervo.swift reduced from 1885 to 1737 lines (148-line delta, within ~150-line estimate). Thin facade delegating to AcervoDownloader (manifest fetch + per-file verification). AcervoDownloadAPITests.swift header already updated by S7 (names both Download.swift and EnsureAvailable.swift). No test moves in S8 — ensure-available tests remain for S13 lift. AcervoDownloader.swift untouched (byte-identical). All gates green (70 XCTest).
- S9 summary: Extracted `Acervo+Availability.swift` (279 lines, §3 legacy availability + §20 three-state availability + internal isModelAvailable(_, in:) from Ensure Available section). Acervo.swift reduced from 1737 to 1479 lines (258-line delta; larger than ~210-line estimate because the internal isModelAvailable(_, in:) overload was relocated from the Ensure Available section to colocate all availability plumbing). Slug-keyed availability(slug:url:) intentionally NOT moved (S12). ValidityOracle.swift byte-identical (MD5 verified). Header comments added to AcervoAvailabilityTests.swift, AvailabilityThreeStateTests.swift, EM2ValidityOracleTests.swift. All gates green (70 XCTest / make build / make test-plan-shape).
- S10 summary: Extracted `Acervo+Discovery.swift` (282 lines, §4 model listing + GC + §7 model families + §8 directory size). Acervo.swift reduced from 1479 to 1141 lines (−338). directorySize moved cleanly as private (only used by listModels(in:) — no other callers in the codebase). EM3LocalModelsHousekeepingTests.swift renamed to LocalModelsHousekeepingTests.swift via git mv; EM3 prefixes removed from Swift type names (ListModelsFilterTests, GCEmptyModelDirectoriesTests, EnsureAvailableManifestTests). No xctestplan updates required (no EM3 references in any .xctestplan file). Header comments added to AcervoDiscoveryTests.swift and AcervoFilesystemEdgeCaseTests.swift. grep -RIn 'EM3LocalModelsHousekeepingTests' Sources/ Tests/ returns empty (Docs/ references are historical plan baselines). All gates green (70 XCTest / make build / make test-plan-shape).
- S11 summary: Extracted `Acervo+Search.swift` (217 lines, §5 pattern matching + §6 fuzzy search). Acervo.swift reduced from 1141 to 946 lines (−195, within ~195-line estimate). One extension Acervo with two MARK subsections per S10 template. Moved 8 symbols total: glob variant (findModels(matching:), findModels(matching:in:) test-support); fuzzy variant (findModels(fuzzyMatching:editDistance:), findModels(fuzzyMatching:editDistance:in:), closestModel(to:editDistance:), closestModel(to:editDistance:in:), and private helpers commonPrefixes + stripCommonPrefixes). Test file headers updated (AcervoSearchTests.swift + AcervoFuzzySearchTests.swift with note that modelFamilies tests stay in fuzzy file). All gates green (70 XCTest / make build / make test-plan-shape). S12 PENDING.
- S12 summary: Extracted `Acervo+SlugAvailability.swift` (245 lines, §21 slug-keyed availability public method + internal test-seam overload + three internal static helpers). Acervo.swift reduced from 946 to 710 lines (−236, within 700–725 estimate). Helpers isOrgRepoSlug, componentTotalBytes, fetchSlugManifest explicitly kept internal static for S13 cross-file access. SlugAvailabilityTests.swift companion header added. All gates green (70 XCTest / make build / make test-plan-shape). S13 PENDING.
- S13 summary: Extracted `Acervo+EnsureAvailable.swift` (377 lines, well under 450-line PARTIAL threshold — combined-file path taken). Combined two non-contiguous sections (§10 legacy repo-keyed + §22 slug-keyed multi-component) plus the file-private `ComponentStateBox` aggregator into one file with two MARK subsections, mirroring S9's pattern. Acervo.swift reduced from 710 to 362 lines (−348, slightly exceeds 380-line estimate because both sections were full-bodied with doc comments + the helper). Symbols moved: public ensureAvailable(_:files:progress:telemetry:) + internal (in:) test seam; public ensureAvailable(slug:url:files:progress:telemetry:) + internal (in:) test seam; ComponentStateBox promoted from inside-function to file-private file-scope. Cross-file reachability of isOrgRepoSlug/componentTotalBytes/fetchSlugManifest (in Acervo+SlugAvailability.swift) confirmed by successful build. Test headers updated on EnsureAvailableEmptyFilesTests.swift and SlugEnsureAvailableTests.swift; AcervoDownloadAPITests.swift already correct from S8. All gates green (70 XCTest / make build / make test-plan-shape). S14 PENDING.
- Notes: S15 closure sortie will perform a public-API symbol delta check (`grep -REn 'public (static (func|var|let))' Sources/SwiftAcervo/Acervo*.swift`) — supervisor captured the pre-S1 snapshot at launch commit 492d54f as the baseline. **State-file location lesson**: every future sortie dispatch must explicitly name the canonical state file path (`/Users/stovak/Projects/SwiftAcervo-decomp/SUPERVISOR_STATE.md`, worktree root) to prevent agents from inventing duplicates.

---

## Completed Sorties

| Sortie | Sortie State | Attempt | Commit SHA | Completed At | build/test/shape-gate |
|--------|-------------|---------|-----------|--------------|----------------------|
| S1 | COMPLETED | 1/3 | 5428627 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S2 | COMPLETED | 1/3 | 8e7e7c8 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S3 | COMPLETED | 1/3 | 8f89f5b | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S4 | COMPLETED | 1/3 | 85aa60f | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S5 | COMPLETED | 1/3 | e62400e + 671a1cb | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S6 | COMPLETED | 1/3 | 0d28f86 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S7 | COMPLETED | 1/3 | 8a29498 + 538671e | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S8 | COMPLETED | 1/3 | e066116 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S9 | COMPLETED | 1/3 | 311eb74 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S10 | COMPLETED | 1/3 | 3555d5e + c57709d | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S11 | COMPLETED | 1/3 | 47b9374 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S12 | COMPLETED | 1/3 | c9a3320 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |
| S13 | COMPLETED | 1/3 | e9a1657 | 2026-05-23 | ✓ pass / ✓ pass / ✓ pass |

---

## Decisions Log

| Timestamp | Sortie | Decision | Rationale |
|-----------|--------|----------|-----------|
| 2026-05-23 | (mission) | Starting point commit captured: 492d54f | EIGHTH-MASTER tip (post DC-2a WIP commit); decomp branched here to inherit EM-3 + EIGHTH-MASTER source state |
| 2026-05-23 | (mission) | Mission branch created: mission/drawer-dividers/01 | Standard naming; slug derived from THE RITUAL operation name |
| 2026-05-23 | (mission) | Worktree created at /Users/stovak/Projects/SwiftAcervo-decomp | Isolation from concurrently-running EIGHTH-MASTER DC-2a upload in primary checkout |
| 2026-05-23 | (mission) | THE RITUAL: OPERATION DRAWER DIVIDERS | Inline name (one big drawer → labeled compartments); user can rename via /mission-supervisor name-feature regenerate later |
| 2026-05-23 | S1 | Model: haiku | Complexity score 4 — smallest extraction (4 fetchManifest overloads, ~58 LOC, leaf, zero internal callers from siblings, pure facade over AcervoDownloader). Haiku is the right tool to validate the extraction template before larger sorties. |
| 2026-05-23 | S1 | COMPLETED at commit 5428627 | Template validation successful. Created Acervo+ManifestAccess.swift (65 lines). Acervo.swift reduced from 2777→2718 lines. All exit criteria met: make build/test/test-plan-shape pass; grep fetchManifest empty in Acervo.swift; test file header comment added. Ready for S2 dispatch. |
| 2026-05-23 | S2 | COMPLETED at commit 8e7e7c8 | Foundation extraction. Created Acervo+PathResolution.swift (235 lines, includes Security import). Acervo.swift reduced from 2718→2490 lines (−228, within estimate). Moved 6 public symbols + 3 internal helpers. import Security followed SecTask calls to new file. AcervoManager.swift byte-identical. All exit criteria met: make build/test/test-plan-shape pass; grep for moved symbols empty in Acervo.swift; AcervoPathTests.swift header comment added. S3 PENDING. |
| 2026-05-23 | S3 | COMPLETED at commit 8f89f5b | Integrity verification extraction. Created Acervo+ComponentIntegrity.swift (107 lines, 2 public overloads + 2 internal baseDirectory helpers). Acervo.swift reduced from 2490→2387 lines (−103, within estimate 2380–2400). Moved public static func verifyComponent(_:) and verifyAllComponents() + internal overloads. IntegrityVerification.swift untouched. All exit criteria met: make build/test/test-plan-shape pass; grep for moved symbols empty in Acervo.swift; IntegrityVerificationTests.swift header comment added. S4 PENDING. |

---

## Parallel mission note

**OPERATION EIGHTH-MASTER** continues in `/Users/stovak/Projects/SwiftAcervo/` on branch `mission/eighth-master/01`:
- DC-2a: UPLOAD-IN-FLIGHT (PID 81371 alive; supervisor-tended polling)
- DC-2b, DC-2c: PENDING (queued after DC-2a)
- DC-3: PENDING (final test-hygiene cleanup)

This mission (DRAWER DIVIDERS) and EIGHTH-MASTER do not share source files (decomp touches `Sources/SwiftAcervo/Acervo*.swift` + `Tests/SwiftAcervoTests/*`; remaining EIGHTH-MASTER work touches `Docs/`, `dc2-specs/`, `DC2_UPLOAD_LOG.md`, and `Tests/AcervoToolTests/*` for DC-3). Disjoint. Each worktree has its own SUPERVISOR_STATE.md.
| 2026-05-23 | S3 | Model: haiku | Complexity score 4 — small leaf extraction (~100 LOC, verifyComponent + verifyAllComponents, delegates to IntegrityVerification sibling). |
| 2026-05-23 | S3 | COMPLETED at commit 8f89f5b | Acervo.swift 2490→2387 (−103). IntegrityVerification.swift byte-identical. Tests + shape gate green. |
| 2026-05-23 | S4 | Model: haiku | Complexity score 2 — smallest extraction in the mission (~55 LOC, 3-method facade over ComponentRegistry actor). |
| 2026-05-23 | S4 | COMPLETED at commit 85aa60f | Acervo.swift 2387→2333 (−54). ComponentRegistry.swift byte-identical. Tests + shape gate green. Test file header names BOTH source files (facade + actor) since the test exercises both. |
| 2026-05-23 | S5 | COMPLETED at commits e62400e + 671a1cb | Acervo.swift 2333→2165 (−168, within 2155-2180 estimate). Created Acervo+ComponentCatalog.swift (176 lines, 8 public symbols). Created ComponentCatalogQueriesTests.swift (8 tests: 1 lifted + 7 new). CatalogHydrationTests.swift: header added, lifted test removed, placeholder left for S6 hydration tests. Pre-lift: 1 test; post-lift: 8 tests. Total test run: 70 tests pass. All gates green. |
| 2026-05-23 | S6 | COMPLETED at commit 0d28f86 | Acervo.swift 2165→2050 (−115, within 2045–2065 estimate). Created Acervo+Hydration.swift (120 lines: HydrationCoalescer actor + extension Acervo { hydrateComponent }). Created HydrationCoalescerTests.swift (4 tests: Case A same-key coalesces counter==1, Case B different-keys counter==2, sequential re-fetch, 10-concurrent). HydrateComponentTests.swift + HydrationTests.swift header comments added. HydrationCoalescer symbol only in Acervo+Hydration.swift (grep confirmed). F7: no production bug found — coalescer behaves correctly. All gates green (646 Swift Testing + 70 XCTest). |
| 2026-05-23 | S7 | COMPLETED at commits 8a29498 + 538671e | Acervo.swift 2050→1885 (−165, within 1880–1900 estimate). Created Acervo+DeleteModel.swift (~175 lines: §11 legacy deleteModel(_:) + §12 slug-keyed deleteModel(slug:url:)). Header documents symmetry with Acervo+CDNMutation.swift (remote vs local delete). Created DeleteModelTests.swift (6 tests lifted from AcervoDownloadAPITests.swift). AcervoDownloadAPITests.swift: 15→9 tests; SlugDeleteModelTests.swift: header comment added. Pre-lift: 20 tests; post-lift: 20 tests (non-decreasing). All gates green (70 XCTest). |
| 2026-05-23 | S8 | COMPLETED at commit e066116 | Acervo.swift 1885→1737 (−148). Created Acervo+Download.swift (171 lines: §9 public download(_:files:progress:telemetry:) + internal test-support download(_:files:in:) overload). Thin facade delegating to AcervoDownloader for manifest fetch and per-file verification. AcervoDownloadAPITests.swift header already correct (updated by S7). No test moves in S8 — ensure-available tests stay in AcervoDownloadAPITests.swift until S13. AcervoDownloader.swift byte-identical. All gates green (make build/test/test-plan-shape). |
| 2026-05-23 | S9 | COMPLETED at commit 311eb74 | Acervo.swift 1737→1479 (−258). Created Acervo+Availability.swift (279 lines: §3 legacy 6 symbols + internal isModelAvailable(_:in:) relocated from Ensure Available + §20 three-state 2 symbols). The isModelAvailable(_:in:) move was justified by the task directive ("any internal (in baseDirectory:) test-support overloads of the same names"); colocating all availability plumbing in one file is correct. Slug-keyed availability(slug:url:telemetry:) confirmed NOT moved (stays in Acervo.swift for S12). ValidityOracle.swift byte-identical (MD5 0f268c95787c9deaa439f5eb21205591 before = after). Three test file headers updated. All gates green (70 XCTest). |
| 2026-05-23 | S10 | COMPLETED at commits 3555d5e + c57709d | Acervo.swift 1479→1141 (−338). Created Acervo+Discovery.swift (282 lines: §4 listing/GC + §7 families + §8 directorySize). directorySize moved cleanly as file-scoped private — grep confirmed only one call site (listModels(in:)); no duplication needed. EM3LocalModelsHousekeepingTests.swift renamed to LocalModelsHousekeepingTests.swift via git mv; Swift types renamed to ListModelsFilterTests, GCEmptyModelDirectoriesTests, EnsureAvailableManifestTests. No xctestplan changes needed. All gates green (70 XCTest / make build / make test-plan-shape). S11 PENDING. |
| 2026-05-23 | S11 | COMPLETED at commit 47b9374 | Acervo.swift 1141→946 (−195). Created Acervo+Search.swift (217 lines: §5 pattern matching + §6 fuzzy search). One extension Acervo with two MARK subsections per S10 template. Symbols moved: glob variant (findModels(matching:), findModels(matching:in:)); fuzzy variant (findModels(fuzzyMatching:editDistance:), findModels(fuzzyMatching:editDistance:in:), closestModel(to:editDistance:), closestModel(to:editDistance:in:), commonPrefixes, stripCommonPrefixes). Test headers updated: AcervoSearchTests.swift (glob) + AcervoFuzzySearchTests.swift (fuzzy + note that modelFamilies tests stay here). All gates green (70 XCTest / make build / make test-plan-shape). S12 PENDING. |
| 2026-05-23 | S12 | COMPLETED at commit c9a3320 | Acervo.swift 946→710 (−236). Created Acervo+SlugAvailability.swift (245 lines: §21 slug-keyed availability(slug:url:telemetry:) public + internal test-seam overload + three internal static helpers: isOrgRepoSlug, componentTotalBytes, fetchSlugManifest). Helpers explicitly marked `internal static` (not narrowed to private) for cross-file reachability by S13 (Acervo+EnsureAvailable.swift). SlugAvailabilityTests.swift header comment updated to name companion source file. All gates green (70 XCTest / make build / make test-plan-shape). S13 PENDING. |
| 2026-05-23 | (supervisor) | State-file location reconciled at b3f09b4 reverted/cleanup | S4 agent wrote its state update to a NEW duplicate at `Docs/incomplete/acervo-decomposition-01/SUPERVISOR_STATE.md` (wrong path) instead of this canonical worktree-root file. Supervisor: (a) folded S4's data into this file, (b) deleted the duplicate, (c) future sortie dispatches will name the canonical path explicitly to prevent recurrence. |
| 2026-05-23 | S13 | Combined-file path taken (not PARTIAL) | New file landed at 377 lines, well under the 450-line PARTIAL threshold. F6a/F6b/F6c three-way split not needed. |
| 2026-05-23 | S13 | ComponentStateBox promoted from inside-function to file-scope | Original location was a `final class` declared INSIDE the function body. To move into a sibling file cleanly (and reduce nesting noise), it was promoted to file-scope with `private` visibility. Behaviorally identical; same NSLock-guarded state vector consumed only by the slug-keyed ensureAvailable. |
| 2026-05-23 | S13 | COMPLETED at commit e9a1657 | Acervo.swift 710→362 (−348). Created Acervo+EnsureAvailable.swift (377 lines, 2 MARK subsections). Both ensureAvailable overloads + ComponentStateBox moved cleanly. Cross-file reachability of S12's internal helpers (isOrgRepoSlug/componentTotalBytes/fetchSlugManifest) confirmed by build success. All gates green. S14 PENDING. |
