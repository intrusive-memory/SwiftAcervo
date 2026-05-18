---
feature_name: OPERATION TICKET STUB
starting_point_commit: d725931
mission_branch: mission/ticket-stub/01
iteration: 1
---

# EXECUTION_PLAN.md — SwiftAcervo: Three-state availability + resumable, dedup'd downloads

**Source requirements:** [`REQUIREMENTS.md`](REQUIREMENTS.md)
**Companion design doc:** [`Docs/MODEL_AVAILABILITY_PATH.md`](Docs/MODEL_AVAILABILITY_PATH.md)
**Origin TODO:** [`TODO.md`](TODO.md) (item dated 2026-05-18)
**Refined:** 2026-05-18 (pass 1–4, code-walked against `Sources/SwiftAcervo/` at HEAD `d0aa8da`).
**Scope note (pass 5, 2026-05-18):** Performance work (REQUIREMENTS § 4.4, chunked streaming) is **deferred to a follow-up mission**. This pass focuses on solid API surface and reliable behavior; the per-byte `AsyncBytes`/`Data.append` cost identified in REQUIREMENTS § 3 will be addressed separately with a `URLSessionDataDelegate`-based rewrite once this mission ships. No perf assertions appear in any test in this plan.

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

Make `SwiftAcervo` the sole source of truth for model state by:

1. Exposing exactly three states to consumers — `notAvailable`, `downloading(progress:)`, `available`.
2. Making the download path resumable (`.part` files colocated with destination + HTTP Range requests).
3. Deduplicating concurrent callers via an `InFlightDownloads` actor.

**Explicitly deferred to a follow-up mission:** chunked-streaming perf fix (REQUIREMENTS § 4.4). The current per-byte `for try await byte in asyncBytes` loop stays in place this pass. A future mission will rewrite it on top of a `URLSessionDataDelegate` per-task delegate (the approach REQUIREMENTS § 4.4 sentence 1 recommends), with its own dedicated perf benchmarks. Nothing in this plan asserts on download throughput or CPU cost.

The mission is cleaved into two release-shaped halves:

- **Work Unit 1 — Resumable downloads + cleanup:** internal-only changes to the streaming downloader. No public API change. Ships as our next patch release.
- **Work Unit 2 — Three-State Availability API:** new public surface (`ModelAvailability`, `availability(_:)`, `isModelConfigPresent(_:)`) plus a backwards-incompatible tightening of `isModelAvailable` semantics. Ships as our next minor release.

Work Unit 2 depends on Work Unit 1 — the resumable `.part` files in WU1 are the on-disk substrate that lets WU2's `availability(_:)` return `.notAvailable` after a hard process kill (the `.part` file alone never satisfies the strict size check). The in-flight registry built in WU2 also benefits from observing a download path whose temp-file location is no longer a random UUID, so retries can converge on a single artifact.

---

## Component Definitions

The refinement researched each component the plan touches against the live source tree. The following are the exact contracts the sorties below must implement.

### Existing components (read these before editing)

| Component | Location | Today's behavior | Relevance |
|---|---|---|---|
| `AcervoDownloader` (struct) | `Sources/SwiftAcervo/AcervoDownloader.swift` (1241 lines, single file) | Static helpers: `buildURL`, `buildManifestURL`, `ensureDirectory`, `downloadManifest`, `streamDownloadFile` (lines 419–623), `fallbackDownloadFile` (lines 647–754), `downloadFile` (×2 overloads), `downloadFiles` (lines 946–1240). | Sorties 1, 2, 4 modify this file. Sortie 6 wraps its progress callback. |
| `streamDownloadFile` | `AcervoDownloader.swift:419–623` | Streams `URLSession.bytes(for:)`, appends each byte to a `Data` buffer (pre-sized via `buffer.reserveCapacity(streamChunkSize)` at line 489) in a `for try await byte in asyncBytes` loop (lines 514–534), flushes hasher+filehandle+progress at `streamChunkSize` boundaries (4 MiB). Writes to `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`. On any throw: `try? fm.removeItem(at: tempFileURL)` (lines 500, 548, 563, 585). After stream, verifies size + SHA, then `moveItem` to destination. Ensures the destination's parent directory exists AFTER the stream completes (line 602–604). | Sortie 1 changes the temp-file location and resume behavior; the byte-loop body is unchanged this mission. Sortie 2 deletes residual cleanup-only paths. |
| `fallbackDownloadFile` | `AcervoDownloader.swift:647–754` | Calls `session.download(for:)` (whole-file), `moveItem` to destination, then `IntegrityVerification.verifyAgainstManifest(...)`. Stays all-or-nothing. | Sortie 2 only adds a top-of-function comment explaining why this path is intentionally not resumable. |
| `downloadFiles` | `AcervoDownloader.swift:946–1240` | Fetches manifest, optionally filters by `requestedFiles`, runs up to 4 concurrent file downloads via `TaskGroup`. Per-file cache check at lines 1033–1109 uses *size-only* comparison against `manifestFile.sizeBytes`. Emits `cacheHit` / `cacheMiss(reason:)` telemetry. | Sortie 4 extracts the per-file size-match logic into a reusable helper and calls the helper from both this function and the new strict `isModelAvailable`. Sortie 4 also persists the validated manifest to disk after this function succeeds. |
| `SecureDownloadSession` | `Sources/SwiftAcervo/SecureDownloadSession.swift` (59 lines) | Singleton `URLSession`. Delegate `SecureDownloadDelegate` conforms to `URLSessionTaskDelegate` only — implements `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` and rejects redirects whose host is not the allowed CDN (`pub-8e049ed02be340cbb18f921765fd24f3.r2.dev`). | Untouched this mission. The deferred chunked-streaming sortie may add a per-task `URLSessionDataDelegate` later; this file does NOT need to be modified to support that path because per-task delegates fall through `respondsToSelector:` for callbacks they don't implement, leaving the session delegate's redirect rejection intact. |
| `IntegrityVerification` | `Sources/SwiftAcervo/IntegrityVerification.swift` (200 lines) | Static helpers: `sha256(of:)`, `verify(file:in:)`, `fileSize(at:)`, `verifyAgainstManifest(fileURL:manifestFile:telemetry:)`. The last is the only `async` one (because it emits telemetry). | Sortie 4 adds two new static methods: `allManifestFilesPresentBySize(manifest:in:)` and `partialFileSize(at:)`. |
| `Acervo.isModelAvailable(_:)` | `Acervo.swift:299–305` (public) and `Acervo.swift:1069–1074` (internal `(in:)` overload) | Public. Returns `true` iff `config.json` exists at the model root. Never throws. | Sortie 4 rewrites both overloads. Sortie 4 also adds the new escape hatch `isModelConfigPresent(_:)` that carries the OLD body verbatim. |
| `Acervo.ensureAvailable(_:files:...)` | `Acervo.swift:1098–1111` (public forwarder) and `Acervo.swift:1118–1139` (internal overload that holds the `if isModelAvailable → return; else download(...)` body) | Public forwarder + internal body. No dedup. | Sortie 6 wraps the body of the INTERNAL overload (lines 1118–1139) in an `InFlightDownloads.shared.task(for:)` call so concurrent callers converge. |
| `AcervoManager` (actor) | `Sources/SwiftAcervo/AcervoManager.swift` (693 lines) | Per-model poll-based lock (`acquireLock` polls `Task.sleep(.milliseconds(50))`). Per-model serialization for `download(_:files:force:progress:)` and `withModelAccess(_:perform:)`. **Out of scope:** the poll-loop lock is *not* replaced by `InFlightDownloads`; they serve different purposes (per-model file access serialization vs. per-model in-flight network download dedup). Both stay. | Sortie 5 adds `availability(_:)` convenience that does NOT hold the per-model lock. |
| `SharedStaticStateSuite` | `Tests/SwiftAcervoTests/Support/SharedStaticStateSuite.swift` | `.serialized` test suite grandparent. Any test that touches `MockURLProtocol`, `ComponentRegistry.shared`, or any other process-global must nest under this suite. | Sorties 1, 4, 5, 6 add tests; the new tests that touch `MockURLProtocol` or `InFlightDownloads.shared` MUST nest under `SharedStaticStateSuite.MockURLProtocolSuite`. |
| `MockURLProtocol` | `Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` | Counting-aware mock for `URLSession`. Has a `Responder` closure + a static request counter. Used by `DownloadSessionInjectionTests`, `DeleteFromCDNTests`, etc. — proven session-injection seam. | All new tests in this plan use this seam, configured per-test in the `.serialized` parent. |

