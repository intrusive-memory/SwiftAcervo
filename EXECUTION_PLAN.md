# SwiftAcervo Execution Plan: ModelDownloadManager

## Terminology

**Mission** — The definable scope of work: Create ModelDownloadManager actor with comprehensive tests and documentation. 

**Sortie** — Atomic agent tasks within the mission (one clear objective per dispatch):
1. Implement ModelDownloadManager.swift
2. Add comprehensive tests
3. Update AGENTS.md with API docs
4. Add example documentation

**Work Unit** — The grouping of all sorties for this mission (ModelDownloadManager).

---

**Objective**: Create a canonical, reusable `ModelDownloadManager` actor in SwiftAcervo that provides standardized model download orchestration with progress reporting and error handling. This becomes shared infrastructure for all consuming libraries (SwiftBruja, SwiftTuberia, etc.).

**Timeline**: ~3-3.5 hours (after blockers resolved)

**Outcome**: 
- ✅ `ModelDownloadManager.swift` with public actor API
- ✅ Updated AGENTS.md with usage examples and best practices
- ✅ Comprehensive tests for manager
- ✅ Example: how consuming libraries call `ensureModelsAvailable()`

---

## ✅ REFINEMENT VERDICT: READY FOR EXECUTION

**Status**: All 4 refinement passes complete. Plan is ready to execute immediately.

**Refinement Results**:
- ✅ **Pass 1 (Atomicity)**: All 4 sorties are atomic and testable. No splits/merges needed.
- ✅ **Pass 2 (Priority)**: Sorties optimally ordered. Sortie 1 is critical path.
- ✅ **Pass 3 (Parallelism)**: Sorties 2, 3, 4 can parallelize after Sortie 1 (no file conflicts, no build deps). ~30min speedup possible.
- ✅ **Pass 4 (Questions)**: 0 blocking issues, 0 critical unknowns, 0 vague criteria. All decisions finalized.

**Key Decisions Locked**:
1. ✅ **Mocking strategy**: Integration tests with temporary model directories (Option A)
   - No MockAcervo; use temp base directory during tests
   - Simpler, more realistic, no architecture changes
   
2. ✅ **Acervo.ensureAvailable() semantics**: Assumption accepted
   - `files: []` downloads all files in manifest (verified as acceptable)
   
3. ✅ **Error handling**: Re-throw AcervoError unchanged
   - Manager catches, logs context, re-throws as-is
   - Consuming libraries wrap to app-specific errors

4. ✅ **Progress aggregation**: CDNManifest.sizeBytes approach
   - Sum manifests for totalBytes; track Acervo progress for bytesDownloaded

5. ✅ **Disk space validation**: Manifest fetch approach acceptable
   - O(N) CDN requests for N models (~100-500ms per model)
   - Reasonable for pre-flight UI checks

---

## Phase 1: Implement ModelDownloadManager

**File**: `Sources/SwiftAcervo/ModelDownloadManager.swift`

**Requirements**:
- Public actor (Sendable) for thread-safe orchestration
- Singleton via `static let shared`
- Two main public methods:
  1. `ensureModelsAvailable(_:progress:)` — orchestrate multiple model downloads
  2. `validateCanDownload(_:)` — disk space validation before attempting downloads
- Aggregate progress across all models with clear reporting
- Typed errors that consuming libraries can catch and wrap

**Public API Signature**:
```swift
public actor ModelDownloadManager: Sendable {
    public static let shared: ModelDownloadManager
    
    /// Ensure all specified models are downloaded and available
    public func ensureModelsAvailable(
        _ modelIds: [String],
        progress: @Sendable (ModelDownloadProgress) -> Void
    ) async throws
    
    /// Validate sufficient disk space before downloading
    public func validateCanDownload(
        _ modelIds: [String]
    ) async throws -> Int64  // Returns total bytes needed
}

public struct ModelDownloadProgress: Sendable {
    public let model: String           // modelId being downloaded
    public let fraction: Double        // 0.0 to 1.0
    public let bytesDownloaded: Int64
    public let bytesTotal: Int64
    public let currentFileName: String // which file in the model
}
```

**Implementation Details**:
- For each model ID: call `Acervo.ensureAvailable(modelId, files: [])`
  - Empty files array means download all files in manifest
