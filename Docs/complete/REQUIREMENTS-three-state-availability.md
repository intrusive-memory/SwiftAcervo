# REQUIREMENTS — Three-state availability + resumable, dedup'd, chunked downloads

**Status:** Archived 2026-05-19. Shipped substantially in v0.14.0 (commit `66d1d56`). §4.1, §4.2, §4.3, §4.5, and §4.6 are complete; §4.4 (chunked streaming) was deferred at execution time and continues in the active root [`REQUIREMENTS.md`](../../REQUIREMENTS.md) §2.
**Author of source TODO:** user, 2026-05-18.
**Driving symptom:** In Vinetas, "the model downloads every time, step 0 of 20 sticks for a long time." Live `sample` of the running process showed the dominant CPU cost is byte-at-a-time `Data.append` in `AcervoDownloader.streamDownloadFile`, plus no resume support, plus no in-flight dedup.

**Companion design doc:** [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md) — the architectural narrative for *why* this shape. This file is the *what* and *how-tested*.

---

## 1. Goal

Make `SwiftAcervo` the sole source of truth for model state, exposing exactly **three** states to consumers — `notAvailable`, `downloading(progress:)`, `available` — and make the underlying download path (a) fast, (b) resumable, and (c) deduplicated across concurrent callers.

After this lands, downstream libraries (`SwiftVinetas`, `flux-2-swift-mlx`) can delete their per-engine workaround checks that exist solely because today's `Acervo.isModelAvailable` is the loose "config.json exists" probe.

---

## 2. Invariant the system must hold

A single, async, three-state status function in `SwiftAcervo` is the only source of truth for whether a model can be used right now.

```swift
public enum ModelAvailability: Sendable, Equatable {
    case notAvailable                       // (1) not on disk OR size-mismatched
    case downloading(progress: Double)      // (2) in flight in this process; share the task
    case available                          // (3) on disk and every manifest file size-matches
}

public static func availability(_ modelId: String) async -> ModelAvailability
```

Consequences:

- Two callers that ask Acervo to ensure the same model is available **must share** the in-flight download, not start a second one.
- A second, *third* caller that just wants to *observe* state gets `.downloading(progress:)` without joining the download.
- `.available` *implies* "usable" — every file in the manifest is present at the manifest's recorded `sizeBytes`. The existing loose-check footgun goes away.
- `.downloading` is transient process-state, not on-disk state. After a hard process kill, `availability` returns `.notAvailable` even if `.part` files are present on disk. The on-disk `.part` files are picked up as a resume by the *next* `ensureAvailable` call.

---

## 3. Current state (with code references)

| Concern | Where it lives today | Current behavior | Problem |
|---|---|---|---|
| Availability surface | `Sources/SwiftAcervo/Acervo.swift:299` — `public static func isModelAvailable(_:) -> Bool` | Returns `true` if `config.json` exists at the model root. | Loose; doesn't imply "usable." Downstream consumers (Flux2Engine, Flux2ModelDownloader) have added stricter parallel checks because of this. Two-state, not three-state. |
| Idempotent ensure | `Sources/SwiftAcervo/Acervo.swift:1098` — `public static func ensureAvailable(_:files:progress:telemetry:)` | If `isModelAvailable` is `true` → return; else `download(force: false)`. | No in-flight dedup. Two parallel callers each start independent downloads of the same model. |
| Manager-level serialization | `Sources/SwiftAcervo/AcervoManager.swift:96` — `acquireLock(for:)` polls every 50 ms | Per-model lock for the *manager actor's* `download(...)` entrypoint. | Doesn't help direct callers of `Acervo.ensureAvailable` (the static surface). And it serializes via polling rather than awaiting a shared Task. |
| Streaming download body | `Sources/SwiftAcervo/AcervoDownloader.swift:419` — `streamDownloadFile(...)`, body at `:513-534` | `for try await byte in asyncBytes { buffer.append(byte); ... }` — **one byte per iteration**, appended to a `Data` buffer; flushes when the buffer reaches `streamChunkSize` (4 MB). | Dominant CPU cost per `sample`: `RangeReplaceableCollection.append` → `Data._Representation.replaceSubrange` → `_platform_memmove`, plus `AsyncIteratorProtocol.next(isolation:)`. Multi-GB shards take a very long time even on fast networks. |
| Temp file location | `Sources/SwiftAcervo/AcervoDownloader.swift:483-484` | Writes to `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`. | (a) `temporaryDirectory` may live on a different volume from the final destination — `moveItem` could degrade to copy. (b) UUID names make resume impossible. |
| Failure cleanup | `Sources/SwiftAcervo/AcervoDownloader.swift:500, 548, 563, 585` | `try? fm.removeItem(at: tempFileURL)` on every failure path. | Throws away all partial bytes. The very next attempt starts at offset 0. |
| Fallback path | `Sources/SwiftAcervo/AcervoDownloader.swift:647` — `fallbackDownloadFile(...)` | Calls `URLSession.download(for:)` (whole-file), then `moveItem`. | OK as fallback; needs the same resume/cleanup treatment if we keep it. |
| Per-file cache check | `Sources/SwiftAcervo/AcervoDownloader.swift:1033-1109` | Size-only comparison against the manifest. Emits `cacheHit` / `cacheMiss` telemetry with reason `.notPresent | .sizeChangedRemote | .forcedRefresh`. | This is the right shape for `.available` — we should reuse the same predicate inside the new `availability(_:)` API. |
| Telemetry | `Sources/SwiftAcervo/Telemetry/AcervoTelemetryEvent.swift` (existing) | `cacheHit` / `cacheMiss` / `componentDownloadStart` / `componentDownloadComplete` / `downloadOperationStart` / `downloadOperationComplete` / `manifestFetchStart` / `manifestFetchComplete` already exist. | The three-state API can be derived from these events; no new events are required. We *may* add an optional `downloadResumed(modelID:fileName:resumedFromBytes:)` event but it is not in scope unless it's free. |

