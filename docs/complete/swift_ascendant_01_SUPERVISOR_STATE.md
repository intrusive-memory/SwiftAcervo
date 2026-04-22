---
operation_name: Operation Swift Ascendant
mission_slug: model-download-manager
mission_number: 01
starting_commit: af8389fa180dfba08d32af1b3892fbf38a8b1afe
starting_branch: development
mission_branch: mission/model-download-manager/01
execution_plan: EXECUTION_PLAN.md
created_at: 2026-04-17T00:00:00Z
---

# SUPERVISOR_STATE: Operation Swift Ascendant

## Terminology

**Mission** — The definable scope of work: Create ModelDownloadManager actor with comprehensive tests and documentation.

**Sortie** — Atomic agent tasks within the mission (one clear objective per dispatch):
1. Implement ModelDownloadManager.swift
2. Add comprehensive tests
3. Update AGENTS.md with API docs
4. Add example documentation

**Work Unit** — The grouping of all sorties for this mission (ModelDownloadManager).

---

## Mission Overview

**Operation**: Swift Ascendant  
**Project**: SwiftAcervo  
**Scope**: ModelDownloadManager actor with tests and documentation  
**Status**: RUNNING

---

## Work Unit: ModelDownloadManager

| State | COMPLETED |
|-------|-----------|
| Total Sorties | 4 |
| Completed | 4 |
| In Progress | 0 |
| Pending | 0 |

### Sortie Queue

#### Sortie 1/4: Implement ModelDownloadManager.swift
- **Status**: COMPLETED ✅
- **Assigned to**: Agent (Opus 4.7)
- **Model**: Opus 4.7 (critical path, complex actor implementation)
- **Objective**: Create `ModelDownloadManager` actor with `ensureModelsAvailable()` and `validateCanDownload()` methods
- **Entry Criteria**:
  - SwiftAcervo sources available at `Sources/SwiftAcervo/`
  - `Acervo` API documented in AGENTS.md
  - `AcervoError` types understood
- **Exit Criteria**:
  - [ ] File `Sources/SwiftAcervo/ModelDownloadManager.swift` created
  - [ ] Actor compiles with Swift 6 strict concurrency
  - [ ] `shared` singleton properly initialized
  - [ ] `ensureModelsAvailable(modelIds:progress:)` implementation downloads each model via Acervo
  - [ ] `validateCanDownload(modelIds:)` implementation fetches manifests and returns total bytes
  - [ ] `ModelDownloadProgress` struct defined with all fields (model, fraction, bytesDownloaded, bytesTotal, currentFileName)
  - [ ] Error handling: catches AcervoError, logs context, re-throws unchanged
  - [ ] `make build` succeeds
  - [ ] No warnings or type mismatches
- **Context Files**:
  - `EXECUTION_PLAN.md` (Phase 1 section)
  - `AGENTS.md` (Acervo API reference)
  - `Sources/SwiftAcervo/AcervoError.swift` (error types)
  - `Sources/SwiftAcervo/Acervo.swift` (public API)

---

#### Sortie 2/4: Add Comprehensive Tests
- **Status**: PENDING
- **Assigned to**: (awaiting dispatch after Sortie 1)
- **Model**: Sonnet 4.6 (test writing, moderate complexity)
- **Objective**: Write 6 test cases for ModelDownloadManager covering happy path, errors, and edge cases
- **Entry Criteria**:
  - Sortie 1 complete and verified (`ModelDownloadManager.swift` exists and compiles)
  - Understanding of test mocking with temporary directories
- **Exit Criteria**:
  - [ ] File `Tests/SwiftAcervoTests/ModelDownloadManagerTests.swift` created
  - [ ] 6 test functions implemented:
    - `testEnsureModelsAvailableWhenAlreadyLocal()`
    - `testEnsureModelsAvailableDownloadsWhenMissing()`
    - `testProgressAggregatesAcrossMultipleModels()`
    - `testValidateCanDownloadReturnsTotalBytes()`
    - `testErrorHandlingCatchesAcervoErrors()`
    - `testCancellationStopsDownloadSequence()`
  - [ ] All tests use temporary model directory for isolation
  - [ ] All 6 tests pass: `make test` succeeds
  - [ ] No test warnings or flaky assertions
- **Context Files**:
  - `EXECUTION_PLAN.md` (Phase 2 section with test cases)
  - `Sources/SwiftAcervo/ModelDownloadManager.swift` (implementation to test)
  - `Tests/SwiftAcervoTests/` (existing test patterns)

