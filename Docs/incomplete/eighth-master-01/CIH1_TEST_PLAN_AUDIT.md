---
sortie: CIH-1
operation: OPERATION EIGHTH-MASTER
mission_branch: mission/eighth-master/01
audit_date: 2026-05-23
audit_sha: HEAD
---

# CIH-1: Test-Plan Placement Audit

## Executive Summary

**Total test suites audited**: 79  
**macOS plan**: 68 suites (all SwiftAcervoTests + all AcervoToolTests)  
**iOS plan**: 67 suites (all SwiftAcervoTests)  
**Performance plan**: Does not exist (critical finding)  

**Critical Finding**: The `SwiftAcervo-Performance.xctestplan` file does not exist in the repository. The EXECUTION_PLAN references three test plans (macOS, iOS, Performance), but only two are present. This is a blocker for CIH-2 and subsequent missions that rely on separating correctness tests from performance tests.

**Deterministic Correctness Tests on Perf Plan**: **NONE** — because no performance plan exists, there are no correctness tests incorrectly perf-gated. This is an accidental pass (the QM01 planner-wrong-#1 mistake is not present).

---

## Test Plan Membership

The current test plans use the default behavior: when `selectedTests` and `skippedTests` are omitted, all suites in the target are included.

| Plan | Target | Included Suites |
|------|--------|---|
| SwiftAcervo-macOS | SwiftAcervoTests | All 68 suites |
| SwiftAcervo-macOS | AcervoToolTests | All 11 suites |
| SwiftAcervo-iOS | SwiftAcervoTests | All 68 suites |
| SwiftAcervo-Performance | (does not exist) | N/A |

---

## Full Test Suite Inventory

### SwiftAcervoTests (68 suites)

All classification below is based on code review to distinguish "measures timing/throughput" (performance) from "asserts functional outcome" (correctness).

| Suite | File | Classification | Notes |
|-------|------|---|---|
| Manifest Persistence Tests | AcervoAvailabilityTests.swift | Correctness | Asserts availability enum values match disk state |
| Acervo Concurrency Tests | AcervoConcurrencyTests.swift | Correctness | Concurrent `ensureAvailable` calls; asserts consistent results |
| AcervoDownloader Tests | AcervoDownloaderTests.swift | Correctness | Low-level download semantics (resume, error handling) |
| AcervoDownloadProgress Tests | AcervoDownloadProgressTests.swift | Correctness | Asserts progress callbacks fire at expected points |
| AcervoError Path Tests | AcervoErrorPathTests.swift | Correctness | Error case assertions |
| AcervoError Tests | AcervoErrorTests.swift | Correctness | Functional error outcomes |
| Filesystem Edge Cases | AcervoFilesystemEdgeCaseTests.swift | Correctness | Edge cases in symlink/permission handling |
| AcervoManager Tests | AcervoManagerTests.swift | Correctness | Actor-based concurrent access control |
| AcervoModel Tests | AcervoModelTests.swift | Correctness | Model type decoding and field validation |
| AcervoPathTests | AcervoPathTests.swift | Correctness | Path resolution |
| Acervo Stress Concurrency Tests | AcervoStressConcurrencyTests.swift | Correctness | Stress-tests concurrency invariants; not a wall-clock perf test |
| Acervo Telemetry — Cache Miss Reasons | AcervoTelemetryCacheMissReasonTests.swift | Correctness | Telemetry event correctness |
| Acervo Telemetry — Integrity Failure | AcervoTelemetryIntegrityFailureTests.swift | Correctness | Telemetry event correctness |
| Acervo Telemetry — Mock Reporter | AcervoTelemetryMockReporterTests.swift | Correctness | Mock telemetry reporter behavior |
| Auto-Hydrate Tests | AutoHydrateTests.swift | Correctness | Automatic manifest hydration on first use |
| Availability Aggregator | AvailabilityAggregatorTests.swift | Correctness | Multi-component availability aggregation |
| Availability Three-State Tests | AvailabilityThreeStateTests.swift | Correctness | Asserts `.available`, `.partial`, `.downloading` enum cases |
| Bundle Component Smoke Tests (Real CDN) | BundleComponentSmokeTests.swift | Correctness | Smoke test against real public CDN (slow, but deterministic assertion) |
| Bundle Component Tests (R1, R3) | BundleComponentTests.swift | Correctness | Component delivery from app bundles |
| Catalog Hydration Tests | CatalogHydrationTests.swift | Correctness | Manifest fetching and hydration |
| CDN Manifest Integrity Tests | CDNManifestIntegrityTests.swift | Correctness | Manifest checksum validation |
| CDN Manifest Tests | CDNManifestTests.swift | Correctness | Manifest decoding and validation |
| Component Access Tests | ComponentAccessTests.swift | Correctness | Component file access |
| Component Catalog Query Tests | ComponentCatalogTests.swift | Correctness | Catalog query results |
| ComponentDescriptor Type Tests | ComponentDescriptorTests.swift | Correctness | Descriptor initialization and encoding |
| Component Download Tests | ComponentDownloadTests.swift | Correctness | Per-component download |
| ComponentHandle Tests | ComponentHandleTests.swift | Correctness | Handle resolution to local paths |
| Component Integration Tests | ComponentIntegrationTests.swift | Correctness | End-to-end component workflows |
| ComponentRegistry Tests | ComponentRegistryTests.swift | Correctness | Registry initialization and lookup |
| Component Telemetry — manifest-destiny APIs | ComponentTelemetryTests.swift | Correctness | Telemetry for component ops |
| Concurrent Download Tests | ConcurrentDownloadTests.swift | Correctness | Concurrent downloads don't corrupt state |
| Acervo.deleteFromCDN | DeleteFromCDNTests.swift | Correctness | CDN deletion semantics |
| Download Component Auto-Hydration | DownloadComponentAutoHydrationTests.swift | Correctness | Hydration during component download |
| Download Session Injection | DownloadSessionInjectionTests.swift | Correctness | Custom session handling |
| EM-1: ModelAvailability.partial round-trip | EM1ManifestPersistenceTests.swift | Correctness | Manifest persistence and round-trip encoding (EM-1 new, from EXECUTION_PLAN) |
| EM-2: Validity oracle — Qwen3-Coder-Next false-positive case | EM2ValidityOracleTests.swift | Correctness | Manifest-driven availability oracle (EM-2 new, from EXECUTION_PLAN) |
| EM-3: listModels() excludes empty dirs | EM3LocalModelsHousekeepingTests.swift | Correctness | localModels() filtering and gc (EM-3 new, from EXECUTION_PLAN) |
| Ensure Available Empty Files Tests | EnsureAvailableEmptyFilesTests.swift | Correctness | ensureAvailable() with zero-byte files |
| Hydrate Component Tests | HydrateComponentTests.swift | Correctness | Explicit hydration API |
| Canonical Hydration Tests | HydrationTests.swift | Correctness | First-use auto-hydration |
| Integration: Real CDN Downloads | IntegrationTests.swift | Correctness | Integration tests against live R2 (slow, but assertions are deterministic) |
| Integrity Verification Tests | IntegrityVerificationTests.swift | Correctness | SHA-256 computation correctness |
| Levenshtein Distance Tests | LevenshteinDistanceTests.swift | Correctness | Fuzzy search distance metric |
| Local Access Tests | LocalAccessTests.swift | Correctness | withLocalAccess() scoped access |
| Manifest Error Mode Tests | ManifestErrorModeTests.swift | Correctness | Manifest decode error handling |
| Manifest Fetch Tests | ManifestFetchTests.swift | Correctness | Manifest fetch semantics |
| ManifestGenerator Tests | ManifestGeneratorTests.swift | Correctness | Manifest generation from filesystem |
| Manifest Integrity Tests | ManifestIntegrityTests.swift | Correctness | Manifest validation |
| Manifest Schema Extension Tests | ManifestSchemaExtensionTests.swift | Correctness | Manifest v2.0 schema extensions |
| Harness | MockURLProtocolTests.swift | Correctness | Test harness (mock URLProtocol behavior) |
| ModelDownloadManager Integration Tests | ModelDownloadManagerTests.swift | Correctness | Batch download orchestration |
| Multi-File Rollback Tests | MultiFileRollbackTests.swift | Correctness | Atomic rollback on error |
| Offline Mode Gate | OfflineModeGateTests.swift | Correctness | Offline cache behavior |
| Acervo.publishModel | PublishModelTests.swift | Correctness | CDN mutation API |
| Acervo.recache | RecacheTests.swift | Correctness | Recache operation |
| Registry Integrity Check | RegistryIntegrityCheckTests.swift | Correctness | Registry schema invariants |
| Resumable Download Tests | ResumableDownloadTests.swift | Correctness | Resume from .part files |
| S3CDNClient | S3CDNClientTests.swift | Correctness | R2 client request/response |
| Secure Download Session Tests | SecureDownloadSessionTests.swift | Correctness | Redirect rejection and security |
| SigV4Signer Tests | SigV4SignerTests.swift | Correctness | AWS SigV4 signature generation |
| Slug-keyed Availability (S2) | SlugAvailabilityTests.swift | Correctness | Slug-based availability checks |
| Slug-keyed deleteModel (S4) | SlugDeleteModelTests.swift | Correctness | Slug-based deletion |
| Slug-keyed ensureAvailable (S3) | SlugEnsureAvailableTests.swift | Correctness | Slug-based ensure-available |
| Stream-and-Hash Download Tests | StreamAndHashTests.swift | **Correctness** | Incremental SHA-256 during streaming (asserts digest correctness, not timing) |
| Shared Static State | SharedStaticStateSuite.swift | Correctness | Test support suite |

### AcervoToolTests (11 suites)

| Suite | File | Classification | Notes |
|-------|------|---|---|
| CDN Manifest Fetch (Read-Only Smoke) | CDNManifestFetchTests.swift | Correctness | Live CDN smoke test (slow, but deterministic assertions) |
| DeleteCommand Tests | DeleteCommandTests.swift | Correctness | CLI delete command parsing |
| DownloadCommand Tests | DownloadCommandTests.swift | Correctness | CLI download command |
| HuggingFaceClient Tests | HuggingFaceClientTests.swift | Correctness | HF API client |
| ManifestCommand Tests | ManifestCommandTests.swift | Correctness | CLI manifest generation |
| Process Environment | ProcessEnvironmentSuite.swift | Correctness | Environment variable handling |
| RecacheCommand Tests | RecacheCommandTests.swift | Correctness | CLI recache command |
| ShipCommand Tests | ShipCommandTests.swift | Correctness | CLI ship command (dry-run and upload) |
| ToolCheck Tests | ToolCheckTests.swift | Correctness | Tool prerequisites validation |
| UploadCommand Tests | UploadCommandTests.swift | Correctness | CLI upload command |
| VerifyCommand Tests | VerifyCommandTests.swift | Correctness | CLI verify command |

---

## Missing Performance Test Plan

**Status**: Does not exist.

According to the EXECUTION_PLAN and the parked QUARTERMASTER-02 plan, a `SwiftAcervo-Performance.xctestplan` should exist to house wall-clock and throughput tests. Currently:

1. **macOS plan** runs 79 suites (68 SwiftAcervoTests + 11 AcervoToolTests)
2. **iOS plan** runs 67 suites (68 SwiftAcervoTests; note: excludes AcervoToolTests as expected)
3. **Performance plan** — absent

No performance test is currently on a Performance plan, so there is no violation of the rule "performance tests MUST NOT be on CI plans." However, **the absence of the Performance plan blocks future sorties (CSR-5 in the parked plan, or equivalent perf sorties in successor missions) that need a place to land wall-clock tests**.

---

## Correctness Tests On Performance Plan

**Finding**: **NONE FOUND.** The QM01 planner-wrong-#1 mistake (deterministic correctness test Test F landed on the perf plan) is NOT present in the current tree because the Performance plan does not exist. All 79 test suites are either on macOS or iOS plans, and all are classified as correctness tests (no tests measure wall-clock or throughput).

This is an accidental pass — the structural invariant is upheld only because the Performance plan has not been created yet.

---

## Recommendations

### Immediate (Blocker for CIH-2)

1. **Create `SwiftAcervo-Performance.xctestplan`** — Define the structure:
   ```json
   {
     "configurations": [
       {
         "id": "<UUID>",
         "name": "Performance",
         "options": { /* optional */ }
       }
     ],
     "defaultOptions": {},
     "testTargets": [
       {
         "target": {
           "containerPath": "container:",
           "identifier": "SwiftAcervoTests",
           "name": "SwiftAcervoTests"
         },
         "skippedTests": [
           // All test suites except performance tests
           // For now, skip all suites (none are perf tests yet)
           // Once a perf test like StreamingPerformanceTests exists,
           // remove it from skippedTests to make it run on this plan.
         ]
       }
     ],
     "version": 1
   }
   ```

   **Note**: In the current codebase, there are no performance tests yet. The Performance plan should be created as a scaffolding, with all suites initially skipped (or explicitly select none). When future sorties add performance tests (e.g., wall-clock throughput tests), those will be added to the Performance plan's `selectedTests` and removed from the CI plans' `skippedTests`.

2. **Update Makefile** — Add a `test-perf` target that invokes:
   ```bash
   make test-perf:
   	xcodebuild test -testPlan SwiftAcervo-Performance ...
   ```

3. **Wire into CI** — Update the workflow to:
   - Run `make test` (macOS plan) in CI.
   - **NOT** run `make test-perf` in CI (perf tests are opt-in).

### For Future Missions

- When adding a performance test (e.g., wall-clock throughput, memory profiling), **create the test file**, mark it with a test attribute that identifies it as performance-only, and ensure it appears in `SwiftAcervo-Performance.xctestplan`'s `selectedTests`, not in the CI plans.
- Use the shape gate (CIH-2 task 3) to enforce: *"No test suite except performance-specific ones may appear in `skippedTests` on the CI plans."*

---

## Validation Against Parked Plan

The parked QUARTERMASTER-02 plan's CIH-1 task list (Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md, lines 289–307) specified:

> 1. List every test class under `Tests/`. For each, determine whether it currently runs under `SwiftAcervo-macOS.xctestplan` and `SwiftAcervo-iOS.xctestplan`.
> 2. Confirm the ONLY entry under `skippedTests` on the CI plans is `StreamingPerformanceTests`.
> 3. Confirm `SwiftAcervo-Performance.xctestplan`'s `selectedTests` lists ONLY `StreamingPerformanceTests`.

**Validation Results**:

1. ✓ **Task 1**: All 79 test classes listed in the inventory above.
2. ✗ **Task 2**: No `skippedTests` entries exist on CI plans (both are empty/absent). `StreamingPerformanceTests` is not mentioned because it does not exist in the v0.15.x tree. The parked plan's assumption that a `StreamingPerformanceTests` class would exist was specific to the CSR-* (chunked-streaming-rebuild) mission that was parked and deferred.
3. ✗ **Task 3**: `SwiftAcervo-Performance.xctestplan` does not exist.

**Conclusion**: The parked plan anticipated the parallel-range rebuild (CSR-1..CSR-5) and the performance tests it would introduce (`StreamingPerformanceTests`). Since that mission was parked, the Performance plan and the performance tests are absent. The current eighth-master mission does not add performance tests; it focuses on the validity oracle (EM-*) and CI hygiene (CIH-*). **The Performance plan is a prerequisite for future missions**, not for the current one.

---

## Summary for CIH-2

CIH-2 must:

1. Create the Performance plan (initially with all suites in `skippedTests` until a perf test is added).
2. Update Makefile to explicitly name plans in `make test` and `make test-perf`.
3. Add the shape gate (`make test-plan-shape`) that asserts no test suite outside a performance-specific allowlist appears in `skippedTests` on CI plans.
4. Wire the shape gate into CI workflow before `make test`.

**Non-mechanical findings** (if any — see next section) carry forward to `QUEUE.md`.

---

## Non-Mechanical Findings

**None identified.** All findings above are mechanical (test-plan scaffolding and structure, not test code or design changes). CIH-2 can proceed with mechanical fixes.