---

## 4. Work items

Each item below has explicit acceptance criteria. The mission-supervisor breakdown should treat each as a candidate sortie.

### 4.1 `ModelAvailability` type + `Acervo.availability(_:)` static API

**Public surface (new):**

```swift
public enum ModelAvailability: Sendable, Equatable {
    case notAvailable
    case downloading(progress: Double)   // 0.0...1.0, clamped
    case available
}

public extension Acervo {
    static func availability(_ modelId: String) async -> ModelAvailability
}

public extension AcervoManager {
    /// Convenience wrapper that forwards to the static API. The manager does
    /// not need to hold its lock during a status query.
    func availability(_ modelId: String) async -> ModelAvailability
}
```

**Behavior:**

1. If `InFlightDownloads.contains(modelId)` → return `.downloading(progress:)` using the latest progress sample the in-flight task has published. Source of progress: a `Sendable` atomic stored on the registered `InFlightDownload` entry, updated by the existing per-file progress callback at the manifest level (sum of bytes / total bytes).
2. Else, attempt the strict on-disk check (see §4.3). If every manifest file is present at the manifest's `sizeBytes` → `.available`.
3. Else → `.notAvailable`. **No network I/O is performed by `availability(_:)`** beyond reading the cached manifest if one is on disk; if the manifest isn't cached and we are offline, we return `.notAvailable`. (Acceptable because the *next* `ensureAvailable` call is what would fetch the manifest and start downloads — `availability` is a peek, not a sync.)
4. Method is non-throwing. Any error during the strict check (e.g., I/O glitch) is treated as `.notAvailable` and the error is dropped on the floor — observability is via telemetry, not the return value.

**Manifest caching:** We need an on-disk manifest copy so the strict check can run without network. Today the manifest is only held in memory inside `downloadFiles`. Persist it at `~/Library/Group Containers/<group-id>/SharedModels/{slug}/manifest.json` on first download. Reload from disk on `availability(_:)`. If absent → `.notAvailable`.

**Acceptance:**

- New test file `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift`.
- Test: empty model dir → `.notAvailable`.
- Test: all manifest files present at correct size → `.available`.
- Test: one shard size-mismatched → `.notAvailable` (and a `cacheMiss(.sizeChangedRemote)` is observed via a mock telemetry reporter).
- Test: in-flight download → `.downloading(progress: p)` with monotonically non-decreasing `p` across repeated observations; final state transitions to `.available` after the in-flight task completes.
- Test: hard "process kill" simulation — drop the `InFlightDownloads` registry while a `.part` file is on disk → next `availability(_:)` returns `.notAvailable` (because the size-match check fails on the partial file).