### New components (the deliverables)

| Component | Location | Sortie | Public/Internal | Contract |
|---|---|---|---|---|
| `streamChunkSize` (existing constant) | `AcervoDownloader.swift:44` | (used by) 1 | private | 4_194_304 (4 MiB). Unchanged. Reused as the partial-file size unit when seeding the hasher on resume in Sortie 1. |
| `IntegrityVerification.allManifestFilesPresentBySize(manifest:in:)` | `IntegrityVerification.swift` | 4 | `static func ... -> Bool` (internal) | Returns `true` iff, for every `CDNManifestFile` in `manifest.files`, the file at `directory.appendingPathComponent(file.path)` exists with size == `file.sizeBytes`. Does NOT recompute SHA-256. Does NOT throw — any I/O glitch on a single file is treated as "missing" (returns `false` overall). Pure function with respect to its inputs and `FileManager`. |
| `IntegrityVerification.partialFileSize(at:)` | `IntegrityVerification.swift` | 1 | `static func ... -> Int64?` (internal) | Returns the size in bytes of the file at the given URL, or `nil` if the file does not exist. Distinguishes "absent" (return `nil`) from "exists with size 0" (return `0`). Does NOT throw — translates any non-ENOENT error to `nil` and logs at `.debug`. |
| Persisted manifest on disk | `{baseDirectory}/{slug}/.acervo-manifest.json` | 4 | filesystem | The validated `CDNManifest` is written here on successful `downloadFiles`. Encoded with `JSONEncoder().outputFormatting = .sortedKeys` (deterministic). Filename is dot-prefixed to avoid any conceivable collision with a manifest entry literally named `manifest.json`. The CDN-side manifest URL stays `manifest.json`; the on-disk copy is named differently on purpose. |
| `AcervoDownloader.loadCachedManifest(for:in:)` | `AcervoDownloader.swift` | 4 | `static func ... -> CDNManifest?` (internal) | Reads `{baseDirectory}/{slug}/.acervo-manifest.json`. Returns `nil` if absent, malformed, or fails its own checksum-of-checksums (does NOT throw — this is a cache loader, not an authoritative path). On checksum mismatch, deletes the corrupted file and returns `nil`. |
| `AcervoDownloader.persistManifest(_:in:)` | `AcervoDownloader.swift` | 4 | `static func ... throws` (internal) | Atomic write to `{baseDirectory}/{slug}/.acervo-manifest.json` using `Data.write(to:options: .atomic)`. Called from `downloadFiles` after the task group's `waitForAll()` succeeds AND before the `modelLoadComplete` telemetry emission. This ordering ensures we only persist a manifest whose files we have actually placed on disk. |
| `Acervo.isModelConfigPresent(_:)` | `Acervo.swift` | 4 | `public static func ... -> Bool` | Returns `true` iff `config.json` exists at the model root. Body is the OLD `isModelAvailable` body verbatim. Documented as "explicit escape hatch; does NOT imply usability." Also gets an `(in baseDirectory:)` internal overload mirroring the existing `isModelAvailable(_:in:)`. |
| `Acervo.isModelAvailable(_:)` (rewritten) | `Acervo.swift:299–305` (rewritten) | 4 | `public static func ... -> Bool` | New body: load `.acervo-manifest.json` via `AcervoDownloader.loadCachedManifest`. If `nil` → return `false`. Else return `IntegrityVerification.allManifestFilesPresentBySize(manifest:, in: modelDirectory)`. Never throws. |
| `ModelAvailability` (enum) | `Sources/SwiftAcervo/ModelAvailability.swift` (new file) | 5 | `public enum ... : Sendable, Equatable` | Three cases: `.notAvailable`, `.downloading(progress: Double)`, `.available`. The `.downloading` payload is clamped to `0.0...1.0` at construction via a custom initializer pattern (a static factory `.downloading(progress:)` is acceptable; clamping happens inside `Acervo.availability(_:)` before emission). `Equatable` synthesis works because `Double` is `Equatable`. |
| `Acervo.availability(_:)` | `Acervo.swift` | 5 (stub), 6 (final) | `public static func ... async -> ModelAvailability` | Non-throwing. Behavior: (1) ask `InFlightDownloads.shared.contains(modelId)`; if true return `.downloading(progress: InFlightDownloads.shared.progress(for: modelId) ?? 0.0)`; (2) else evaluate `isModelAvailable(modelId)`; if true return `.available`, else `.notAvailable`. Errors swallowed → `.notAvailable`. Zero network I/O. Sortie 5 ships this with the InFlightDownloads check stubbed to return `false`; Sortie 6 removes the stub. |
| `AcervoManager.availability(_:)` | `AcervoManager.swift` | 5 | `public func ... async -> ModelAvailability` | Trivial forwarder to `Acervo.availability(modelId)`. **Does NOT acquire the per-model lock** — status queries must not be serialized behind a download. |
| `InFlightDownloads` (actor) | `Sources/SwiftAcervo/InFlightDownloads.swift` (new file) | 6 | `actor` (internal — file-private to the SwiftAcervo module) | Process-wide registry of in-flight model downloads. Singleton: `static let shared = InFlightDownloads()`. Members below. |
| `InFlightDownloads.task(for:start:)` | (above) | 6 | `func ... -> Task<Void, Error>` | If an entry exists for `modelId`, returns its `Task`. Else invokes `start()` to obtain a new `Task`, registers it under `modelId`, and returns it. Concurrent callers with the same `modelId` converge on a single `Task`. |
| `InFlightDownloads.publishProgress(_:for:)` | (above) | 6 | `func ... ` | Stores the latest progress sample (clamped 0.0…1.0) for `modelId`. Called from inside the in-flight closure's wrapped progress callback. |
| `InFlightDownloads.progress(for:)` | (above) | 6 | `func ... -> Double?` | Returns latest progress sample for `modelId`, or `nil` if not in flight. |
| `InFlightDownloads.finish(_:)` | (above) | 6 | `func ... ` | Deregisters the entry. Called from a `defer` inside the in-flight closure so it fires on both success and throw. |
| `InFlightDownloads.contains(_:)` | (above) | 6 | `func ... -> Bool` | Membership probe. |
| `InFlightDownloads.reset()` | (above) | 6 | `internal func ... ` | Test-only seam. Empties the registry. Documented as such; not called from production code. |

### Chunked-streaming sortie: deferred

The original plan opened with a "Sortie 1 — Chunked streaming download" focused on REQUIREMENTS § 4.4. That sortie is **deferred to a follow-up mission**.

**Why deferred (and why a refactor here would not be a real fix):**

The current code already calls `buffer.reserveCapacity(streamChunkSize)` at `AcervoDownloader.swift:489` before the byte loop, so the byte-by-byte `buffer.append(byte)` never triggers geometric growth — `_platform_memmove` is hit *per byte* by `Data._Representation.replaceSubrange`, not on growth. The dominant cost identified in REQUIREMENTS § 3 (`Data.append → replaceSubrange → memmove`, plus `AsyncIteratorProtocol.next(isolation:)`) is per-byte regardless of capacity. Any AsyncBytes-batching wrapper that still iterates the underlying `URLSession.AsyncBytes` one byte at a time inherits both costs and would not move the needle on the Vinetas symptom. The fix that actually addresses § 3 needs a `URLSessionDataDelegate`-based path (where the URL Loading System hands us pre-sized `Data` chunks), and that work belongs in its own mission with its own perf bench. This mission ships resumability + API surface only; perf claims and perf assertions are explicitly absent.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| WU1 — Resumable downloads + cleanup | `Sources/SwiftAcervo/` + `Tests/SwiftAcervoTests/` | 3 | 1 | none |
| WU2 — Three-State Availability API | `Sources/SwiftAcervo/` + `Tests/SwiftAcervoTests/` | 4 | 2 | WU1 |

---

## Parallelism Structure

**Critical path:** Sortie 1 → 2 → 3 → 4 → 5 → 6 → 7 (length: 7 sorties).

**Parallel execution groups:** None. Every sortie modifies code or state that the next sortie depends on:
- WU1 sorties chain: resumable `.part` (1) → cleanup-path deletion (2) → version/CHANGELOG (3).
- WU2 sorties chain: strict-availability helper + manifest persistence (4) → `ModelAvailability` + `availability(_:)` (5, with stub) → `InFlightDownloads` (6, removes the stub) → version/CHANGELOG/API docs (7).

**Sub-agent allocation:** zero. The supervising agent runs every sortie because every sortie includes a `make test` step (build is restricted to the supervising agent).

