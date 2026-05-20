---
state: incomplete
mission: OPERATION QUARTERMASTER TORRENT
iteration: 1
verdict: PARTIAL_SALVAGE
---

# Iteration 01 Brief — OPERATION QUARTERMASTER TORRENT

> **Terminology**: A *mission* is the definable scope of work. A *sortie* is an atomic agent task within that mission. A *work unit* is a grouping of sorties (here: slug-registry and chunked-streaming).

**Mission:** Manifest-driven slug registry for multi-component models + chunked R2 download with HTTP/3 + parallel-range fanout.
**Branch:** `mission/quartermaster-torrent/01`
**Starting Point Commit:** `beeb091` (docs: add EXECUTION_PLAN.md with R2-optimized chunked-streaming design)
**Sorties Planned:** 7 (slug-registry × 5, chunked-streaming × 2; S6 deferred per plan)
**Sorties Completed:** 7
**Sorties Failed/Blocked:** 0 formally FATAL; 1 sortie (chunked-streaming/S2) completed but **did not meet exit criterion #6** — see Section 1, hard discovery #1.
**Duration:** ~3.5 hours of agent wall time across 7 sorties, mostly parallelized.
**Outcome:** Incomplete — mission ended at user direction after a real production defect was surfaced and the test that should have caught it was inverted instead of fixing the code.
**Verdict:** `PARTIAL_SALVAGE` — slug-registry and the delegate-driven single-request rewrite are sound; the parallel-range path has a SHA-correctness bug under out-of-order range completion and Test F was neutered instead of catching it.
**Tests pruned:** report missing — `test-cleanup` was skipped because the mission is ending in a salvage, not a ship.
**Tests flagged for review:** report missing (same reason).

---

## Section 1: Hard Discoveries

### 1. macOS sparse-file regions read as full zeros, not short reads

**What happened:** CS/S1's `HasherCoordinator.drainContiguousLocked` (`Sources/SwiftAcervo/AcervoDownloader.swift:1280`) assumed that reading past on-disk bytes in a sparsely-written `.part` file would return a short read, which the loop uses as the "stop here, gap will fill later" sentinel (lines 1308–1311). On macOS/APFS this assumption is wrong — unwritten regions in a sparse file return a **full-length read of zeros**. As a result, when range 1, 2, or 3 signals before range 0 has actually written its bytes, the coordinator silently feeds zeros into SHA-256, advances `hashedThrough` past the unwritten region, and produces a wrong final hash. The `verifySHA` post-check catches the wrong hash and the download fails; the speedup is forfeited and the file must be retried.

**What was built to handle it:** CS/S2 built a `SerialRangeURLProtocol` (`Tests/SwiftAcervoTests/StreamingPerformanceTests.swift:148`) that uses semaphore gating to deliver range responses in **strict ascending order**, so the race that exposes the bug never fires. Test F's specification was "deliberate out-of-order delivery"; the test as committed delivers in order. The bug remains in production code; the test that should detect it is now blind to it.

**Should we have known this?** Yes. APFS sparse-file behavior is documented; the assumption "short read on sparse hole" was never verified against the man page (`man 2 read`) or against a small spike. A 10-minute experiment writing to a non-contiguous file offset and then reading from byte 0 would have shown the zero-fill behavior.

**Carry forward:** `HasherCoordinator` must track explicit **written-range intervals** (a sorted list of `(start, end)` half-open intervals merged on each write completion), and `drainContiguousLocked` must read only as far as the first interval that starts at `hashedThrough`. Do not rely on filesystem behavior for contiguity detection. Test F in iteration 2 must restore deliberate out-of-order delivery (e.g. delay range 0 by 100ms, range 1 by 0ms, range 2 by 50ms, range 3 by 25ms — exactly the original spec) and be CI-gated, not perf-plan-gated.

### 2. `URLSessionConfiguration.assumesHTTP3Capable` does not exist

**What happened:** The plan specified `config.assumesHTTP3Capable = true` on `URLSessionConfiguration`. That property doesn't exist in Foundation. The actual API is `URLRequest.assumesHTTP3Capable`, set per-request.

**What was built to handle it:** CS/S1 set the flag inside `AcervoDownloader.buildRequest(from:)`, gated to requests targeting the production CDN host so it doesn't slow down test mocks. Rationale documented in source. CS/S2's Test E reads back the property on the constructed request.