---

### 4.2 `InFlightDownloads` actor + dedup in `ensureAvailable`

**Internal surface (new):**

```swift
actor InFlightDownloads {
    static let shared = InFlightDownloads()

    /// Returns the existing task for this modelId if one is registered.
    /// Otherwise calls `start()` to create one, registers it, and returns it.
    /// Concurrent callers converge on a single Task<Void, Error>.
    func task(
        for modelId: String,
        start: @Sendable @escaping () -> Task<Void, Error>
    ) -> Task<Void, Error>

    /// Latest progress sample for an in-flight task, or nil if not in flight.
    func progress(for modelId: String) -> Double?

    /// Called by the in-flight task itself to publish progress.
    func publishProgress(_ p: Double, for modelId: String)

    /// Called when the task finishes (success or failure) to deregister.
    func finish(_ modelId: String)

    func contains(_ modelId: String) -> Bool
}
```

**Wiring inside `Acervo.ensureAvailable(_:files:...)`:**

1. Acquire-or-create the shared task via `InFlightDownloads.shared.task(for: modelId) { ... }`.
2. If the closure runs (we are the originator), `download(...)` proceeds; the wrapped progress callback publishes overall progress to `InFlightDownloads`. On completion (success or thrown), call `finish(modelId)`.
3. The caller `await`s the returned task. A second concurrent caller that hits step 1 gets the *same* task and `await`s it — no second download.

**Important:** the dedup key is `modelId`, not `(modelId, files)`. Concurrent callers requesting *different* subsets of files for the same model should still share the umbrella task. The originator picks the file set; the joiner waits. If the joiner needed files that the originator didn't request, we *don't* re-fetch — but per the current code, the only public callers that pass non-empty `files:` are tests; production callers pass `[]` meaning "everything in the manifest." Document this trade-off in the API doc comment and add a test that asserts it explicitly. (If we ever need stricter semantics, a follow-up can promote the key to `(modelId, FileSet)`.)

**Acceptance:**

- New test in `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift`: two concurrent `ensureAvailable(modelId, files: [])` calls against a mock `URLSession` only invoke the *manifest* fetch *once* and only invoke *each file* fetch *once*. Use an injected counting `URLSession` to assert.
- Test: after the shared task completes, `InFlightDownloads.contains(modelId)` is `false`.
- Test: when the shared task throws, both callers see the same error (and the registry is cleared so a retry can start fresh).

---

### 4.3 Tighten `isModelAvailable(_:)` semantics

**Contract change:** `Acervo.isModelAvailable(_:)` now returns `true` only if every file in the cached manifest exists with the manifest's `sizeBytes`. The loose "config.json exists" check is removed.

**Compatibility:** This is a **breaking semantic change** for downstream consumers. Mitigations:

1. Bump SwiftAcervo to `0.14.0` (minor — pre-1.0 semver allows breaking minor). Update `Sources/acervo/Version.swift` and `CLAUDE.md`.
2. Add a clearly-named escape hatch for callers that genuinely only want the config probe:
   ```swift
   /// Returns true iff `config.json` exists in the model directory.
   /// Does NOT imply "model is usable." Prefer `availability(_:)` or
   /// `isModelAvailable(_:)` for production use.
   public static func isModelConfigPresent(_ modelId: String) -> Bool
   ```
3. CHANGELOG entry under `0.14.0` calls out:
   - "`isModelAvailable` is now strict — requires all manifest files present at recorded size. Use `isModelConfigPresent` if you really wanted the old loose check."
   - "New `availability(_:)` API supersedes `isModelAvailable` for UI state."
4. The optional SHA-verifying form is **out of scope**. Per the TODO: *"Optionally: verify SHA on a slower `isModelAvailableVerified(_:)`"* — explicitly NOT in this work item. Tracked as a future enhancement.

**Implementation note:** the existing per-file cache check inside `downloadFiles` (`AcervoDownloader.swift:1033-1109`) is the canonical predicate. Extract it to an internal helper `IntegrityVerification.allManifestFilesPresentBySize(manifest:in:) -> Bool` and call it from both `downloadFiles` (so behavior matches) and from `isModelAvailable`.

**Acceptance:**