**Missed opportunities considered and rejected:**
- "Could Sortie 5's `ModelAvailability` enum be written in parallel with Sortie 4?" → No. Sortie 5's test cases depend on Sortie 4's strict `isModelAvailable` returning the right answer; otherwise the `.available` test case would still pass with the old loose semantics and we'd ship without confirming the contract change.
- "Could Sorties 3 and 7 (docs) run in parallel with their predecessors?" → No. They depend on the predecessor's final state and CHANGELOG entries name the changes the predecessor made.

---

## Open Questions & Resolutions

Pass 4 (and 5) surfaced the following ambiguities. All are resolved in this refinement and locked in as decisions:

| Item | Original ambiguity | Resolution |
|---|---|---|
| Chunked streaming (perf fix) | Original plan added a Sortie 1 to swap byte-loop for AsyncBytes batching; pass-5 review of the live source found the proposed code is functionally equivalent to the existing byte loop (capacity is already reserved at line 489; per-byte `Data.append → replaceSubrange → memmove` cost survives any wrapper that still iterates AsyncBytes). | **Deferred.** REQUIREMENTS § 4.4 is out of scope for this mission. The real fix (a per-task `URLSessionDataDelegate` that emits sized `Data` chunks via `urlSession(_:dataTask:didReceive:)`) ships in a dedicated follow-up mission with its own perf bench. No perf assertions appear in any test in this plan. |
| Hasher seeding on resume | Plan said "seed by streaming the existing part-file bytes through it." | **Confirmed acceptable.** REQUIREMENTS § 7 documents the trade-off (~10 s for 4 GB on SSD). Add a doc-comment on `streamDownloadFile` calling this out so future readers don't assume hasher state is persisted. |
| Subdirectory part-file parent dir creation | Current code creates the destination's parent directory AFTER the stream completes (line 602–604). With `.part` files in the destination directory, the parent must exist BEFORE opening the part file. | **Fix in Sortie 1:** move the `ensureDirectory(at: parentDirectory)` call to the top of `streamDownloadFile`, before the part-file URL is constructed and the file handle is opened. |
| `fallbackDownloadFile` resumability | Plan said "either give it `.part` semantics OR add a comment." | **Locked: keep it all-or-nothing.** Rationale (Sortie 2 task #3): the fallback path is invoked only when streaming itself has thrown a non-`AcervoError`. Resuming via the fallback would (a) require duplicating Sortie 1's range logic, (b) complicate the "clean fallback to retry from scratch" property, and (c) provide no robustness benefit since the fallback's `URLSession.download(for:)` writes to session-managed temp anyway. Add a single-paragraph top-of-function comment locking this in. |
| Manifest persistence path | Plan said `{slug}/manifest.json`. | **Changed: persist to `.acervo-manifest.json` (dot-prefixed).** The CDN manifest itself can legally contain a file named `manifest.json` in its `files` array — the validator (`CDNManifestFile.validatedRelativePath`) only rejects `..` and empty components. A dot-prefixed local name removes any possible collision. The CDN URL (`{slug}/manifest.json`) is unchanged; the disk-cache name is a SwiftAcervo internal detail. |
| `InFlightDownloads` test isolation | Plan did not address it. | **Add `reset()` test seam + nest tests under `SharedStaticStateSuite.MockURLProtocolSuite`.** The new dedup tests use `MockURLProtocol` AND the actor registry — both are process-global. The `.serialized` grandparent suite is the existing pattern (see `Tests/SwiftAcervoTests/Support/SharedStaticStateSuite.swift`). |
| Sortie 5 stub for `InFlightDownloads.contains` | Plan said "stub so that it always returns false." | **Specific stub placement:** in `Acervo.availability(_:)`, write `// TODO(Sortie 6): query InFlightDownloads.shared.contains(modelId)` immediately before the on-disk check, and add a `let inFlight = false` local. Sortie 6's first task replaces both lines with the real call. |
| Dedup key choice | Plan said `modelId`, not `(modelId, FileSet)`. | **Confirmed.** Production callers pass `files: []` (everything); a joiner with a different file subset rides on the originator's set. Document this in `ensureAvailable`'s doc comment as a known trade-off. Sortie 6 adds an explicit test that asserts this behavior so a future change cannot quietly regress it. |
| `ensureAvailable` body location | Plan originally cited `Acervo.swift:1098–1139`. | **Corrected.** Lines 1098–1111 are the public forwarder; the `if isModelAvailable → return; else download(...)` body lives in the internal overload at lines 1118–1139. Sortie 6 modifies the internal overload. The public forwarder remains a forwarder. |
| Version numbers in plan | User instruction: "NEVER specify concrete version numbers; use relative language." | **Compliance:** every reference below uses "our next patch release version" / "our next minor release version." The release-time `ship-swift-library` flow resolves these from the highest published tag. |

---

# Work Unit 1 — Resumable downloads + cleanup

**Goal:** Make downloads resumable via `.part` files colocated with destination, and remove the cleanup-only paths that exist only because today's downloads are all-or-nothing. No public API change. Streaming shape (`bytes(for:)` + byte loop) is intentionally **unchanged** — REQUIREMENTS § 4.4 is deferred to a follow-up mission.

**Releases as:** our next patch release version.

**Priority justification:** depth-2 dependency (blocks every WU2 sortie), foundation score 1 (establishes the resumable-download substrate that `availability(_:)` reasons over after process kills), risk 3 (file I/O + HTTP Range + hasher reseed correctness), complexity moderate. Composite priority: high — execute first.

---

### Sortie 1: Resumable downloads via `.part` files

**Priority:** 11 — depth-2 dependency (blocks Sortie 2 and indirectly WU2's "hard process kill returns notAvailable" semantics), foundation score 1, risk 3 (HTTP Range correctness + hasher reseed correctness + cross-volume `moveItem` correctness — multiple ways to be subtly wrong), complexity high. First sortie in WU1.

**Entry criteria**:
- [ ] First sortie — no prerequisites.
- [ ] Working tree is clean on the mission branch.
- [ ] `make test` baseline passes (recorded so any post-sortie regression is unambiguous).

**Files in scope**:
- `Sources/SwiftAcervo/AcervoDownloader.swift` — modify `streamDownloadFile`. Do NOT touch `fallbackDownloadFile`.
- `Sources/SwiftAcervo/IntegrityVerification.swift` — add `partialFileSize(at:)` helper.
- `Tests/SwiftAcervoTests/ResumableDownloadTests.swift` — new file.

**Tasks**:
1. **Add `IntegrityVerification.partialFileSize(at:) -> Int64?`** — see § Component Definitions for the contract. Implementation: wrap `fileSize(at:)` in a `try?` and check `FileManager.default.fileExists(atPath:)` to distinguish absent from "exists with size 0."
2. **Replace the UUID temp-file URL** (`AcervoDownloader.swift:483–484`):
   ```swift
   let tempFileURL = FileManager.default.temporaryDirectory
       .appendingPathComponent(UUID().uuidString)
   ```
   with:
   ```swift
   let partURL = destination.appendingPathExtension("part")
   ```
   The part file now lives in the destination's directory — same volume — so the final `moveItem` is guaranteed to be a rename, not a cross-volume copy. (This also fixes a hidden perf regression: the App Group container and `FileManager.temporaryDirectory` are typically on different volumes, so today's `moveItem` already degrades to copy for every download.)
3. **Move the parent-directory creation** (`try ensureDirectory(at: parentDirectory, telemetry: telemetry)`) from its current position (after the stream completes, line 602–604) to the TOP of `streamDownloadFile`, BEFORE the part-file URL is constructed and the file handle is opened. Subdirectory files like `speech_tokenizer/config.json` require this ordering or `FileHandle(forWritingTo:)` will throw.
4. **Classify the part file's pre-stream state** and branch on it. Use `IntegrityVerification.partialFileSize(at: partURL)`:
   - `nil` (absent) → write from offset 0. No `Range` header. Open file handle for writing (creating the file if needed).
   - `0 < partSize < manifestFile.sizeBytes` (genuine partial) → set `request.setValue("bytes=\(partSize)-", forHTTPHeaderField: "Range")`. Open file handle for writing AND seek to `partSize` (use `FileHandle.seekToEnd()` after opening for writing in append mode, or open in `r+` mode and `seek(toOffset: partSize)`). **Seed the SHA-256 hasher** by reading the existing partial bytes from `partURL` through the same `IntegrityVerification.chunkSize`-sized chunks and calling `hasher.update(data:)` for each. Set `bytesWritten = partSize`.
   - `partSize == manifestFile.sizeBytes` (already-complete part file) → SKIP the network call entirely. Compute SHA-256 of the part file directly (`IntegrityVerification.sha256(of: partURL)`). If it matches `manifestFile.sha256`, atomic-rename to destination and return success. If not, delete the part file and recursively retry the function (or set the URL to "absent" state and fall through — simpler).
   - `partSize > manifestFile.sizeBytes` (oversized — corrupt or stale manifest size) → delete the part file and start fresh from offset 0.
5. **Handle server-ignored Range responses.** After the stream begins, inspect the HTTP response status:
   - `206 Partial Content` → trust the partial bytes already on disk; the body stream resumes at `partSize`.
   - `200 OK` and we sent a `Range` header → the server ignored the range. The body is the full file from offset 0. Reset the hasher (`hasher = SHA256()`), truncate the part file (`fileHandle.truncate(atOffset: 0)`), and continue reading the body as if from a fresh start. Do NOT mutate any global "disable resume" flag — this is a per-attempt fallback.
   - Other status codes → same handling as today (throw `AcervoError.downloadFailed`).
6. **Change the failure-path cleanup policy.** Today there are four `try? fm.removeItem(at: tempFileURL)` calls (lines 500, 548, 563, 585) that delete the temp file on every throwable. Now, *keep* the part file across transient failures:
   - On `FileHandle(forWritingTo:)` failure (line 500 region) → keep the part file (it's intact and partial); just throw.
   - On stream-interrupted / write-failed (line 548 region) → keep the part file. Throw.
   - On size mismatch (line 563 region) → DELETE the part file (this is validated corruption). Throw.
   - On SHA mismatch (line 585 region) → DELETE the part file (validated corruption). Throw.
   - On oversize observed pre-stream (task #4 case) → DELETE before starting.
7. **Create `Tests/SwiftAcervoTests/ResumableDownloadTests.swift`** nested under `SharedStaticStateSuite.MockURLProtocolSuite`. Five tests, each driving `AcervoDownloader.downloadFile(...)` against `MockURLProtocol.session()`:
   1. **`partial_resumeViaRangeHeader`**: Pre-populate `destination.appendingPathExtension("part")` with the first half of a synthetic 16 MiB body (so `partSize == 8 MiB`). Configure responder: assert the incoming request carries `Range: bytes=8388608-`, respond with the second-half bytes at status 206. Assert the final file at `destination` has the full 16 MiB and a matching SHA.
   2. **`partial_serverIgnoresRangeReturns200`**: Pre-populate `.part` to 8 MiB. Responder ignores the `Range` header and returns the full 16 MiB at status 200. Assert the final file is byte-identical to the synthetic body and SHA matches. (Verifies the truncate-and-restart path in task #5.)
   3. **`partial_oversizedTriggersFullRedownload`**: Pre-populate `.part` to 32 MiB of garbage (manifest says 16 MiB). Responder returns the full 16 MiB at status 200 with NO `Range` header on the request. Assert request count == 1 (no abortive request), final file matches manifest SHA, original 32 MiB garbage no longer exists.
   4. **`complete_correctHashSkipsNetwork`**: Pre-populate `.part` with the EXACT 16 MiB body whose SHA matches the manifest. Assert `MockURLProtocol.requestCount == 0` after `downloadFile`. Final file exists at `destination` (atomic-renamed from `.part`).
   5. **`complete_wrongHashDeletesAndRedownloads`**: Pre-populate `.part` with 16 MiB of garbage (size matches manifest, SHA does not). Responder returns the correct 16 MiB at status 200. Assert request count == 1, final SHA matches, garbage part file no longer exists.
8. Run `make test`. All existing tests must still pass; new tests pass.

**Exit criteria**:
- [ ] `make test` returns 0.
- [ ] `Tests/SwiftAcervoTests/ResumableDownloadTests.swift` exists with all 5 tests passing.
- [ ] `grep -n "UUID().uuidString" Sources/SwiftAcervo/AcervoDownloader.swift` shows zero hits within the `streamDownloadFile` function. (One or more hits inside `fallbackDownloadFile`'s session-managed download path are acceptable — that function is untouched in this sortie and stays unchanged in Sortie 2 except for a comment.)
- [ ] `grep -n "temporaryDirectory" Sources/SwiftAcervo/AcervoDownloader.swift` shows zero hits inside `streamDownloadFile`.
- [ ] `IntegrityVerification.partialFileSize(at:)` exists and is called from `streamDownloadFile`.
- [ ] The test `complete_correctHashSkipsNetwork` proves request count == 0.
- [ ] Subdirectory test exists: at least one of the 5 tests above uses a manifest path with a `/` (e.g., `speech_tokenizer/config.json`) to exercise the parent-directory-creation move in task #3. (If none of the 5 above naturally do, add a 6th.)
- [ ] All pre-existing tests still pass, especially: `MultiFileRollbackTests` (relies on cleanup behavior), `StreamAndHashTests`, `ConcurrentDownloadTests`.

---

### Sortie 2: Delete cleanup-only paths + document fallback

**Priority:** 6 — depth-1 dependency (blocks Sortie 3), foundation score 0, risk 1 (delete-only sortie; no new code paths), complexity low.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all green (resumable downloads merged).
- [ ] Working tree clean.

**Files in scope**:
- `Sources/SwiftAcervo/AcervoDownloader.swift` — delete dead paths in `streamDownloadFile`; add a single doc comment to `fallbackDownloadFile`.

**Tasks**:
1. **Audit `streamDownloadFile` for residual cleanup-only branches.** After Sortie 1, the function's failure paths should already follow the policy: delete part file ONLY on validated corruption (oversize, SHA mismatch, size mismatch). Any remaining `try? fm.removeItem(at: ...)` calls inside `streamDownloadFile` that exist only to clean up the legacy UUID temp file must be deleted. Specifically: any `try? fm.removeItem(at: partURL)` that fires on transient/non-corruption throws (network error, write error, stream interrupted) must be deleted.
2. **Remove any `.fileExists` branches inside `streamDownloadFile`** that became unreachable after the part-file migration. The function should no longer reference `FileManager.default.temporaryDirectory` anywhere.
3. **Add a top-of-function doc comment to `fallbackDownloadFile`** (around line 647) explaining why it stays all-or-nothing (locked in by Pass 4 resolution above):
   ```swift
   /// Legacy whole-file fallback. Invoked only when `streamDownloadFile` throws a
   /// non-`AcervoError` (transport error, etc.). This path intentionally does NOT
   /// implement `.part`-based resume: it is the second-chance retry for a stream that
   /// has already failed. Restarting the whole file is acceptable here because
   /// (a) reaching this path is already an exceptional case, (b) `URLSession.download(for:)`
   /// writes to session-managed temp anyway and is rename-only on the final hop,
   /// (c) adding resume here would duplicate `streamDownloadFile`'s range-classification
   /// logic for negligible benefit.
   ```
4. **Do NOT bump the version yet** — that is Sortie 3's job.
5. Run `make test`. All existing tests must still pass. No new tests added in this sortie (it's a delete-and-document sortie).

**Exit criteria**:
- [ ] `make test` returns 0.
- [ ] `grep -n "temporaryDirectory" Sources/SwiftAcervo/AcervoDownloader.swift` shows zero hits inside `streamDownloadFile` (hits inside `fallbackDownloadFile` are expected and acceptable).
- [ ] `grep -B2 -A8 "func fallbackDownloadFile" Sources/SwiftAcervo/AcervoDownloader.swift` shows the new explanatory doc comment.
- [ ] No test file was deleted to make this sortie pass. (`git diff --stat Tests/` reports zero deletions.)
- [ ] No new code paths were introduced — the diff is overwhelmingly deletions plus one comment block.

---

### Sortie 3: Version + CHANGELOG for WU1

**Priority:** 2 — leaf sortie. No code changes that affect behavior. Tiny scope.

**Entry criteria**:
- [ ] Sortie 2 exit criteria all green.
- [ ] All WU1 tests pass on a clean run (`make test` from a clean checkout, not the incremental cache).

**Files in scope**:
- `Sources/acervo/Version.swift` — currently `let acervoVersion = "0.13.1-dev"`.
- `CLAUDE.md` — the `**Version**:` line in Quick Reference (currently `0.13.1`).
- `CHANGELOG.md` — the `## [Unreleased]` section is currently empty.

**Tasks**:
1. Update `Sources/acervo/Version.swift` to our next patch release version (drop the `-dev` suffix; bump the patch number by one from the latest published tag).
2. Update the `**Version**:` line in `CLAUDE.md` Quick Reference to match.
3. Add a `CHANGELOG.md` entry under our next patch release version with today's date, following the Keep a Changelog format already in use. Required sections and bullets:
   - **Changed**:
     - Resumable downloads via `.part` files. Temp files now live at `{destination}.part` (same volume as the final file) and survive transient failures. On retry, downloads send `Range: bytes=<partial-size>-`; if the server responds 200 instead of 206, the partial bytes are discarded and the full body is consumed. The cross-volume `moveItem` (App Group container vs system temp directory) is incidentally avoided since the part file is co-located with the destination. (See `REQUIREMENTS.md` § 4.5.)
     - Removed cleanup-only paths in `streamDownloadFile` that deleted partial bytes on every transient failure. Part files are now deleted only on validated corruption (oversize, SHA mismatch, size mismatch) or successful completion. (See `REQUIREMENTS.md` § 4.6.)
   - **Internal**:
     - Added `IntegrityVerification.partialFileSize(at:)`.
   - **Not included (deferred to a follow-up release):**
     - Chunked streaming (REQUIREMENTS § 4.4). The per-byte `for try await byte in asyncBytes` loop is unchanged. A dedicated mission with its own perf bench will ship the `URLSessionDataDelegate`-based rewrite. Do not advertise chunking as a change in this release.
4. Do NOT tag a release — tagging is handled by `ship-swift-library` post-merge.
5. Run `make test` once more to confirm the version bump didn't break anything (it shouldn't, but the bump is a `String` literal so a typo is possible).

**Exit criteria**:
- [ ] `Sources/acervo/Version.swift` reflects the next patch release version (no `-dev` suffix).
- [ ] `CLAUDE.md` Quick Reference `**Version**:` line matches.
- [ ] `CHANGELOG.md` has a dated entry under the next patch release version covering the three changes listed above.
- [ ] `make test` returns 0.
- [ ] No `git tag` was created (verify via `git tag --list "v*" | wc -l` matches the pre-sortie count).

---

# Work Unit 2 — Three-State Availability API

**Goal:** Add the `ModelAvailability` enum and `availability(_:)` static API, build the `InFlightDownloads` actor for concurrent-caller dedup, persist manifests to disk so the strict availability check can run without network, and tighten `isModelAvailable` to actually mean "usable." Adds one new escape-hatch method (`isModelConfigPresent`) for the legacy loose-check use case.

**Releases as:** our next minor release version (semver-breaking semantic change in `isModelAvailable`).

**Depends on:** WU1 (the in-flight registry observes a stabilized download path, and `availability(_:)` returning `.notAvailable` after a hard process kill relies on the strict size check failing on a lone `.part` file).

**Priority justification:** depth-2 dependency, foundation score 2 (establishes the public availability surface that downstream consumers — SwiftVinetas, flux-2-swift-mlx — will rebuild on top of), risk 3 (breaking semantic change in a public API), complexity high.

---

### Sortie 4: Strict-availability helper + manifest persistence + `isModelConfigPresent` + test migration

**Priority:** 12 — highest in WU2. Establishes the substrate for Sorties 5 and 6. Carries the breaking-semantic change.

**Entry criteria**:
- [ ] WU1 fully complete (Sorties 1–3 all green).
- [ ] All WU1 tests pass on a clean run.
- [ ] Working tree clean.

**Files in scope**:
- `Sources/SwiftAcervo/IntegrityVerification.swift` — add `allManifestFilesPresentBySize(manifest:in:)`.
- `Sources/SwiftAcervo/AcervoDownloader.swift` — add `persistManifest(_:in:)`, `loadCachedManifest(for:in:)`; call `persistManifest` from `downloadFiles` after `waitForAll()` and before the `modelLoadComplete` telemetry; refactor the per-file size-match cache check (lines 1033–1109) to call `allManifestFilesPresentBySize` (the body becomes a per-file invocation of the same predicate, preserving per-file `cacheHit`/`cacheMiss` telemetry).
- `Sources/SwiftAcervo/Acervo.swift` — rewrite `isModelAvailable(_:)` body; add `isModelConfigPresent(_:)` and its `(in:)` overload.
- `Tests/SwiftAcervoTests/AcervoAvailabilityTests.swift` — extend with the four new test cases listed in task #7 below.
- All other test files that reference `isModelAvailable` — migrate as listed in task #8 below.

**Tasks (organized into 3 phases for execution clarity within the single sortie)**:

**Phase A — Additive infrastructure (no semantic change yet)**:

1. **Add `IntegrityVerification.allManifestFilesPresentBySize(manifest:in:) -> Bool`.** Implementation iterates `manifest.files`; for each, compose `directory.appendingPathComponent(file.path)` and check `partialFileSize(at: ...) == file.sizeBytes`. Short-circuits on first miss. No telemetry emitted (this is a pure predicate).
2. **Add `AcervoDownloader.persistManifest(_ manifest: CDNManifest, in baseDirectory: URL) throws`.** Resolves `{baseDirectory}/{slug}/.acervo-manifest.json`. Encodes with `JSONEncoder()` (set `outputFormatting = [.sortedKeys]` for determinism). Atomic write via `try data.write(to: url, options: [.atomic])`. Throws on encoding or write failure.
3. **Add `AcervoDownloader.loadCachedManifest(for modelId: String, in baseDirectory: URL) -> CDNManifest?`.** Reads the file via `try? Data(contentsOf:)`. Decodes via `try? JSONDecoder().decode(CDNManifest.self, from:)`. Verifies the manifest's own checksum-of-checksums by calling `manifest.verifyIntegrity()` (or equivalent — see how `downloadManifest` does it on line 357 of AcervoDownloader). If any step fails, returns `nil` and (best-effort) `try? FileManager.default.removeItem(at: url)` to evict the corrupted cache. Never throws.
4. **Wire `persistManifest` into `downloadFiles`.** Insert the call AFTER `try await group.waitForAll()` (line 1209) and BEFORE the `modelLoadComplete` telemetry emission (line 1229). If `persistManifest` throws, do NOT throw out of `downloadFiles` — log at `.warning` via the existing `logger` and continue. The manifest cache is a best-effort optimization; a failure to write it should not surface as a user-visible download error.

**Phase B — Public API semantic change**:

5. **Refactor the in-`downloadFiles` cache check (lines 1033–1109) to call `allManifestFilesPresentBySize`** — or, more precisely, to use the SAME per-file predicate that `allManifestFilesPresentBySize` aggregates. The cleanest refactor: extract the per-file `existingSize == manifestFile.sizeBytes` check into an `IntegrityVerification.fileMatchesManifestEntry(_:in:)` (internal). Call it from both:
   - The per-file branch in `downloadFiles` (so `cacheHit`/`cacheMiss(.sizeChangedRemote)` telemetry continues to fire per-file as today).
   - `allManifestFilesPresentBySize` (used by `isModelAvailable` — no telemetry, pure predicate).
   This preserves today's telemetry exactly while ensuring `isModelAvailable` and `downloadFiles` agree on the predicate. (Alternative: leave the per-file branch alone and have `allManifestFilesPresentBySize` duplicate the size-check inline. Acceptable but slightly more brittle.)
6. **Rewrite `Acervo.isModelAvailable(_:)`** (currently `Acervo.swift:299–305`) to:
   ```swift
   public static func isModelAvailable(_ modelId: String) -> Bool {
       isModelAvailable(modelId, in: sharedModelsDirectory)
   }
   static func isModelAvailable(_ modelId: String, in baseDirectory: URL) -> Bool {
       guard let manifest = AcervoDownloader.loadCachedManifest(for: modelId, in: baseDirectory) else {
           return false
       }
       let modelDir = baseDirectory.appendingPathComponent(slugify(modelId))
       return IntegrityVerification.allManifestFilesPresentBySize(manifest: manifest, in: modelDir)
   }
   ```
   Replace the existing internal overload (`Acervo.swift:1069–1074`) with the new body. Update doc comments to reflect the new contract (call out that absence of a cached manifest yields `false`).
7. **Add `Acervo.isModelConfigPresent(_:)`** in the same `// MARK: - Availability` extension. The body is the OLD `isModelAvailable` body verbatim (check `config.json` exists at the model root). Add an `(in baseDirectory:)` internal overload mirroring today's `isModelAvailable(_:in:)`. Doc comment must include this warning: "Does NOT imply 'model is usable.' Prefer `availability(_:)` or `isModelAvailable(_:)` for production use. This method exists as an explicit escape hatch for callers that genuinely only want to probe for `config.json`."

**Phase C — Tests**:

8. **Update `Tests/SwiftAcervoTests/AcervoAvailabilityTests.swift`.** The file currently has 4 `isModelAvailable` tests that all assume the loose `config.json` semantics. Migrate them and add new ones. Final test list:
   - `isModelAvailable_returnsFalse_whenNoManifestCached` — directory with `config.json` only → `false`. Replaces the existing "returns true when config.json is present" test.
   - `isModelAvailable_returnsTrue_whenManifestCachedAndAllFilesSizeMatch` — write a small synthetic manifest to `.acervo-manifest.json`, write each file at the recorded size, assert `true`.
   - `isModelAvailable_returnsFalse_whenShardSizeMismatched` — same setup as above, but one file is truncated → `false`.
   - `isModelAvailable_returnsFalse_whenManifestFileMissing` — manifest cached, one file simply not present on disk → `false`.
   - `isModelAvailable_returnsFalse_whenManifestAbsent` — even with `config.json` and all data files present, no `.acervo-manifest.json` → `false`.
   - `isModelConfigPresent_returnsTrue_whenConfigJsonExists` — directory with `config.json` only → `true`. (This is the test that used to live for `isModelAvailable`; the assertion has moved to the new method.)
   - `isModelConfigPresent_returnsFalse_whenConfigJsonMissing` — empty directory → `false`.
   - `isModelConfigPresent_returnsFalse_forInvalidModelId` — `"no-slash"` → `false`.
   Keep the existing `modelFileExists` tests unchanged.
9. **Migrate dependent tests.** `grep -rn "isModelAvailable" Tests/` shows 11+ call sites. For each, decide:
   - If the test is asserting "config.json exists" semantics (i.e., it does NOT write a manifest and full file set), migrate the call to `Acervo.isModelConfigPresent(...)`. Likely candidates: tests that synthesize a model directory by writing only `config.json` — e.g., `IntegrationTests.swift` lines 150, 160, 188, 387; `ComponentIntegrationTests.swift` lines 351, 358.
   - If the test is asserting "model fully downloaded and usable" (i.e., it DOES write the full file set and a manifest), keep the `isModelAvailable` call but ensure the test now also writes `.acervo-manifest.json` to satisfy the new contract. Likely candidates: `ModelDownloadManagerTests.swift` post-download assertions, `MultiFileRollbackTests.swift` post-success assertions, `AcervoDownloadAPITests.swift` line 281.
   - Borderline cases (`MultiFileRollbackTests` post-failure asserting `false`): the new contract makes this stronger — after a failed partial download, the manifest is NOT persisted (Phase A task #4 puts the persist after `waitForAll()` succeeds), so `isModelAvailable` correctly returns `false` without further change. Leave as-is and verify in the test run.

   Make the migration explicit: produce a short summary in the sortie's report listing each migrated call site and its disposition.
10. Run `make test`. Every test passes.

**Exit criteria**:
- [ ] `make test` returns 0.
- [ ] `IntegrityVerification.allManifestFilesPresentBySize(manifest:in:)` exists.
- [ ] `IntegrityVerification.fileMatchesManifestEntry(_:in:)` (or equivalent shared predicate) exists and is called from both `downloadFiles`'s per-file branch and from `allManifestFilesPresentBySize`. Verify via `grep -n "fileMatchesManifestEntry\|allManifestFilesPresentBySize" Sources/SwiftAcervo/`.
- [ ] `AcervoDownloader.persistManifest(_:in:)` and `loadCachedManifest(for:in:)` exist.
- [ ] `Acervo.isModelConfigPresent(_:)` exists with the documented warning in its doc comment. Verify via `grep -A5 "isModelConfigPresent" Sources/SwiftAcervo/Acervo.swift`.
- [ ] After a successful `downloadFiles` call against `MockURLProtocol`, `.acervo-manifest.json` is on disk at `{baseDirectory}/{slug}/.acervo-manifest.json` and decodes to a `CDNManifest` whose `manifestChecksum` self-validates. (Add at least one test in `AcervoAvailabilityTests.swift` or a new fixture file that proves this.)
- [ ] `AcervoAvailabilityTests.swift` contains at least the 8 tests listed in task #8 and all pass.
- [ ] Test migration summary produced — every pre-existing call to `isModelAvailable` in the test suite has been audited and either migrated to `isModelConfigPresent`, updated to satisfy the new contract, or confirmed to still hold under the new semantics. The summary names each file:line touched.
- [ ] No test still passes by accident under the old loose semantics: pick any test that currently asserts `isModelAvailable == true` after writing only `config.json`. After migration, either the assertion has flipped to `isModelConfigPresent` or the test now writes a manifest and full file set.

---

### Sortie 5: `ModelAvailability` + `Acervo.availability(_:)` (with InFlightDownloads stub)

**Priority:** 9 — depth-1 dependency (Sortie 6 removes the stub it ships).

**Entry criteria**:
- [ ] Sortie 4 exit criteria all green.
- [ ] Working tree clean.

**Files in scope**:
- `Sources/SwiftAcervo/ModelAvailability.swift` — new file.
- `Sources/SwiftAcervo/Acervo.swift` — add `availability(_:)` static and its `(in:)` overload in a new `// MARK: - Availability (three-state)` extension.
- `Sources/SwiftAcervo/AcervoManager.swift` — add `availability(_:)` convenience.
- `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift` — new file.

**Tasks**:
1. **Create `Sources/SwiftAcervo/ModelAvailability.swift`:**
   ```swift
   import Foundation

   /// The three states a model can be in from a consumer's point of view.
   ///
   /// Returned by `Acervo.availability(_:)` and `AcervoManager.availability(_:)`.
   /// This is the canonical "is the model usable right now?" surface; prefer
   /// it over `Acervo.isModelAvailable(_:)` (which returns the strict-on-disk
   /// `Bool` view and does not distinguish "downloading" from "absent").
   public enum ModelAvailability: Sendable, Equatable {
       /// The model is not on disk, or its on-disk file set does not match the
       /// cached manifest (size-only check; SHA-verifying variants are out of
       /// scope and tracked separately).
       case notAvailable
       /// A download is currently in flight in this process. The associated
       /// `progress` value is in `0.0...1.0`, clamped at construction.
       case downloading(progress: Double)
       /// All manifest files are on disk at their recorded sizes.
       case available
   }
   ```
2. **Add to `Acervo.swift` a new extension `// MARK: - Availability (three-state)`:**
   ```swift
   extension Acervo {
       public static func availability(_ modelId: String) async -> ModelAvailability {
           await availability(modelId, in: sharedModelsDirectory)
       }
       static func availability(_ modelId: String, in baseDirectory: URL) async -> ModelAvailability {
           // TODO(Sortie 6): replace stub with InFlightDownloads.shared.contains(modelId)
           let inFlight = false
           if inFlight {
               // TODO(Sortie 6): read InFlightDownloads.shared.progress(for: modelId) ?? 0.0
               return .downloading(progress: 0.0)
           }
           let strict = isModelAvailable(modelId, in: baseDirectory)
           return strict ? .available : .notAvailable
       }
   }
   ```
   The function is `async` even though Sortie 5's body is synchronous, because Sortie 6 will need the actor `await` on `InFlightDownloads.shared.contains(...)`. Declaring it `async` from the start avoids a signature change between sorties.
3. **Add to `AcervoManager.swift` in a new `// MARK: - Availability (three-state)` extension:**
   ```swift
   extension AcervoManager {
       public func availability(_ modelId: String) async -> ModelAvailability {
           // Intentionally does NOT acquire the per-model lock: status queries
           // must not serialize behind an in-flight download.
           await Acervo.availability(modelId)
       }
   }
   ```
4. **Create `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift`** nested under `SharedStaticStateSuite.MockURLProtocolSuite`. Initial tests (Sortie 6 will extend with dedup and downloading-state tests):
   - `availability_returnsNotAvailable_fromEmptyDirectory` — empty model dir → `.notAvailable`.
   - `availability_returnsAvailable_fromFullMirror` — synthetic manifest + matching files on disk → `.available`.
   - `availability_returnsNotAvailable_whenShardSizeMismatched` — synthetic manifest, one file truncated → `.notAvailable`.
   - `availability_returnsNotAvailable_whenManifestAbsent` — files on disk at correct sizes but no `.acervo-manifest.json` → `.notAvailable`.
   - `availability_performsZeroNetworkIO` — assert `MockURLProtocol.requestCount == 0` after an `availability(_:)` call, regardless of return value.
   - `acervoManager_availability_forwardsToStatic` — verify `AcervoManager.shared.availability(_:)` returns the same value as `Acervo.availability(_:)` for at least one fixture. Use a fresh `AcervoManager` instance if possible to avoid singleton state interference; otherwise nest under the serialized suite.
5. Run `make test`.

**Exit criteria**:
- [ ] `make test` returns 0.
- [ ] `Sources/SwiftAcervo/ModelAvailability.swift` exists and the type compiles as `public, Sendable, Equatable`.
- [ ] `Acervo.availability(_:)` is callable; exercised by ≥ 5 test cases.
- [ ] `AcervoManager.availability(_:)` is callable; exercised by ≥ 1 test case.
- [ ] `availability(_:)` is observed (via `MockURLProtocol.requestCount`) to perform zero network I/O. At least one test asserts this explicitly.
- [ ] Sortie 6 stubs are clearly marked: `grep -n "TODO(Sortie 6)" Sources/SwiftAcervo/Acervo.swift` returns exactly 2 hits (one for `contains`, one for `progress`). Sortie 6 will assert this drops to 0.

---

### Sortie 6: `InFlightDownloads` actor + dedup in `ensureAvailable`

**Priority:** 11 — depth-1 dependency (blocks Sortie 7), foundation score 1 (the dedup substrate that downstream consumers will rely on), risk 3 (concurrency correctness: shared task convergence, progress publication ordering, registry cleanup on throw, test isolation), complexity high.

**Entry criteria**:
- [ ] Sortie 5 exit criteria all green.
- [ ] Working tree clean.

**Files in scope**:
- `Sources/SwiftAcervo/InFlightDownloads.swift` — new file.
- `Sources/SwiftAcervo/Acervo.swift` — wire dedup into `ensureAvailable`; remove the Sortie 5 stub in `availability`.
- `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift` — extend with dedup + downloading-state tests.

**Tasks**:
1. **Create `Sources/SwiftAcervo/InFlightDownloads.swift`:**
   ```swift
   import Foundation

   actor InFlightDownloads {
       static let shared = InFlightDownloads()

       private struct Entry {
           let task: Task<Void, Error>
           var progress: Double
       }
       private var entries: [String: Entry] = [:]

       /// Returns the existing in-flight task for `modelId`, or invokes `start()`
       /// to create one. Concurrent callers with the same `modelId` converge on
       /// a single task.
       func task(
           for modelId: String,
           start: @Sendable () -> Task<Void, Error>
       ) -> Task<Void, Error> {
           if let existing = entries[modelId]?.task { return existing }
           let new = start()
           entries[modelId] = Entry(task: new, progress: 0.0)
           return new
       }

       func publishProgress(_ p: Double, for modelId: String) {
           guard entries[modelId] != nil else { return }
           entries[modelId]?.progress = min(max(p, 0.0), 1.0)
       }

       func progress(for modelId: String) -> Double? {
           entries[modelId]?.progress
       }

       func finish(_ modelId: String) {
           entries.removeValue(forKey: modelId)
       }

       func contains(_ modelId: String) -> Bool {
           entries[modelId] != nil
       }

       /// Test-only seam: empties the registry. NOT for production use.
       func reset() {
           entries.removeAll()
       }
   }
   ```
   Note: `start` is a synchronous closure that creates a `Task` — the closure runs while the actor is isolated, but `Task { ... }` is non-blocking, so this is safe. Concurrent callers who lose the race to register simply get the winner's task back.
2. **Wire dedup into `Acervo.ensureAvailable(_:files:...)`.** The internal overload at `Acervo.swift:1118–1139` carries the `if isModelAvailable → return; else download(...)` body (the public overload at `:1098–1111` is just a forwarder). Rewrite the INTERNAL overload as:
   ```swift
   static func ensureAvailable(
       _ modelId: String,
       files: [String],
       progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
       in baseDirectory: URL,
       telemetry: (any AcervoTelemetryReporter)? = nil
   ) async throws {
       // Fast path: already available, no work.
       if isModelAvailable(modelId, in: baseDirectory) { return }

       // Wrap caller's progress so each tick also publishes to InFlightDownloads.
       let wrappedProgress: (@Sendable (AcervoDownloadProgress) -> Void) = { p in
           Task { await InFlightDownloads.shared.publishProgress(p.overallProgress, for: modelId) }
           progress?(p)
       }

       let sharedTask = await InFlightDownloads.shared.task(for: modelId) {
           Task {
               defer { Task { await InFlightDownloads.shared.finish(modelId) } }
               try await download(modelId, files: files, force: false, progress: wrappedProgress, in: baseDirectory, telemetry: telemetry)
           }
       }
       try await sharedTask.value
   }
   ```
   Caveats to bake into the implementation:
   - The `defer` on the inner Task is for the originator's path; on a thrown error, `finish` still fires so the registry is cleared for retries. Use `Task { ... }` inside `defer` because `defer` is sync and `finish` is `async`.
   - A joiner who calls `ensureAvailable` for the same `modelId` while a task is in flight: their `task(for:start:)` returns the existing task; their `start` closure is NOT invoked. They `await sharedTask.value` and receive the same outcome (success or thrown error). The wrappedProgress closure built by the joiner is never installed — only the originator's progress callback is wired into the actual download.
   - The dedup KEY is `modelId`, NOT `(modelId, files)`. A joiner that requested a different `files` subset rides on the originator's set. Document this in the `ensureAvailable` doc comment as a known and tested trade-off.
3. **Remove the Sortie 5 stub** in `Acervo.availability(_:)`. Replace:
   ```swift
   // TODO(Sortie 6): replace stub ...
   let inFlight = false
   ```
   with:
   ```swift
   let inFlight = await InFlightDownloads.shared.contains(modelId)
   ```
   And replace the placeholder progress lookup with the real one:
   ```swift
   let p = await InFlightDownloads.shared.progress(for: modelId) ?? 0.0
   return .downloading(progress: p)
   ```
4. **Extend `Tests/SwiftAcervoTests/AvailabilityThreeStateTests.swift`** with the following tests (continuing nested under `SharedStaticStateSuite.MockURLProtocolSuite`). Each test must call `await InFlightDownloads.shared.reset()` in its setup OR rely on test serialization to provide a clean registry.
   - `dedup_singleDownloadUnderConcurrency`: configure `MockURLProtocol` with a slow responder (1 s sleep) that serves a synthetic manifest plus 3 files. Launch 2 concurrent `Task { try await Acervo.ensureAvailable(modelId, files: [], in: tempBase, ...) }` calls. After both `await`, assert `MockURLProtocol.requestCount == 4` (1 manifest + 3 files) — NOT 8. Both tasks complete successfully.
   - `dedup_registryClearedAfterCompletion`: after a single `ensureAvailable` call succeeds, assert `await InFlightDownloads.shared.contains(modelId) == false`.
   - `dedup_errorPropagatesToJoiner`: configure the responder to throw on the second file. Launch 2 concurrent `ensureAvailable` calls. Assert both receive the SAME error (same `AcervoError` case), AND `await InFlightDownloads.shared.contains(modelId) == false` afterward, AND a third `ensureAvailable` call after the failure starts a fresh download (request counter increments beyond the previous total).
   - `downloading_stateObservableViaAvailability`: drive a slow download in one task. From another task, poll `Acervo.availability(modelId)` every 100 ms via `Task.sleep`. Assert that at least one poll observes `.downloading(progress: p)` with `0.0 <= p < 1.0`, AND a final poll after the download completes observes `.available`. Use a `nonisolated(unsafe)` array of observed progress values to assert monotonic non-decrease.
   - `dedup_joinerWithDifferentFilesRidesOriginator`: launch originator with `files: ["config.json", "model.safetensors"]`; concurrently launch joiner with `files: ["config.json"]`. Assert request count is exactly the originator's set (3: manifest + 2 files), NOT 4 (manifest + 2 + 1). Documents the modelId-only dedup-key behavior. Sortie 7's CHANGELOG entry must note this contract.
   - `hardKillSimulation_returnsNotAvailable_withPartialOnDisk`: pre-populate `{slug}/file.part` (a partial). Do NOT register any in-flight task. Call `availability(modelId)`. Assert `.notAvailable` (because `isModelAvailable` sees no `.acervo-manifest.json` AND the size check fails). This proves that the on-disk `.part` file alone does not satisfy `.available` — the InFlightDownloads registry is the only source of `.downloading`-ness.
5. **Verify `grep -rn "TODO(Sortie 6)" Sources/ Tests/`** returns ZERO hits (both stubs removed; no new ones added).
6. Run `make test`. All existing tests still pass.

**Exit criteria**:
- [ ] `make test` returns 0.
- [ ] `Sources/SwiftAcervo/InFlightDownloads.swift` exists with the full actor surface (`task`, `publishProgress`, `progress`, `finish`, `contains`, `reset`).
- [ ] `Acervo.ensureAvailable(_:files:...)` wraps its work in `InFlightDownloads.shared.task(for:)` and clears the registry via `finish` in both success and failure paths.
- [ ] Doc comment on `ensureAvailable` describes (a) the `modelId`-only dedup key and (b) the joiner-with-different-files trade-off. Verify via `grep -B2 -A30 "public static func ensureAvailable" Sources/SwiftAcervo/Acervo.swift`.
- [ ] All 6 new tests listed in task #4 pass.
- [ ] `grep -rn "TODO(Sortie 6)" Sources/ Tests/` returns no matches.
- [ ] The pre-existing test `EnsureAvailableEmptyFilesTests` still passes. (This test exercises the production-typical `files: []` path that the dedup logic must not break.)
- [ ] `MockURLProtocol.requestCount` assertion in `dedup_singleDownloadUnderConcurrency` shows count is the originator's request set, not 2× the originator's set.

---

### Sortie 7: Version + CHANGELOG + API docs for WU2

**Priority:** 3 — leaf sortie. Carries the breaking-semantic CHANGELOG entry, so accuracy matters more than scope.

**Entry criteria**:
- [ ] Sortie 6 exit criteria all green.
- [ ] All WU2 tests pass on a clean run.

**Files in scope**:
- `Sources/acervo/Version.swift`.
- `CLAUDE.md` (Version line).
- `CHANGELOG.md`.
- `Docs/API_REFERENCE.md` — document `ModelAvailability`, `availability(_:)`, `isModelConfigPresent`, and the tightened contract on `isModelAvailable`.

**Tasks**:
1. Bump `Sources/acervo/Version.swift` to our next minor release version.
2. Update the `**Version**:` line in `CLAUDE.md` Quick Reference to match.
3. Add a `CHANGELOG.md` entry under our next minor release version with today's date. Required structure:
   - **Added**:
     - `ModelAvailability` enum (`.notAvailable | .downloading(progress: Double) | .available`).
     - `Acervo.availability(_:)` and `AcervoManager.availability(_:)` — the canonical three-state read API.
     - `Acervo.isModelConfigPresent(_:)` — explicit escape hatch for callers that genuinely only want to probe for `config.json` at the model root. Does NOT imply usability.
     - `InFlightDownloads` actor (internal) — process-wide in-flight download registry. Two concurrent `ensureAvailable(modelId, ...)` calls for the same model now share a single underlying download.
     - Manifest persistence on disk at `{baseDirectory}/{slug}/.acervo-manifest.json` after each successful `downloadFiles`. Used by the new strict `isModelAvailable` and by `availability(_:)`.
     - `IntegrityVerification.allManifestFilesPresentBySize(manifest:in:)` and `IntegrityVerification.partialFileSize(at:)` (internal helpers).
   - **Changed (BREAKING SEMANTIC)**:
     - `Acervo.isModelAvailable(_:)` now returns `true` only when every file declared in the cached manifest is present on disk at the manifest's recorded `sizeBytes`. The previous loose semantics ("`config.json` exists at the model root") is preserved verbatim in the new `isModelConfigPresent(_:)`. Callers that intentionally want the loose probe must migrate. Callers that want "model is fully usable" should switch to `availability(_:)`.
     - `ensureAvailable(_:files:...)` now deduplicates concurrent callers via `InFlightDownloads`. The dedup key is `modelId`, not `(modelId, files)`: a joiner that requests a different `files` subset rides on the originator's set. Production callers pass `files: []` (everything in the manifest), so this trade-off is rarely observable; tests that exercise narrow file subsets concurrently for the same model should be aware.
   - **Cross-reference WU1:**
     - Confirm that the WU1 resumability/cleanup entries are already in CHANGELOG under the previous patch release; do not duplicate them here. Do NOT add a "Performance" subsection to this entry — REQUIREMENTS § 4.4 (chunked streaming) was intentionally deferred from this mission. If a follow-up mission ships the perf fix, it gets its own dated entry.
4. Update `Docs/API_REFERENCE.md`:
   - Add a `ModelAvailability` section to the type reference. Document each case with semantics.
   - Add `availability(_:)` documentation under both `Acervo` and `AcervoManager`. Note: non-throwing, no network I/O, observes `InFlightDownloads` for `.downloading`.
   - Add `isModelConfigPresent(_:)` with the warning (escape hatch only).
   - Update `isModelAvailable(_:)` to reflect the new strict contract. Cross-reference the migration note in `CHANGELOG.md` and the design doc at `Docs/MODEL_AVAILABILITY_PATH.md`.
5. Do NOT tag a release.
6. Run `make test` once more to confirm the version bump is correct.

**Exit criteria**:
- [ ] `Sources/acervo/Version.swift` reflects the next minor release version.
- [ ] `CLAUDE.md` Quick Reference version matches.
- [ ] `CHANGELOG.md` has a dated entry under the next minor release with both **Added** and **Changed (BREAKING SEMANTIC)** sections, covering every bullet listed in task #3.
- [ ] `Docs/API_REFERENCE.md` documents `ModelAvailability`, `availability(_:)` (on both `Acervo` and `AcervoManager`), `isModelConfigPresent`, and the tightened contract on `isModelAvailable`.
- [ ] `make test` returns 0.
- [ ] No `git tag` was created.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 2 |
| Total sorties | 7 |
| Dependency structure | 2 layers (WU2 depends on WU1); strict sequential within each layer |
| Parallelism | None — every sortie includes `make test` (supervising agent only) |
| Critical path length | 7 sorties |
| Estimated turns per sortie (50-turn budget) | Sortie 1: ~32 (largest in WU1); Sortie 2: ~10; Sortie 3: ~6; Sortie 4: ~38 (test migration is the bulk; largest overall); Sortie 5: ~18; Sortie 6: ~28; Sortie 7: ~10 |
| Largest sortie | Sortie 4 (~38 turns) — still right-sized (76% of budget). Three internal phases keep it organized. |

| Detection metric | Count |
|--------|-------|
| Requirements detected (REQUIREMENTS.md §4 work items addressed in this mission) | 5 (§ 4.1, 4.2, 4.3, 4.5, 4.6) |
| Requirements explicitly deferred | 1 (§ 4.4 chunked streaming) |
| Atomic tasks (across all sorties) | ~36 |
| New public types or methods | 3 (`ModelAvailability`, `Acervo.availability`, `Acervo.isModelConfigPresent`) + 1 on `AcervoManager` |
| Breaking semantic changes | 1 (`isModelAvailable` strict-check semantics) |
| New test files | 3 (ResumableDownload, AvailabilityThreeState, plus `AcervoAvailabilityTests` extensions) |
| Existing test files migrated | ≥ 5 (IntegrationTests, ModelDownloadManagerTests, MultiFileRollbackTests, ComponentIntegrationTests, AcervoDownloadAPITests) |

## Refinement Pass Results

| Pass | Status | Notable changes from the pre-refinement plan |
|------|--------|--------|
| 1. Atomicity & Testability | ✓ PASS | No splits or merges. Sortie 4 (formerly 5) re-organized into 3 internal phases for clarity. |
| 2. Prioritization | ✓ PASS | Priority scores added to every sortie. Order matches the natural dependency chain (no reordering needed). |
| 3. Parallelism | ✓ PASS | Zero parallel groups. Critical path = total sortie count = 7. All sorties include builds → supervising agent only. |
| 4. Open Questions & Vague Criteria | ✓ PASS | Ambiguities resolved and locked in (see § Open Questions & Resolutions). |
| 5. Research-assumption audit (pass 5, 2026-05-18) | ✓ PASS | Code-walked every cited line/range against `Sources/SwiftAcervo/` at HEAD `d0aa8da`. Corrections: (a) original Sortie 1 (chunked streaming) deferred — proposed AsyncBytes-batching code was structurally equivalent to the existing byte loop (capacity already reserved at line 489); REQUIREMENTS § 4.4 will ship in its own mission with the per-task `URLSessionDataDelegate` approach. (b) `ensureAvailable` body cited at `:1098–1139` corrected to `:1118–1139` (internal overload). (c) Line counts and existing constant references updated. (d) All "perf" or throughput claims removed from CHANGELOG bullets and test assertions; this mission asserts behavioral correctness only. |

**VERDICT**: ✓ Plan is ready to execute.

**Next step**: `/mission-supervisor start`