---

#### Sortie 3/4: Update AGENTS.md
- **Status**: PENDING
- **Assigned to**: (awaiting dispatch after Sortie 1, can parallel with Sorties 2-4)
- **Model**: Haiku 4.5 (documentation writing, straightforward)
- **Objective**: Add ModelDownloadManager section to AGENTS.md with usage examples, API reference, and best practices
- **Entry Criteria**:
  - Sortie 1 complete (ModelDownloadManager.swift exists)
  - AGENTS.md structure understood
- **Exit Criteria**:
  - [ ] New `## ModelDownloadManager` section added after "Component Registry Methods" section
  - [ ] Usage example block complete with consuming library pattern
  - [ ] API reference table documents both public methods (`ensureModelsAvailable`, `validateCanDownload`)
  - [ ] `ModelDownloadProgress` struct documentation with all fields
  - [ ] Error handling section lists all AcervoError cases (modelNotFound, manifestChecksumMismatch, downloadFailed, checksumMismatch)
  - [ ] Best practices section has ≥5 numbered items
  - [ ] "Best Practices for Consuming Libraries" section updated to reference ModelDownloadManager
  - [ ] No markdown syntax errors
- **Context Files**:
  - `EXECUTION_PLAN.md` (Phase 3 section)
  - `AGENTS.md` (existing structure and format)
  - `Sources/SwiftAcervo/ModelDownloadManager.swift` (API to document)

---

#### Sortie 4/4: Add Example Documentation
- **Status**: PENDING
- **Assigned to**: (awaiting dispatch after Sortie 1, can parallel with Sorties 2-3)
- **Model**: Haiku 4.5 (documentation writing, straightforward)
- **Objective**: Create `Docs/ModelDownloadManager-Examples.md` with usage examples
- **Entry Criteria**:
  - Sortie 1 complete (ModelDownloadManager.swift exists)
  - Docs directory structure understood
- **Exit Criteria**:
  - [ ] File `Docs/ModelDownloadManager-Examples.md` created
  - [ ] Contains ≥3 distinct examples:
    - Single model download example
    - Multiple models with custom progress UI example
    - Error handling patterns example
  - [ ] Disk space validation workflow example included
  - [ ] Cancellation and resume behavior example included
  - [ ] All code examples are valid Swift and match actual API
  - [ ] No markdown syntax errors
- **Context Files**:
  - `EXECUTION_PLAN.md` (Phase 4 section)
  - `Sources/SwiftAcervo/ModelDownloadManager.swift` (API to document)
  - `Docs/` (existing documentation patterns)

---

## Dispatch Log

### Dispatch 1: Sortie 1/4 (Implement ModelDownloadManager)
- **Dispatched at**: [PENDING]
- **Status**: PENDING
- **Task ID**: [awaiting dispatch]
- **Attempt**: 0/3

---

## Decisions Log

**Decision 1: Mocking Strategy** (LOCKED)
- Integration tests use temporary model directories, not mocks
- Rationale: Simpler, more realistic, no architecture changes
- Status: Accepted by maintainer

**Decision 2: Acervo.ensureAvailable() Semantics** (LOCKED)
- Empty `files: []` array downloads all files in manifest
- Rationale: Intended behavior, verified acceptable
- Status: Confirmed

**Decision 3: Error Handling** (LOCKED)
- Re-throw `AcervoError` unchanged (no wrapping)
- Manager logs context internally, consumer libraries wrap to app-specific errors
- Rationale: Simpler API contract, matches existing patterns
- Status: Finalized

**Decision 4: Progress Aggregation** (LOCKED)
- Cumulative bytes across all models via `CDNManifest.sizeBytes`
- Rationale: Accurate, reflects real user download experience
- Status: Confirmed via code audit

**Decision 5: Disk Space Validation** (LOCKED)
- Manifest fetch approach acceptable (~100-500ms per model)
- Intended for pre-flight UI checks
- Rationale: Cost is unavoidable anyway; manifests re-fetched during download
- Status: Accepted

---

## Notes

- All sorties ready for execution
- Sortie 1 is on critical path; must complete before others can fully begin
- Sorties 2-4 can parallelize after Sortie 1 completes
- Estimated total time: ~3-3.5 hours
- Build verification: `make build` after each sortie completion
- Test verification: `make test` after Sortie 2