- Aggregate progress: track cumulative bytes across all models
- Error handling: catch `AcervoError` cases and throw with context
- Per-model locking: serialize sequential downloads (already handled by Acervo's per-model locking)
- Disk space check: sum manifest file sizes before downloading

**Acceptance Criteria**:
- [ ] Actor compiles with Swift 6 strict concurrency
- [ ] `shared` singleton is properly initialized
- [ ] `ensureModelsAvailable()` downloads each model in sequence
- [ ] Progress callback fires for each file chunk (via Acervo's progress)
- [ ] `validateCanDownload()` returns accurate byte count (sum of manifest sizes)
- [ ] Errors are caught, contextualized, and thrown
- [ ] Actor is Sendable and thread-safe

---

## Phase 2: Add Comprehensive Tests

**File**: `Tests/SwiftAcervoTests/ModelDownloadManagerTests.swift`

**Test Cases**:

1. **`testEnsureModelsAvailableWhenAlreadyLocal()`**
   - Mock: Models already available locally
   - Assert: No download calls made, completes immediately
   - Assert: Progress callback fired with 100%

2. **`testEnsureModelsAvailableDownloadsWhenMissing()`**
   - Mock: `Acervo.ensureAvailable()` called successfully
   - Assert: ModelDownloadProgress callbacks fired in sequence
   - Assert: All models marked available after completion

3. **`testProgressAggregatesAcrossMultipleModels()`**
   - Mock: Two models, each 100MB
   - Assert: Progress callback shows cumulative 0-200MB (not 0-100% twice)
   - Assert: Current model and file name included in progress

4. **`testValidateCanDownloadReturnsTotalBytes()`**
   - Mock: Two models in manifest
   - Assert: Returns sum of all file sizes (bytes, not MB)

5. **`testErrorHandlingCatchesAcervoErrors()`**
   - Mock: `Acervo.ensureAvailable()` throws `.modelNotFound`
   - Assert: Caught and rethrown as SwiftAcervo error
   - Assert: Original error context preserved

6. **`testCancellationStopsDownloadSequence()`**
   - Mock: Slow download (use Task cancellation)
   - Assert: Partial downloads not cleaned up (resume capability)
   - Assert: Graceful error on next attempt

**Mocking Strategy**:
- Create `MockAcervo` struct with configurable download behavior
- Inject into manager via internal initializer for testing
- Default to real Acervo for integration tests

---

## Phase 3: Update AGENTS.md

**Sections to add/modify**:

### New Section: "ModelDownloadManager"
Location: After "Component Registry Methods" in API Overview

```markdown
## ModelDownloadManager

ModelDownloadManager provides standardized multi-model download orchestration for consuming libraries. It handles concurrent progress tracking, disk space validation, and error context.

### Usage Example: Consuming Library Startup

```swift
import SwiftAcervo

// In your library's initialization phase
func loadModels() async throws {
    // Validate disk space first
    let totalBytes = try await ModelDownloadManager.shared.validateCanDownload([
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    ])
    
    print("Will download \(totalBytes / (1024*1024)) MB total")
    
    // Download with progress reporting
    try await ModelDownloadManager.shared.ensureModelsAvailable([
        "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
    ]) { progress in
        let percent = Int(progress.fraction * 100)
        let mb = progress.bytesDownloaded / (1024 * 1024)
        let total = progress.bytesTotal / (1024 * 1024)
        print("\r[\(progress.model)] \(progress.currentFileName): \(percent)% (\(mb)/\(total) MB)", terminator: "")
        fflush(stdout)
    }
    
    // All models now available
    print("\nModels ready!")
}
```

### Public API

| Method | Description |
|--------|-------------|
| `ensureModelsAvailable(_:progress:)` | Download all specified models if not already available |
| `validateCanDownload(_:)` | Check disk space and return total bytes needed |

### Return Types

```swift
public struct ModelDownloadProgress: Sendable {
    public let model: String           // e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit"
    public let fraction: Double        // 0.0 to 1.0 cumulative progress
    public let bytesDownloaded: Int64  // Total bytes downloaded across all models
    public let bytesTotal: Int64       // Total bytes to download across all models
    public let currentFileName: String // e.g., "model.safetensors"
}
```

### Error Handling

`ModelDownloadManager.ensureModelsAvailable()` throws `AcervoError`:

- `modelNotFound(modelId: String)` — Model doesn't exist on CDN
- `manifestChecksumMismatch(modelId: String)` — Manifest integrity check failed
- `downloadFailed(reason: String)` — Network error (transient)
- `checksumMismatch(fileName: String)` — File corrupted during download

Catch these at the consuming library level and convert to app-specific error types.

### Best Practices

1. **Always validate disk space first**: Call `validateCanDownload()` before user-initiated downloads
2. **Show aggregate progress**: Display cumulative MB downloaded, not per-model percentages
3. **Serialize model downloads**: Manager handles this (sequential, not parallel)
4. **Handle cancellation gracefully**: If user cancels, partial files remain (resume on next attempt)
5. **Distinguish model types in messages**: Include model name in progress callback output
```

### Modify Existing Section: "Best Practices for Consuming Libraries"

Replace the section with a link to ModelDownloadManager:

```markdown
### Best Practices for Consuming Libraries

Use **ModelDownloadManager** for standardized multi-model download orchestration:

```swift
try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
    // Handle progress callback
}
```

For advanced patterns (custom progress UI, library-specific error mapping), see [ModelDownloadManager](#modeldownloadmanager) section above.

Single-model validation can still use `Acervo.modelInfo()` directly for fast CDN checks.
```

---

## Phase 4: Add Example Documentation

**File**: `Docs/ModelDownloadManager-Examples.md` (new)

**Content**:
- Simple use case (single model download)
- Advanced use case (multiple models with custom progress UI)
- Error handling patterns (catch + convert to library-specific errors)
- Disk space validation workflow
- Cancellation and resume behavior

---

## Phase 5: Integration with Existing Code

**Verify no breaking changes**:
- [ ] `Acervo` static methods unchanged
- [ ] `AcervoManager` behavior unchanged
- [ ] `ComponentRegistry` behavior unchanged
- [ ] Existing tests still pass

**Compile check**:
```bash
make clean
make resolve
make build
make test
```

---

## Checklist

- [ ] Phase 1: Create `ModelDownloadManager.swift`
  - [ ] Actor definition with `shared` singleton
  - [ ] `ensureModelsAvailable()` implementation
  - [ ] `validateCanDownload()` implementation
  - [ ] `ModelDownloadProgress` struct
  - [ ] Error handling (catch + contextualize)
  - [ ] Disk space calculation logic
  
- [ ] Phase 2: Add tests
  - [ ] 6 test cases pass
  - [ ] Mocking strategy in place
  - [ ] Coverage for happy path + error cases
  
- [ ] Phase 3: Update AGENTS.md
  - [ ] New "ModelDownloadManager" section added
  - [ ] Usage examples included
  - [ ] API reference complete
  - [ ] Best practices section updated
  
- [ ] Phase 4: Add example documentation
  - [ ] Examples file written
  - [ ] Multiple use cases documented
  
- [ ] Phase 5: Integration
  - [ ] Full test suite passes
  - [ ] No regressions in existing code
  - [ ] Compile with `make build` succeeds

---

## Notes

- `ModelDownloadManager` is a **shared utility** — all consuming libraries should use it
- **Singleton pattern**: `ModelDownloadManager.shared` is initialized once, reused globally
- **Error mapping**: Consuming libraries catch `AcervoError` and throw app-specific errors (e.g., `BrujaError.modelNotDownloaded`)
- **Disk space validation**: Optional but recommended for large models
- **Progress aggregation**: Cumulative across all models, not per-model (shows true user experience)

---

## Success Criteria

When complete, consuming libraries can adopt `ModelDownloadManager` and reduce their model download code to:

```swift
// Before (complex per-library orchestration)
func downloadModels() async throws { ... }  // 50+ lines per library

// After (standardized via manager)
try await ModelDownloadManager.shared.ensureModelsAvailable(requiredModels) { progress in
    updateUI(with: progress)
}
```

---

---

## Refinement Results (All 4 Passes)

### Pass 1: Atomicity & Testability ✅ PASS

**Summary**: All 4 sorties are atomically focused and have machine-verifiable acceptance criteria, with one exception noted.

| Sortie | Atomicity | Testability | Context Fitness | Verdict |
|--------|-----------|------------|-----------------|---------|
| 1. ModelDownloadManager | ✅ | ✅ | ✅ Right-sized (12 turns) | Ready |
| 2. Tests | ✅ | ✅ | ✅ Right-sized (15 turns) | Ready |
| 3. AGENTS.md | ✅ | ⚠️ Vague ACs | ✅ Right-sized (6 turns) | Enhanced |
| 4. Examples | ✅ | ⚠️ Vague ACs | ✅ Right-sized (4 turns) | Enhanced |

**Auto-fixes applied**:
- **Sortie 3**: Enhanced acceptance criteria
  - [ ] `## ModelDownloadManager` section exists after "Component Registry Methods"
  - [ ] Usage example block complete
  - [ ] API reference table documents both methods
  - [ ] Error handling section lists ≥4 AcervoError cases
  - [ ] Best practices section has ≥5 numbered items

- **Sortie 4**: Enhanced acceptance criteria
  - [ ] File `Docs/ModelDownloadManager-Examples.md` exists
  - [ ] Contains ≥3 distinct examples (single, multiple, error handling)
  - [ ] Disk space validation workflow example included
  - [ ] Cancellation and resume behavior example included

**Sorties after refinement**: 4 (no splits/merges needed)

---

### Pass 2: Prioritization ✅ PASS

| Sortie | Priority Score | Reasoning | Order |
|--------|-----------|-----------|-------|
| 1. ModelDownloadManager | 15 | Foundation (high risk, 3 dependents) | Execute 1st |
| 2. Tests | 2 | Depends on #1, test code (lower risk) | Execute 2nd or parallel |
| 3. AGENTS.md | 1.5 | Depends on #1, documentation | Can parallel after #1 |
| 4. Examples | 1.5 | Depends on #1, documentation | Can parallel after #1 |

**Current order is already optimal** — No reordering needed.

---

### Pass 3: Parallelism ✅ PASS

**Dependency graph**:
```
Phase 1 (sequential):
  → Sortie 1: Implement ModelDownloadManager (supervising agent, has build)

Phase 2 (parallel):
  → Sortie 2: Tests (sub-agent 2, no build)
  → Sortie 3: AGENTS.md (sub-agent 3, no build)
  → Sortie 4: Examples (sub-agent 4, no build)
```

**Parallelism opportunity**: After Sortie 1 completes, Sorties 2, 3, 4 can run simultaneously with 3 sub-agents.

**Critical path**: Sortie 1 → max(Sortie 2, 3, 4) → Done
- Length: 2 phases
- Bottleneck: Sortie 2 (tests, ~1 hour)
- Speedup: ~14% time savings (~30 minutes)

**File conflicts**: None (each sortie writes to different files)
**Build constraints**: Only Sortie 1 requires `make build`; Sorties 2-4 have no build operations

---

### Pass 4: Open Questions & Vague Criteria ✅ PASS (All resolved)

**Issues found**: 14 total, **all resolved**
- Blocking issues: 2 → **0** (both decisions made)
- Critical unknowns: 3 → **0** (all clarified)
- Non-blocking issues: 9 (can address during execution)

---

## Refinement Issues (Detailed Analysis)

### ✅ BLOCKING ISSUE 1 — RESOLVED: Mocking Strategy

**Sorties affected**: 2 (Tests)

**Decision**: Integration tests with temporary model directories (Option A)

**Implementation approach**:
- Test setup creates temporary directory for model downloads during test
- Each test configures Acervo to use temp base directory
- Tests call `ModelDownloadManager.shared.ensureModelsAvailable()` with real Acervo API
- Acervo downloads to temp directory (real downloads, fully isolated)
- Test teardown cleans up temp directory

**Benefits**:
- No architectural changes to ModelDownloadManager or Acervo
- `shared` singleton remains clean and simple
- Tests are realistic (exercises real download + validation logic)
- Simpler test code than dependency injection
- Easy to implement with XCTestDynamicOverlay or FileManager temp directory

**Test cases** (6 functions using temp directories):
1. `testEnsureModelsAvailableWhenAlreadyLocal()` — seed temp dir with pre-downloaded files
2. `testEnsureModelsAvailableDownloadsWhenMissing()` — download to empty temp dir
3. `testProgressAggregatesAcrossMultipleModels()` — two models to temp dir, verify cumulative progress
4. `testValidateCanDownloadReturnsTotalBytes()` — fetch manifests, verify byte count
5. `testErrorHandlingCatchesAcervoErrors()` — simulate CDN errors with inaccessible temp dir
6. `testCancellationStopsDownloadSequence()` — cancel mid-download, verify partial state

---

### ✅ BLOCKING ISSUE 2 — RESOLVED: Acervo.ensureAvailable() Semantics

**Sorties affected**: 1 (Implementation)

**Decision**: Assumption accepted as-is

**Statement**: `Acervo.ensureAvailable(modelId, files: [])` with empty `files` array downloads all files in the manifest.

**Rationale**: 
- Verified acceptable by codebase maintainer
- Implementation detail is internal to Acervo; manager abstracts it
- Plan assumes empty array = "download all"; this is the intended behavior

---

### ✅ CRITICAL UNKNOWN 1: Progress Aggregation Scope — RESOLVED

**Sorties affected**: 1, 2, 3

**Resolution**: CDNManifest already contains `sizeBytes: Int64` for each file (see CDNManifest.swift line 69).

**How it works**:
1. When `ensureModelsAvailable()` is called, fetch manifest for each model (unavoidable—needed for downloads anyway)
2. Sum `manifest.files[].sizeBytes` across all models → `totalBytes`
3. As files download, Acervo's progress callbacks provide cumulative `bytesDownloaded`
4. Report `(bytesDownloaded / totalBytes)` as cumulative progress

**Details**:
- `bytesTotal` in ModelDownloadProgress: cumulative across all requested models
- `bytesDownloaded`: cumulative bytes downloaded so far
- Manifest fetch is unavoidable, but it's a one-time cost per model (same cost as downloading first file)
- No pre-computation needed—we get exact sizes as manifests are fetched

**Acceptance criteria** (clarified):
- [ ] Progress callback fires for each file chunk (from Acervo's download progress)
- [ ] `bytesDownloaded` is cumulative sum across all models
- [ ] `bytesTotal` is sum of all manifest file sizes across all models
- [ ] `fraction = bytesDownloaded / bytesTotal` (0.0 to 1.0)

---

### ✅ CRITICAL UNKNOWN 2: Disk Space Validation Cost and Purpose — RESOLVED

**Sorties affected**: 1, 3

**Resolution**: Manifest fetch is unavoidable and reasonable—it's the same cost as downloading the first file.

**Implementation**:
- `validateCanDownload()` fetches each model's manifest from CDN
- Sums `manifest.files[].sizeBytes` to return accurate total bytes needed
- Cost: O(N) CDN requests, where N = number of models
- Latency: ~100-500ms per model (network bound, not CPU)
- Caching: Optional optimization (not required for correctness)

**Why this is acceptable**:
- Intended use case: UI pre-flight check ("This will download X GB")
- User initiates download → we fetch manifests while user reads a confirmation dialog
- Same manifests are fetched again during download setup (unavoidable)
- Caching would only help if user validates twice in quick succession (nice-to-have, not required)

**Acceptance criteria** (clarified):
- [ ] `validateCanDownload()` fetches manifests and sums `sizeBytes` across all models
- [ ] Returns total bytes (Int64) as cumulative sum
- [ ] Throws AcervoError if any model's manifest fetch fails (modelNotFound, checksumMismatch, etc.)
- [ ] No caching required (manifests are re-fetched during ensureModelsAvailable anyway)

---

### ✅ CRITICAL UNKNOWN 3 — RESOLVED: Error Handling Semantics

**Sorties affected**: 1, 2, 3

**Decision**: Re-throw AcervoError unchanged (no wrapping)

**Implementation approach**:
- Manager catches AcervoError internally for logging/context
- Manager re-throws the same AcervoError unchanged to caller
- No new error type (ModelDownloadManagerError) created
- Consuming libraries catch AcervoError and wrap to app-specific errors (per AGENTS.md pattern)

**Rationale**:
- Simpler API contract (one error type, not two)
- Matches AGENTS.md documentation expectation
- Aligns with existing Acervo error handling pattern in other libraries
- Leaves error mapping to consuming libraries (they know their domain)

**Update to Phase 1 implementation details**:
- Line 97: Change "Error handling: catch `AcervoError` cases and throw with context" to "catch `AcervoError`, log context, re-throw unchanged"
- Line 107: Change "Errors are caught, contextualized, and thrown" to "Errors are caught, logged, and re-thrown unchanged"

**Update to Sortie 2 test case**:
- `testErrorHandlingCatchesAcervoErrors()` verifies manager re-throws AcervoError (not a new wrapped type)

---

### Additional non-blocking issues

| Issue | Sortie | Severity | Description |
|-------|--------|----------|-------------|
| Missing test AC clarity | 2 | LOW | Test cases reference "No download calls made" but without MockAcervo, this cannot be asserted. Defer until mocking strategy chosen. |
| AGENTS.md example lacks error handling | 3 | LOW | Usage example should show error cases. Can be added during implementation. |
| Example documentation not specified | 4 | LOW | No detail on what use cases to demonstrate. Defer until Phase 1-2 complete. |

---

## ✅ All Blockers Resolved — Ready for Execution

**All 5 decisions made**:
1. ✅ Mocking: Integration tests with temp directories
2. ✅ Acervo semantics: Empty array downloads all files (accepted)
3. ✅ Progress aggregation: Cumulative bytes via CDNManifest.sizeBytes
4. ✅ Disk validation: Manifest fetches acceptable for pre-flight checks
5. ✅ Error handling: Re-throw AcervoError unchanged

**Execution estimate**: ~3-3.5 hours (Sortie 1: ~2h, then parallel Sorties 2-4: ~1-1.5h)

**Ready to execute**: Yes ✅

**Next step**: `/mission-supervisor start /Users/stovak/Projects/SwiftAcervo/EXECUTION_PLAN.md`

---

## Archive: Original Plan Phases (Refined)

### Sortie 1: Implement ModelDownloadManager

**File**: `Sources/SwiftAcervo/ModelDownloadManager.swift`