- Update `Tests/SwiftAcervoTests/AcervoAvailabilityTests.swift` to cover the new strict semantics.
- Test: directory with `config.json` only (no manifest, no other files) → `isModelAvailable` returns `false`; `isModelConfigPresent` returns `true`.
- Test: directory with full manifest contents at correct sizes → `isModelAvailable` returns `true`.
- Test: one file truncated → `isModelAvailable` returns `false`.
- No test should still rely on the loose semantics (find and migrate them).

---

### 4.4 Chunk `streamDownloadFile`

**Deferred at execution time and moved to the active requirements doc.** See [`REQUIREMENTS.md` §2](../../REQUIREMENTS.md) in the repo root. The line reference for the byte-at-a-time loop has shifted to `AcervoDownloader.swift:745` post-§4.5; the substance of the requirement is otherwise unchanged.

---

### 4.5 Resumable downloads

**Replace** the UUID temp file path with a `.part` file colocated with the destination:

```swift
let partURL = destination.appendingPathExtension("part")
```

On each download attempt:

1. If `partURL` exists and `0 < partSize < manifestFile.sizeBytes`:
   - Send `Range: bytes=<partSize>-` in the request.
   - Open the part file for appending.
   - Seed the running SHA-256 hasher by streaming the existing bytes from disk through it before appending new bytes. (Don't try to persist hasher state across processes — too brittle. A 4 GB rehash is faster than redownloading 4 GB.)
2. If `partURL` exists and `partSize == manifestFile.sizeBytes`:
   - Skip the network call. Verify the SHA-256 directly. If it matches, atomic-rename to destination. If not, delete the part file and start over.
3. If `partURL` exists and `partSize > manifestFile.sizeBytes`:
   - Corrupt/oversized — delete and start fresh.
4. Else (`partURL` absent): write to `partURL` from offset 0.

**Server behavior assumption:** R2 supports HTTP range requests for static objects. If the server returns `200 OK` instead of `206 Partial Content`, treat that as "server ignored the range" and discard the partial bytes before consuming the body. Tracked as a runtime guard, not a configuration setting.

**Cleanup policy change:** stop deleting the part file on transient failures (network drop, cancellation). Only delete on:

- Successful completion (after atomic-rename to destination).
- Validated corruption (SHA mismatch after a complete read, size > manifest size, server-rejected range with stale partial).

**Acceptance:**

- New test in `Tests/SwiftAcervoTests/ResumableDownloadTests.swift` using an injected `URLSession` mock:
  - Test: write half of a file, simulate cancellation, restart → second attempt sends `Range: bytes=N-` and final file is byte-identical (SHA matches manifest).
  - Test: half-written part file, second attempt where server returns `200 OK` ignoring the range → final file still verifies correctly (partial bytes discarded).
  - Test: oversized part file → deleted, full re-download succeeds.
  - Test: complete-size part file that hashes correctly → no network call (assert via counting session).
  - Test: complete-size part file with wrong hash → re-download.

---

### 4.6 Delete cleanup-only paths

Once §4.5 is in, an interrupted download is the normal case, not an error. Remove:

- `try? fm.removeItem(at: tempFileURL)` calls at `AcervoDownloader.swift:500, 548, 563, 585` that exist solely to clean up the legacy UUID temp file.
- Any `.fileExists` / `.tempFileURL` cleanup branches that are unreachable after the part-file migration.
- The `tempFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)` construct itself.
- Audit `fallbackDownloadFile(...)` for the same anti-patterns; either give it part-file semantics or document why it's allowed to stay all-or-nothing (it's the fallback for a streaming failure, so it's acceptable to keep it whole-file with a UUID temp — but call that out in a comment).

**Acceptance:**

- `grep -rn "temporaryDirectory" Sources/SwiftAcervo/` shows zero hits in `AcervoDownloader.swift`'s streaming path (one in `fallbackDownloadFile` is OK if we document it).
- All existing tests still pass.

---

## 5. Out of scope

- Component registry / `ComponentDescriptor` semantics — keep as-is. Engines should keep registering components; the change is the read API on top.
- App-Group / `ACERVO_APP_GROUP_ID` directory resolution — unchanged.
- Telemetry event surface — `cacheHit` / `cacheMiss` / `downloadOperationStart` / `downloadOperationComplete` is enough to derive the three states. We may *optionally* add a single new event for resume (`downloadResumed`) if it falls out for free, but it is not required.
- SHA-verifying availability check (`isModelAvailableVerified`) — explicitly punted to a future work item.
- Changes to downstream libraries (`SwiftVinetas`, `flux-2-swift-mlx`, `Vinetas`) — those land in their own PRs once this ships.

---

## 6. Sequencing recommendation

Two PRs:

1. **PR #1 — performance fixes, no API change**
   - §4.4 (chunked streaming)
   - §4.5 (resumable downloads)
   - §4.6 (cleanup-path deletion)
   - Releasable as a patch (`0.13.2`) — pure perf/robustness, no surface change.
2. **PR #2 — three-state API**
   - §4.1 (`ModelAvailability` + `availability(_:)`)
   - §4.2 (`InFlightDownloads` actor)
   - §4.3 (tightened `isModelAvailable` + `isModelConfigPresent` escape hatch)
   - Minor bump to `0.14.0` due to the breaking semantic change in §4.3.

Mission-supervisor may choose to split further. The two-PR shape is a recommendation, not a hard constraint.

---

## 7. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Downstream callers depend on the loose `isModelAvailable` and silently regress | High | Ship §4.3 as a minor bump with a clearly-named `isModelConfigPresent` escape hatch and a CHANGELOG entry. Coordinate with the Flux2 and Vinetas teams (the only known consumers) before merging PR #2. |
| R2 doesn't honor range requests for a given object | Low (R2 is S3-compatible) | Runtime guard — if server returns `200`, discard partial bytes and consume from offset 0. Don't disable resume on that response; just don't trust the part file for this attempt. |
| Delegate-based streaming breaks `SecureDownloadSession`'s redirect rejection | Medium | Verify in tests: the redirect-blocking behavior must still be enforced via `URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`. If delegate plumbing is too invasive, fall back to the `AsyncBytes`-batching approach (§4.4 alternative). |
| Seeding the SHA-256 hasher from disk on resume is slow for multi-GB shards | Medium | Document the trade-off. A 4 GB read-and-hash on a modern SSD is ~10 s; far faster than a 4 GB redownload. If profiling shows this is a real bottleneck, a future enhancement can persist hasher state alongside the part file. Out of scope for this work. |
| `InFlightDownloads` dedup key (`modelId` not `(modelId, files)`) surprises a caller asking for a different file subset mid-flight | Low | Document explicitly in the doc comment. Add a test that asserts the joiner-with-different-files behavior. Production usage is `files: []` (everything), so the surprise window is small. |

---

## 8. Telemetry mapping

No new required events. The three-state API derives from:

| State | Derivation |
|---|---|
| `.notAvailable` | No matching `downloadOperationStart` in flight; strict size-match check fails. Observable via the absence of `cacheHit` for one or more manifest files. |
| `.downloading(progress:)` | `downloadOperationStart` observed, `downloadOperationComplete` not yet. `progress` derived from the existing `AcervoDownloadProgress.overallProgress` (already byte-accurate per the `ByteProgressTracker`). |
| `.available` | `cacheHit` for every manifest file *or* `componentDownloadComplete` for every manifest file, with no subsequent `errorThrown` of phase `.fileDownloadIntegrity` / `.fileDownloadSize`. |

Optional addition (only if it falls out naturally during §4.5 implementation):

```swift
case downloadResumed(
    modelID: String,
    fileName: String,
    resumedFromBytes: Int64
)
```

If added, route it through the same telemetry surface as the existing events; do not add a new reporter method.

---

## 9. Acceptance signals (system-level, post-merge)

The TODO's stated signals, reproduced here verbatim so the breakdown can use them as integration checkpoints:

1. **Dedup proven by test:** Two parallel calls to `Acervo.ensureAvailable("black-forest-labs/FLUX.2-klein-4B", files: [])` from a unit test only run **one** network download.
2. **Resume proven by manual smoke:** Killing Vinetas mid-shard and reopening resumes that shard's `.part` file with a `Range:` request, not from byte 0.
3. **Perf proven by `sample`:** `sample` of the running process during a download no longer shows `Data.append` and `_platform_memmove` as the dominant cost.
4. **Contract unification:** `Flux2Engine.isAvailable` and `Flux2ModelDownloader.findModelPath` no longer disagree about whether a model is usable. (Verification happens in the downstream repo — out of scope for SwiftAcervo's merge gate, but blocks the downstream cleanup PR.)