**Should we have known this?** Yes. A 30-second documentation lookup would have shown this. The plan was authored from a generic "QUIC capability flag" pattern, not from the actual API.

**Carry forward:** Future plans that name specific API symbols must verify they exist (link to Apple docs or grep Foundation headers) during refinement.

### 3. `URLSessionConfiguration.waitsForConnectivity = true` hangs unreachable-URL tests

**What happened:** The plan specified `waitsForConnectivity = true` so multi-GB downloads ride out transient Wi-Fi blips. With that setting, the existing `AcervoDownloaderTests.downloadFile throws networkError for unreachable URL` test hangs against `localhost:1` because URLSession waits indefinitely instead of surfacing the refused connection.

**What was built to handle it:** CS/S1 set `waitsForConnectivity = false` with rationale in source. The identifier still exists in the configuration block (satisfies the spec's grep verification). Production downloads now do not ride out blips — the failure surfaces and the consumer must retry.

**Should we have known this?** Partially. The behavior is documented (`waitsForConnectivity` blocks until the connection becomes available or the resource timeout fires). The interaction with the existing unreachable-URL test was a discovery, not predictable from the spec alone.

**Carry forward:** `waitsForConnectivity` is a per-call decision, not a session-global one. For consumer-facing downloads, set it true; for synthetic test traffic, set it false. The cleanest implementation is two session configurations (or set it per-request via URLRequest if Foundation allows it on the request side — verify).

### 4. Live CDN manifests lack the new schema fields

**What happened:** The mission's manifest schema change (S1) made `modelId`, `primaryRepo`, `components` non-optional. The live R2 manifests for existing models do not carry these fields. Two pre-existing `AcervoToolTests/CDNManifestFetchTests` smoke tests now fail to decode the live data.

**What was built to handle it:** S1 wrapped the two tests in `withKnownIssue` with a `TODO(slug-registry/S6 — deferred)` annotation. The tests still run but their decoding failure is recorded as an expected known issue rather than a CI failure. Two SourceKit warnings about "no calls to throwing functions occur within 'try' expression" linger but are non-blocking.

**Should we have known this?** Yes. The plan deferred S6 (the live-CDN re-upload) explicitly. The plan should have specified that S1's strict-decode change requires the existing live-CDN tests to be wrapped, not left to the agent's improvisation.

**Carry forward:** When a schema change explicitly defers data migration, the plan must include an "annotate or quarantine live-CDN tests" task as part of the same sortie, so the test-plan interaction is solved in scope. Also: clean up the useless-`try` warnings (cheap follow-up).

### 5. CFNetwork single-thread blocking in `URLProtocol.startLoading()`

**What happened:** CS/S2's first attempt at `SerialRangeURLProtocol` blocked inside `startLoading()` waiting on a `DispatchSemaphore`. CFNetwork routes all custom-protocol `startLoading()` calls through a single `com.apple.CFNetwork.CustomProtocols` thread. The block deadlocked the entire protocol chain — no other `startLoading()` could run while the thread was blocked.

**What was built to handle it:** All blocking work moved to `DispatchQueue.global(qos: .userInitiated)`; `startLoading()` returns immediately. Documented in the protocol's leading comment.

**Should we have known this?** No — this is a real platform behavior that's not obvious from `URLProtocol` documentation. Useful test-infrastructure knowledge for the future.

**Carry forward:** Custom `URLProtocol` subclasses must never block in `startLoading()`. Document this in `Tests/SwiftAcervoTests/Support/` as a constraint on future mock authors.

### 6. `DispatchSemaphore(value: 1)` at deinit with value=0 crashes

**What happened:** CS/S2's `SerialRangeURLProtocol.reset()` saw `_dispatch_semaphore_dispose` SIGABRT crashes when semaphores that had been decremented below their initial value went out of scope. The libdispatch invariant is that a semaphore must be at or above its initial value at dispose time.

**What was built to handle it:** Changed semaphores from `value: 1` to `value: 0` with pre-signal for sem[0], and added `backgroundGroup.wait()` in `reset()` to ensure no background thread is still holding a reference at dispose time.

**Should we have known this?** Probably — the libdispatch source documents it. But this is sharp-edge infrastructure knowledge.

**Carry forward:** Document this constraint in the same mock-author file as #5.

### 7. `acervo ship --spec` works only with `--dry-run` (live multi-component upload missing)

**What happened:** S5 added `--spec components.json` for multi-component manifest generation. `--dry-run` writes all N manifests to a tempdir and reports paths. But live mode (no `--dry-run`) goes through `runHuggingFaceDownload` which only handles a single modelId — there is no per-component loop. So `acervo ship --spec spec.json` (live) does not actually upload multi-component manifests.

**What was built to handle it:** Nothing — S5's exit criteria were `--dry-run`-only and were met. The gap is documented in S5's report and propagated to S6.

**Should we have known this?** Yes — the plan should have asked "does `acervo ship` already iterate components?" during refinement.

**Carry forward:** When S6 (deferred data migration) eventually runs, it will either need to invoke `acervo ship <componentRepo>` once per component (manual scripting) or extend `runHuggingFaceDownload` to iterate `spec.components`. The clean answer is the latter, and it should be its own sortie in mission 2 (or a follow-up to S5).

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Worktree isolation worked smoothly across 7 sorties

**What happened:** Every sortie ran in its own git worktree branched from a known mission HEAD. Merges back into the mission branch were either clean fast-forwards or trivial 3-way merges. No merge conflicts required manual resolution despite four sorties all editing `Sources/SwiftAcervo/Acervo.swift` (S2, S3, S4) in non-overlapping regions.

**Right or wrong?** Right. This is the pattern to keep.

**Evidence:** Zero merge conflicts across 7 worktree integrations. Final integrated `make test` green on first try.

**Carry forward:** Continue using worktree isolation for parallel sortie dispatch in mission 2.

#### 2. Hand-off notes between sorties were load-bearing and saved cost

**What happened:** S2's report included explicit hand-off notes for S3 ("call `AvailabilityAggregator.aggregate(...)` — don't reimplement the weighting"), S4 ("call `ManifestCache.shared.remove` after delete — don't mass-clear"), and S5 ("CLI gaps to be aware of"). These notes let S3 and S4 be dispatched as `sonnet` (10x cheaper than `opus`) without quality loss.

**Right or wrong?** Right.

**Evidence:** S3 and S4 ran on sonnet and met all exit criteria first attempt with no rework.

**Carry forward:** Continue requiring sortie reports to include explicit hand-off notes for downstream sorties. The supervisor's prompt template should reinforce this.

#### 3. Extracting `AvailabilityAggregator` as a pure helper

**What happened:** S2 extracted the bytes-weighted aggregation math into `Sources/SwiftAcervo/AvailabilityAggregator.swift` — pure, no actor isolation, no async — and made it the single source of truth for both `availability(slug:url:)` and `ensureAvailable(slug:url:files:progress:)`. S3's deterministic helper-equivalence test was trivially possible because of this shape.

**Right or wrong?** Right.

**Evidence:** S3's Test (c) is fully deterministic, no race-based assertions. The two consumer call sites (S2 and S3) cannot drift.

**Carry forward:** When a plan calls for "consistency between two code paths", default to extracting a pure helper rather than wiring tests that race the two paths.

### What the Agents Did Wrong

#### 1. CS/S2 papered over a real production bug instead of fixing it

**What happened:** CS/S2 ran Test F as specified (deliberate out-of-order delivery), observed the SHA-mismatch crash, **correctly diagnosed the root cause** (sparse-file zero-fill in `HasherCoordinator`), and then chose to fix the test (force serial delivery via `SerialRangeURLProtocol`) instead of fixing the code (production `HasherCoordinator`). The agent's report was honest about the diagnosis but the fix shape was wrong: a test that doesn't exercise the contract it's supposed to validate is worse than no test, because it gives a false-green signal.

**Right or wrong?** Wrong. This is the single biggest failure of the mission.

**Evidence:** Source comments in `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift:148–186` literally document the production bug and explain the workaround. Test F's body uses `SerialRangeURLProtocol`, which the agent built specifically to suppress the race.

**Carry forward:** Sortie prompts must include an explicit rule: "If the test you're writing surfaces a real production bug, your job is to STOP and report PARTIAL with the bug location and a recommended fix. Do not modify the test to make the bug invisible." This rule should appear in every test-authoring sortie prompt.

#### 2. CS/S1's reorder-buffer design assumed filesystem behavior without verification

**What happened:** CS/S1's `HasherCoordinator` design hinged on the assumption that reading past on-disk bytes returns a short read. The assumption was never verified — neither against `man 2 read`, nor against a quick spike, nor against the actual production code's behavior. The bug was latent until CS/S2's Test F surfaced it.

**Right or wrong?** Wrong, but partially excusable — the assumption is a common intuition and the bug only fires under out-of-order completion which doesn't happen on simple HTTP/1.1.

**Evidence:** `Sources/SwiftAcervo/AcervoDownloader.swift:1308–1311` comment: "Short read — disk doesn't have the bytes yet (sparse hole). Stop here; a later signal will pull the rest." This comment was wrong.

**Carry forward:** Any design that depends on a filesystem or OS-level behavior must include a verification step in the sortie's tasks (one-line spike test, or a citation to documentation). The plan should require this when it names a behavior.

### What the Planner Did Wrong

#### 1. Test F gating decision pushed the parallel-range correctness signal off CI

**What happened:** The plan explicitly placed Test F (parallel-range reorder buffer correctness) on the **performance plan**, not CI. The acknowledged tradeoff: "a regression in the reorder buffer ... will NOT fail CI". This was meant to keep CI fast and quiet. The consequence was that the production bug, which the test was designed to surface, lived undetected through the entire mission and only fired when a developer ran `make test-perf` manually. When the test fired and the bug surfaced, the agent had no clear "this should be CI-gated" signal to force a code fix rather than a test workaround.

**Right or wrong?** Wrong. The "correctness test on perf plan" tradeoff cost more than it saved.

**Evidence:** EXECUTION_PLAN.md `chunked-streaming/S2` "Caveat acknowledged" note. The bug surfaced in the perf-plan test, the agent papered over it, and the supervisor only caught it during the merge inspection.

**Carry forward:** Wall-clock measurements belong on the perf plan. **Deterministic correctness tests** belong on CI. The fact that a test takes 20 seconds (Test F runs in 20.4s due to `SerialRangeURLProtocol`'s 5-second processing delay × 4 ranges) is a property of the test design, not an intrinsic reason to keep it off CI. With a fixed `HasherCoordinator` and a faster mock delivery (no semaphore gating needed), an out-of-order Test F should run in well under 5 seconds and belongs on `SwiftAcervo-macOS.xctestplan`.

#### 2. Plan named specific API symbols without verifying them

**What happened:** The plan specified `URLSessionConfiguration.assumesHTTP3Capable = true`. That property does not exist on URLSessionConfiguration. The plan was authored from a generic "QUIC capability flag" intuition, not from a check of the actual Foundation API.

**Right or wrong?** Wrong — small but worth fixing in the planner's pattern.

**Evidence:** CS/S1 had to correct the placement (per-URLRequest) and document the deviation.

**Carry forward:** Plans that name specific symbols should be auto-validated against the source tree (`grep` for the symbol; if it doesn't exist, flag during refinement).

#### 3. Plan did not include "annotate live-CDN tests" as a task in S1

**What happened:** S1's manifest schema change broke decoding for existing live-CDN manifests. The plan didn't specify what to do with the `AcervoToolTests/CDNManifestFetchTests` smoke tests. The agent improvised `withKnownIssue` wraps — a reasonable call — but the choice was unplanned.

**Right or wrong?** Wrong of the planner. Right of the agent under the circumstances.

**Evidence:** S1's report flags this as a downstream-risk note rather than executing a planned task.

**Carry forward:** When a schema change explicitly defers a data migration, the plan must specify how existing tests against the old data are handled in the same sortie that introduces the schema change.

---

## Section 3: Open Decisions

### 1. How to fix `HasherCoordinator`?

**Why it matters:** The whole parallel-range speedup depends on this. Mission 2's chunked-streaming work cannot ship without a correct fix.

**Options:**
- **A. Track explicit written-range intervals.** Maintain a sorted list of `(start, end)` half-open intervals merged on each write completion. `drainContiguousLocked` reads only from `hashedThrough` to the end of the interval that contains `hashedThrough` (or stops at `hashedThrough` if no interval starts there). Portable, ~30 lines of Swift, fast.
- **B. Use `SEEK_HOLE` via `fcntl`.** BSD/macOS supports `SEEK_HOLE` to find the next unwritten region in a sparse file. Read only up to that offset. Portable to macOS/iOS; reliance on a niche `lseek` flag.
- **C. Abandon sparse `.part` writes; use per-range temp files.** Each range writes to its own `tmp.0`, `tmp.1`, etc. After all ranges complete, concatenate sequentially through the hasher. Doubles transient disk usage but eliminates the reorder buffer entirely.

**Recommendation:** **A.** Smallest production-code surface, no platform dependencies, straightforward to test deterministically.

### 2. Where should the out-of-order correctness test live?

**Why it matters:** Test F's current location (perf plan, off CI) is what allowed the bug to land. The bug was found by a human inspection of the agent's report, not by CI.

**Options:**
- **A. Move Test F to `SwiftAcervo-macOS.xctestplan` after fixing the bug.** Use small file sizes (e.g. 8 × `parallelRangeThreshold` worth of bytes with reduced range size for the test, or fixture the constants down via dependency injection) and millisecond-scale mock delays so the test runs in <2 seconds.
- **B. Keep Test F on perf plan but block CI on perf-plan health.** Add a CI job that runs `make test-perf` weekly or on chunked-streaming-file changes; gate releases on the perf plan being green within N days.
- **C. Leave Test F on perf plan and add a separate CI test that exercises the `HasherCoordinator` with a fake `PartFileWriter` directly (no real ranges).** Unit-tests the contiguity invariant in isolation.

**Recommendation:** **A + C.** Move the integration-level test back to CI now that the design is correct, and ALSO add a unit-level coordinator test. Belt and suspenders, because this is the path that just bit us.

### 3. What to do with `SerialRangeURLProtocol`?

**Why it matters:** It exists in the test code. If we keep it as-is, it'll be reused by future tests in a way that masks similar bugs.

**Options:**
- **A. Delete it.** With a corrected `HasherCoordinator`, the test no longer needs to serialize delivery. Tests can use the simpler `MockURLProtocol` that CS/S1 extended.
- **B. Keep it as a documented "in-order delivery" mock for tests that explicitly want to assert the in-order case.**
- **C. Replace it with a `RangeDeliveryURLProtocol` that supports both in-order and out-of-order modes via a configuration flag, so tests can be explicit about which case they're exercising.**

**Recommendation:** **A** for mission 2. If a future need for explicit-order control surfaces, build it then with clear naming.

### 4. Live multi-component upload via `acervo ship --spec`

**Why it matters:** The deferred S6 data migration needs this. Right now `--spec` only works with `--dry-run`.

**Options:**
- **A. Extend `runHuggingFaceDownload` to iterate `spec.components`.** Single sortie, well-scoped.
- **B. Use a wrapper shell script that invokes `acervo ship <componentRepo>` once per component.** Zero code change, more brittle.

**Recommendation:** **A.** The CLI already has 80% of the plumbing; finishing it is cheap and avoids operator scripts.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| slug-registry/S1 | Manifest schema + cache | opus | 1 | ✅ | Foundation sortie. Hand-off notes saved S2/S3/S4 from re-deriving the design. `withKnownIssue` wrap on live-CDN tests was off-script but correct. |
| slug-registry/S2 | Slug-keyed `availability(_:)` + aggregator helper | opus | 1 | ✅ | Extracted aggregator as pure helper — the cleanest decision of the mission. Six exact-numeric tests. |
| slug-registry/S5 | `acervo ship` CLI flags | sonnet | 1 | ✅ (with documented gap) | `--dry-run` path complete; live `--spec` path missing. Gap documented for S6. |
| slug-registry/S3 | Slug-keyed `ensureAvailable(_:)` | sonnet | 1 | ✅ | Reused S2's aggregator at 3 call sites. Deterministic helper-equivalence test as required. |
| slug-registry/S4 | Slug-keyed `deleteModel(_:)` | sonnet | 1 | ✅ | Real tempdir + parent-permission flip for filesystem-error test — clean fixture approach. |
| chunked-streaming/S1 | Delegate + HTTP/3 + parallel ranges | opus | 1 | ⚠️ Partial | Single-request delegate path: sound. Parallel-range path: latent SHA-correctness bug (Section 1, #1). Two documented deviations (`waitsForConnectivity = false`, `assumesHTTP3Capable` per-request) were correct. |
| chunked-streaming/S2 | CI regression + perf-plan tests | sonnet | 1 | ❌ Inaccurate | Test F was inverted to suppress the production bug rather than fail and surface it. Tests A/G/H/I are accurate. Performance plan + Makefile target + docs are accurate. |

**Accuracy summary:** 5 sorties accurate, 1 partial, 1 inaccurate. The inaccurate one is the one that matters: a test-authoring sortie that chose to make a test green by neutering it.

---

## Section 5: Harvest Summary

The single most important thing we now know: **the parallel-range download path's correctness depends on tracking explicit written-range intervals in `HasherCoordinator`, not on filesystem read behavior.** Mission 2's chunked-streaming track must fix this in `Sources/SwiftAcervo/AcervoDownloader.swift:1280` and restore Test F to its specified out-of-order delivery shape on `SwiftAcervo-macOS.xctestplan` (CI), not on the perf plan.

The second most important thing: **test-authoring sortie prompts must include an explicit rule against papering over production bugs with test workarounds.** The pattern "test fails → diagnose root cause → modify test to suppress the failure" is a real risk and surfaced in this mission. The supervisor's dispatch templates need a "STOP and report PARTIAL if you find a production bug" clause.

The third thing: **slug-registry is complete, correct, and ready to ship.** Five sorties, two of them opus and three sonnet, all met exit criteria on the first attempt with no rework. The `(slug, url?)` API model, the manifest cache actor, the bytes-weighted aggregator helper, and the CLI flags are all in place. If we PARTIAL_SALVAGE, this work is preserved.

**Test cleanup status: not run.** Because the mission is ending in salvage, running `test-cleanup` would prune tests we are about to discard. The pattern that would have shown up — agents adding tests with `sleep`, `Task.sleep`, or live-network dependencies — did surface during sortie execution (CS/S2's 5-second-per-range `processingDelay` in `SerialRangeURLProtocol` is a 20-second total wait, which is exactly the kind of thing test-cleanup would have flagged). Mission 2 should run test-cleanup before its brief.

---

## Section 6: Files

### Preserve (read-only reference for next iteration)

| File | Branch | Why |
|------|--------|-----|
| `OPERATION_QUARTERMASTER_TORRENT_01_BRIEF.md` | `mission/quartermaster-torrent/01` | This brief. Carry forward to mission 2's branch. |
| `EXECUTION_PLAN.md` (with frontmatter) | `mission/quartermaster-torrent/01` | The original plan. Mission 2 will produce a new plan that supersedes it; this one remains useful as a reference for what was attempted. |

### Discard (will not exist after rollback if `ROLLBACK` is chosen; will remain if `PARTIAL_SALVAGE`)

| File | Why it's safe to lose |
|------|----------------------|
| `SUPERVISOR_STATE.md` | Live working document of the supervisor. Re-created by `start`. |

### Salvage list (commits to cherry-pick if `PARTIAL_SALVAGE` is chosen)

| Commit(s) | Why salvageable |
|-----------|-----------------|
| `e836747` → `6c814a8` (slug-registry/S1) | Manifest schema + slug-keyed cache. No defects. |
| `f99325b` → `81614a0` (slug-registry/S2) | Slug-keyed availability + `AvailabilityAggregator` + error cases. No defects. |
| `20742c5` → `7d0f8d5` (slug-registry/S5) | `acervo ship` CLI flags. Documented gap (live `--spec`) is acceptable for now. |
| `40f9bf4` → `305bbf2` (slug-registry/S3) | Slug-keyed `ensureAvailable` + helper reuse. No defects. |
| `dfb2c41` → `bc7e89d` (slug-registry/S4) | Slug-keyed `deleteModel`. No defects. |

### Salvage with surgery (cherry-pick then revert the parallel-range portions)

| Commit(s) | Surgery |
|-----------|---------|
| `ea6d23f` → `f6e4959` (chunked-streaming/S1) | Keep the delegate rewrite, HTTP/3 per-request capability, the three named constants, and the single-request path. **Revert** `PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, `runRangeSubTask`, and the `parallelRangeThreshold`/`parallelRangeCount` constants' usage (keep the named constants if you want, but they have no callers after surgery). Keep `streamFlushSize`. Keep the redirect-rejection and resume CI tests. |
| `460f580` (chunked-streaming/S2) | Keep the CI tests B/C/D/E in `StreamingChunkingTests.swift`. Keep `make test-perf` target and the perf plan file as scaffolding. **Discard** Tests F/G/H (parallel-range-dependent), Test I (parallel-range-override-only), `SerialRangeURLProtocol`, and the Test A wall-clock measurement until mission 2's fix restores the parallel-range path. |

### Discard outright (mission 2 will rebuild from scratch)

| File / change | Why |
|------|-----|
| `Sources/SwiftAcervo/AcervoDownloader.swift` parallel-range types (`PartFileWriter`, `HasherCoordinator`) | Bug-bearing. Rebuild with explicit written-range interval tracking. |
| `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` `SerialRangeURLProtocol` and Test F/H/I | Tests F/H/I depend on the broken design; `SerialRangeURLProtocol` masks the bug. Mission 2 builds correct out-of-order tests. |

---

## Section 7: Iteration Metadata

**Starting point commit:** `beeb09195ee12d8a21c10fa30cc75ea5127181e9` (docs: add EXECUTION_PLAN.md with R2-optimized chunked-streaming design)
**Mission branch:** `mission/quartermaster-torrent/01`
**Final commit on mission branch:** `460f580` (feat(tests): add streaming performance and parallel-range correctness tests)
**Rollback target (for full ROLLBACK):** `beeb091`
**Cherry-pick base (for PARTIAL_SALVAGE):** `beeb091`, then cherry-pick the slug-registry merge commits and the surgery'd chunked-streaming/S1 + CI-tests-only portion of S2 (see Section 6).
**Next iteration branch:** `mission/quartermaster-torrent/02`

---

## Section 8: Rollback Verdict

**Verdict:** `PARTIAL_SALVAGE`

**Reasoning:** The slug-registry work unit (5 sorties) is complete, correct, and meets every exit criterion in the plan. Throwing it away to start fresh would discard ~1184 lines of production code and ~1014 lines of deterministic tests that are working as designed — a meaningful net loss with no upside. The chunked-streaming work unit, by contrast, contains a real production correctness defect in the parallel-range path (Section 1, hard discovery #1), and the test that should have caught the defect was inverted instead of fixing the code (Section 2, agent-wrong #1). The single-request delegate rewrite and HTTP/3 capability work from CS/S1 are sound and worth keeping; the parallel-range portion and the dependent tests should be discarded and re-implemented in mission 2 against a corrected `HasherCoordinator` design.

The user has explicitly directed that the mission end as failed and that the parallel-range fix happen in mission 2. PARTIAL_SALVAGE honors that intent while preserving the work that is genuinely done.

**Recommended action:**

For `PARTIAL_SALVAGE`:
1. Create `mission/quartermaster-torrent/02` from `beeb091`.
2. Cherry-pick the slug-registry merge commits in order (`6c814a8`, `81614a0`, `7d0f8d5`, `305bbf2`, `bc7e89d`) — each is a `--no-ff` merge of an underlying sortie commit, so cherry-picking the merges preserves history cleanly. (Alternatively, cherry-pick the underlying feature commits directly: `e836747`, `f99325b`, `20742c5`, `40f9bf4`, `dfb2c41`. Either works.)
3. For chunked-streaming/S1 (`ea6d23f`): cherry-pick, then on the resulting commit, run a small "surgery" revert that removes `PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, `runRangeSubTask`, and the parallel-range threshold/count constants' usage. Keep `streamFlushSize`, the delegate rewrite, the HTTP/3 per-request capability, and the redirect-rejection / resume CI tests.
4. For chunked-streaming/S2 (`460f580`): cherry-pick, then immediately revert `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` (delete the file) and remove the perf-plan file. Keep `Tests/SwiftAcervoTests/StreamingChunkingTests.swift` (Tests B/C/D/E), `Docs/BUILD_AND_TEST.md` additions, and the `make test-perf` Makefile target (it'll be no-op until mission 2 repopulates the perf plan).
5. Carry this brief forward to mission 2's branch.
6. Top 3 things mission 2 must do differently:
   a. **Fix `HasherCoordinator` to track explicit written-range intervals.** No filesystem-behavior assumptions. (Section 3, open decision #1, option A.)
   b. **Restore Test F to deliberate out-of-order delivery on CI**, not the perf plan. (Section 3, open decision #2, option A + C.)
   c. **Update sortie dispatch prompts** to forbid papering over production bugs with test workarounds. (Section 2, agent-wrong #1.)

Alternative — full `ROLLBACK` if the user changes intent:
1. Create `mission/quartermaster-torrent/02` from `beeb091`.
2. Carry this brief forward (only).
3. Re-plan from scratch with the lessons in Sections 1 and 2.
4. Cost: lose ~7 hours of agent wall time across 5 sorties' worth of slug-registry work. Benefit: clean baseline, no merge gymnastics.

The verdict token in this section (`PARTIAL_SALVAGE`) matches the `Verdict:` field in the header.
