---
state: incomplete
mission: OPERATION QUARTERMASTER TORRENT
iteration: 2
predecessor: docs/incomplete/quartermaster-torrent-01/OPERATION_QUARTERMASTER_TORRENT_01_BRIEF.md
predecessor_branch: mission/quartermaster-torrent/01
predecessor_verdict: PARTIAL_SALVAGE
parked: 2026-05-20
parked_reason: "Mission scope re-prioritized. REQUIREMENTS §3 (manifest-driven validity oracle) became the higher-priority headline after the 2026-05-20 on-disk audit confirmed the current validity check is wrong in both directions (false-positive on Qwen3-Coder-Next-4bit; false-negative on FLUX.2-klein-4B). Chunked-streaming-rebuild (CSR-1..CSR-5) is deferred to a future mission. DC-1..DC-3 and CIH-1..CIH-2 carry forward verbatim into the successor mission."
successor_mission: TBD (run mission-supervisor name-feature)
---

# EXECUTION_PLAN.md — SwiftAcervo (OPERATION QUARTERMASTER TORRENT, Iteration 02)

> **PARKED 2026-05-20.** This plan is no longer the active mission. Reason: after restating the library's goal as "consumers depend on a slug and get a working model path, full stop," the highest-impact next work is REQUIREMENTS.md §3 (manifest-driven validity oracle), not the §2 chunked-streaming perf rebuild driving the CSR-* work units below.
>
> **What carries forward into the successor mission:**
> - **CIH-1, CIH-2** (CI hygiene) — port verbatim; independent and useful regardless.
> - **DC-1, DC-2, DC-3** (deferred §1 cleanup: live `acervo ship --spec`, three-manifest re-upload, `withKnownIssue` removal) — port verbatim. These are load-bearing for §3: the local `manifest.json` written by `ensureAvailable` is the artifact §3's validity oracle reads, and that artifact is the same blob DC ships to the CDN.
>
> **What stays parked:**
> - **CSR-1..CSR-5** (chunked-streaming rebuild — `HasherCoordinator` redesign, parallel-range path, out-of-order correctness test, perf-plan throughput test). Revive in a fresh mission after the availability-correctness mission ships. Do **not** revive verbatim — the hashing-design conversation will have aged, and §2 should be re-planned with whatever we learn from §3.
>
> Active scope for the next mission lives in `REQUIREMENTS.md` (§1 unification + §3 in full). Everything below this banner is historical context for whoever revives §2 later.

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Context

This is **iteration 02** of OPERATION QUARTERMASTER TORRENT. Iteration 01 ended in `PARTIAL_SALVAGE`:

- **Salvaged**: §1 slug-registry work (5 sorties, complete, on `mission/quartermaster-torrent/01`).
- **Failed**: §2 chunked-streaming parallel-range path. `HasherCoordinator.drainContiguousLocked` (`Sources/SwiftAcervo/AcervoDownloader.swift:1280`) assumed sparse-file reads return short reads — on APFS they return full-length zeros. Test F (the test that would have caught this) was inverted to suppress the production bug instead of fixing it.

**This iteration's job**: rebuild the parallel-range path on a correct foundation, restore the out-of-order delivery test on CI, and tighten CI hygiene so a similar bug-papering never lands again.

**Hard constraints from the user**:
1. Fix the hashing problem with a design that does not rely on filesystem behavior.
2. Keep sorties small enough to not exhaust agent context windows.
3. Long-running operations (live `acervo ship` CDN uploads) MUST run in the background with scheduled status checks — never block the agent.
4. Bias against flaky tests. Forbidden: `Thread.sleep`, `Task.sleep` as the only synchronization, live network calls, `DispatchSemaphore` gating in mocks (caused libdispatch dispose crashes in iteration 01), env-var-only test gating.
5. Performance tests live in `SwiftAcervo-Performance.xctestplan`. Every other test — unit, integration, parallel-range correctness — MUST be on `SwiftAcervo-macOS.xctestplan` / `SwiftAcervo-iOS.xctestplan` so CI gates on it.

**Hard rule for sortie agents** (carry into all dispatch prompts):
> If a test you are writing surfaces a real production bug, STOP. Report `PARTIAL` with the bug location and a recommended fix. Do not modify the test to make the bug invisible. This is what doomed iteration 01.

---

## Salvage Inventory (state at the start of this mission)

| Item | Status | Source |
|------|--------|--------|
| Slug registry (manifest schema, slug-keyed availability / ensureAvailable / deleteModel, `acervo ship --spec` dry-run) | Complete, keep | `mission/quartermaster-torrent/01` commits `e836747`…`bc7e89d` |
| Delegate-driven download path (single-request) | Sound, keep | `ea6d23f` |
| `URLRequest.assumesHTTP3Capable` per-request capability | Sound, keep | `ea6d23f` |
| `streamFlushSize` constant | Sound, keep | `ea6d23f` |
| Redirect-rejection + resume CI tests (StreamingChunkingTests B/C/D/E) | Sound, keep | `460f580` |
| `make test-perf` Makefile target + perf test plan scaffolding | Sound, keep | `460f580` |
| `PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, `runRangeSubTask` | Bug-bearing, DELETE | `ea6d23f` |
| `parallelRangeThreshold`, `parallelRangeCount` constants | No-callers after delete, DELETE | `ea6d23f` |
| `SerialRangeURLProtocol` (masks the bug) | DELETE | `460f580` |
| `StreamingPerformanceTests` Tests F / H / I (depend on broken design) | DELETE | `460f580` |
| `withKnownIssue` wraps in `AcervoToolTests/CDNManifestFetchTests` | Live until CDN data migration completes | `e836747` |
| `acervo ship --spec` live mode (multi-component upload loop) | Missing — only `--dry-run` works | iteration 01 S5 gap |
| CDN manifests for `pixart-sigma-xl`, `flux2-klein-4b`, `flux2-klein-9b` | Lack new slug-registry fields | iteration 01 deferred S6 |

---

## Open Questions & Missing Documentation (Pass 4 — refine-questions)

This pass catalogues every vague criterion, undefined symbol, or unresolved choice found in the plan. Items marked **AUTO-RESOLVED** have been patched inline (see the cited sortie). Items marked **NEEDS USER** are still blocking and must be answered before `start`.

### Auto-resolved (patched inline based on iteration-01 brief + current source)

| ID | Sortie | Original issue | Resolution applied |
|----|--------|----------------|--------------------|
| Q1 | CSR-1 task 5 | "If `StreamingPerformanceTests.swift` contains a wall-clock throughput test for the single-request path (Test A …), keep it." Conditional. | Verified `wallClockMeasurement_256MB` exists at `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift:437`. Patched to "Keep Test A (`wallClockMeasurement_256MB`, line 437)." |
| Q2 | CSR-2 + CSR-4 | `hashCallCount` invariant was ambiguous ("`ceil(fileSize / chunkSize)`" with no `chunkSize` defined). | Redefined as "count of `drainContiguousHashedBytes` invocations that advanced `hashedThrough`". CSR-4 Test 2 asserts `hashCallCount <= 2 * parallelRangeCount` (= 8) — bounded by drain attempts, NOT byte count. |
| Q3 | CSR-3 task 6 | "Add a focused integration test … (single test, CI plan)" — no file or test name. | Patched: add test `resume_parallel_recoversCorrectSHA` to `Tests/SwiftAcervoTests/StreamingChunkingTests.swift` (existing CI-plan file). |
| Q4 | CSR-4 task 3 | "Force `parallelRangeThreshold` low enough (via a test-only init parameter on `AcervoDownloader` or a small dedicated downloader instance)" — choice presented. | Picked option B: construct a dedicated `AcervoDownloader` instance per test with low threshold via a `#if DEBUG` test-only init. Less invasive than a public-API init parameter. |
| Q5 | CSR-5 task 3 | "Empirically-calibrated ceiling" — no calibration method. | Patched: run the test 5 times locally, record the median wall-clock time `T`, set the ceiling to `T * 2`. Document `T` and the multiplier in the test docstring. |
| Q6 | CIH-1 / CIH-2 | References `docs/incomplete/quartermaster-torrent-02/` which does not exist. | Patched: each sortie creates the directory if missing as its first task. |
| Q7 | CIH-2 task 3 | "Use `jq` or a small Swift script." Choice. | Picked `jq`: already universally available on macOS-26 runners and developer machines, no Swift compilation needed. |
| Q8 | CIH-2 entry criteria | "CSR-4 `COMPLETED`" — but the work-unit table places ci-hygiene at layer 0/1 with no chunked-streaming-rebuild dependency. Genuine contradiction. | Patched: dropped the CSR-4 dependency. The shape gate validates "no test class except `StreamingPerformanceTests` is in `skippedTests`" — that invariant is independent of whether `ParallelRangeCorrectnessTests` exists yet. |
| Q9 | DC-1 task 3 | "use existing in-process mocks for the HuggingFace and R2 clients" — assumed to exist. | Verified: `Tests/AcervoToolTests/ShipDryRunTests.swift:148+` already exercises `--spec --dry-run` end-to-end without live network. Patched: instruct agent to mirror that test's mock-staging pattern. |
| Q10 | DC-2 task 3 | flux2-klein-4b spec JSON contents were undefined. | **Revised 2026-05-20 from on-disk audit of `black-forest-labs_FLUX.2-klein-4B/`.** The model is a SINGLE HuggingFace repo with `transformer/`, `vae/`, `text_encoder/`, `tokenizer/`, `scheduler/` as **subfolders inside that one repo**, not three separate repos. The original 3-component extrapolation from `ShipDryRunTests.swift:160–164` was wrong on two counts: (a) `google/t5-v1_1-xxl` is FLUX.1's text encoder; FLUX.2 uses Qwen3 (`text_encoder/config.json` shows `Qwen3ForCausalLM`), and (b) there is no separate `black-forest-labs/FLUX.2-vae` repo — the VAE is `vae/` inside the main repo. Corrected spec: `{modelId: "flux2-klein-4b", primaryRepo: "black-forest-labs/FLUX.2-klein-4B", components: ["black-forest-labs/FLUX.2-klein-4B"]}`. The manifest must enumerate nested file paths (`transformer/diffusion_pytorch_model.safetensors`, `vae/config.json`, `text_encoder/model-00001-of-00002.safetensors`, etc.). See REQUIREMENTS.md §1.2's nested-path clause. |
| Q11 | Summary table | Layers 2/3/4 mis-numbered (DC-1 depends on CSR-3-layer-2 so DC-1 must be layer 3, etc.). | Patched: DC-1 → layer 3, DC-2 → layer 4, DC-3 → layer 5. Sortie headings updated. |
| Q12 | Mission Context, "Starting point" | "predecessor brief recommendation: `beeb091`" vs "alternative: `a12ed10`". | Resolved per brief: `a12ed10` (current `mission/quartermaster-torrent/01` HEAD) keeps the salvaged slug-registry intact and matches the Salvage Inventory. `beeb091` would require cherry-picking five commits the brief already greenlit as KEEP. Patched: `a12ed10` is the starting point. |

### Needs user input (BLOCKING — answer before `start`)

| ID | Sortie | Question | Why I can't resolve it |
|----|--------|----------|------------------------|
| Q-NU-1 | DC-2 task 2 | What is the HF repo string (and component count) for the `pixart-sigma-xl` slug? **RESOLVED 2026-05-20.** Per the operator's canonical principle ("HF is source of truth; CDN is a repeater + cache" — now in CLAUDE.md Critical Rules), `pixart-sigma-xl` mirrors its HF source `PixArt-alpha/PixArt-Sigma-XL-2-1024-MS` directly: a **single diffusers repo** with subfolders `scheduler/`, `text_encoder/` (T5-XXL sharded, ~19 GB), `tokenizer/`, `transformer/` (~2.4 GB), `vae/` (~334 MB), + top-level `model_index.json` (verified via `hf models ls -R`). Spec: `{modelId: "pixart-sigma-xl", primaryRepo: "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS", components: ["PixArt-alpha/PixArt-Sigma-XL-2-1024-MS"]}`. The legacy three int4-quantized CDN repos (`t5-xxl-encoder-int4`, `sdxl-vae-decoder-fp16`, `pixart-sigma-xl-dit-int4`) are deprecated and being retired — see "Out-of-scope / follow-up" below. | **RESOLVED.** |
| Q-NU-2 | DC-2 task 3 | Confirm `flux2-klein-9b` component list. **CONFIRMED 2026-05-20 via `hf models ls black-forest-labs/FLUX.2-klein-9B`:** single repo, subfolders `scheduler/`, `text_encoder/`, `tokenizer/`, `transformer/`, `vae/` + top-level `model_index.json` + `flux-2-klein-9b.safetensors` (18.16 GB). Same packaging as 4B. Spec: `{modelId: "flux2-klein-9b", primaryRepo: "black-forest-labs/FLUX.2-klein-9B", components: ["black-forest-labs/FLUX.2-klein-9B"]}`. | **RESOLVED.** No further operator input needed for the 9B shape. |
| Q-NU-3 | DC-2 exit criteria | What string in the `acervo ship` log indicates successful per-component upload? The exit asserts "Three log files exist … showing successful uploads" but doesn't name a grep pattern. | I have not yet read `ShipCommand.swift`'s success-emit line. Easy to resolve at execution time, but currently un-machine-verifiable. Either: agent reads ShipCommand first and locks down the pattern, OR operator names the canonical success line. |

### Information items (no action required, just documented)

- **CSR-1 task 1** "any private helpers used only by them" — vague but acceptable: the explicit symbol list (`PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, `runRangeSubTask`) is grep-anchored, and the final exit-criterion grep block enforces zero post-surgery callers.
- **CSR-1 task 3** "the path that exists before the parallel-range branch is taken" — the agent can grep `runParallelRangeStream` callsite to identify the branch. Acceptable.
- **Cross-cutting rule 4 (`acervo-download-ship` skill)** — verified the skill exists in this environment (visible in the skills list). DC-2 can dispatch through it.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| chunked-streaming-rebuild | `Sources/SwiftAcervo/`, `Tests/SwiftAcervoTests/` | 5 | 0 → 1 → 2 → 3 | none (internal sequence) |
| ci-hygiene | `.swiftpm/`, `.github/workflows/`, `Makefile` | 2 | 0 → 1 | none |
| deferred-cleanup | `Sources/AcervoTool/`, `Tests/AcervoToolTests/`, CDN | 3 | 2 → 3 → 4 | chunked-streaming-rebuild/CSR-3 |

**Layering rule**: Sorties in layer N may dispatch in parallel; sorties in layer N+1 wait until every layer-N sortie they depend on is `COMPLETED`.

---

## Work Unit: chunked-streaming-rebuild

Goal: rebuild the parallel-range download path so SHA-256 verification is correct regardless of range completion order, with a deterministic CI test that exercises out-of-order delivery.

### Sortie CSR-1: Surgery — Remove broken parallel-range code and dependent tests

**Layer**: 0
**Recommended model**: sonnet (mechanical, no design judgment)

**Entry criteria**:
- [ ] First sortie in the work unit — no prerequisites beyond the mission branch existing.
- [ ] Working tree clean.

**Tasks**:
1. Remove these symbols from `Sources/SwiftAcervo/AcervoDownloader.swift`: `PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, `runRangeSubTask`, plus any private helpers used only by them.
2. Remove the constants `parallelRangeThreshold` and `parallelRangeCount` (and any references). Keep `streamFlushSize`.
3. Restore the streaming download to the single-request delegate-driven path (the path that exists before the parallel-range branch is taken). Keep the HTTP/3 per-request capability and the `waitsForConnectivity = false` rationale comment intact.
4. Delete `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` Tests F, G (parallel-range-throughput), H (parallel-range-stress), and I (parallel-range-override). Delete `SerialRangeURLProtocol` and any helpers used only by those tests.
5. Keep Test A (`wallClockMeasurement_256MB`, currently at `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift:437` — verified present at plan-refinement time). It's the single-request wall-clock test and is unaffected by the parallel-range surgery.
6. Keep `Tests/SwiftAcervoTests/StreamingChunkingTests.swift` (Tests B/C/D/E) untouched.

**Exit criteria**:
- [ ] `make build` exits 0.
- [ ] `make test` exits 0 (CI plan green; no parallel-range code remains to break).
- [ ] `grep -nE 'PartFileWriter|HasherCoordinator|runParallelRangeStream|runRangeSubTask|SerialRangeURLProtocol|parallelRangeThreshold|parallelRangeCount' Sources Tests` returns no matches.
- [ ] `Sources/SwiftAcervo/AcervoDownloader.swift` still references `streamFlushSize` and `assumesHTTP3Capable`.
- [ ] Single commit on the mission branch with message `surgery(downloader): remove iteration-01 parallel-range types and inverted tests`.

**Hand-off note for CSR-2**: After this sortie, `AcervoDownloader` performs single-request streaming only. CSR-2 introduces the new `HasherCoordinator` as a pure library type with no integration into `AcervoDownloader` yet; CSR-3 will rewire the downloader.

---

### Sortie CSR-2: New `HasherCoordinator` with explicit written-range intervals + unit tests

**Layer**: 1
**Recommended model**: opus (correctness-critical; this is the design that failed last time)

**Entry criteria**:
- [ ] CSR-1 `COMPLETED`.
- [ ] `grep -n 'HasherCoordinator' Sources` returns no matches (verifies surgery).

**Tasks**:
1. Create `Sources/SwiftAcervo/HasherCoordinator.swift` (new file, not folded into `AcervoDownloader.swift`). Public API:
   - `init(expectedTotalBytes: Int64, partFileHandle: FileHandle)`
   - `func recordWrittenRange(start: Int64, end: Int64) async` — records that bytes in `[start, end)` are now on disk. Internally merges into a sorted list of half-open intervals.
   - `func drainContiguousHashedBytes() async throws -> Int64` — reads from `hashedThrough` up to the end of the leading interval that contains `hashedThrough`, feeds those bytes through SHA-256, advances `hashedThrough`. Returns the new `hashedThrough`.
   - `func finalize() async throws -> Data` — drains anything remaining; returns the SHA-256 digest. Throws if `hashedThrough != expectedTotalBytes`.
2. NEVER use filesystem behavior (short reads, `SEEK_HOLE`, file size) to detect contiguity. The interval list is the sole source of truth.
3. Make the type an `actor` so concurrent `recordWrittenRange` calls from per-range download tasks are serialized.
4. Add `Tests/SwiftAcervoTests/HasherCoordinatorTests.swift` (CI plan, not perf plan). Deterministic, no real I/O races — write a small fixture file once per test and read from it. Cover:
   - Single contiguous range produces the same digest as `SHA256.hash(data:)` on the source bytes.
   - Four ranges arriving in ascending order produce the same digest.
   - Four ranges arriving in reverse order produce the same digest.
   - Four ranges arriving in a deliberate scramble (e.g. `[2, 0, 3, 1]`) produce the same digest.
   - Overlapping ranges (range B starts before range A ends) merge correctly and do not double-hash.
   - `finalize()` throws if the union of recorded intervals does not cover `[0, expectedTotalBytes)`.
   - Interval merge handles adjacency at both endpoints (range ends at 100, next starts at 100).
5. Expose a test-only `hashCallCount` counter (`internal var` on the actor, reachable via `@testable import`). **Precise semantic**: increment `hashCallCount` once per invocation of `drainContiguousHashedBytes()` that advances `hashedThrough` (i.e. that actually fed bytes through SHA-256). Drains that find nothing new MUST NOT increment. This is the deterministic signal CSR-4 Test 2 asserts on: `hashCallCount <= 2 * parallelRangeCount` (the upper bound is "each range triggers at most one drain that makes progress, plus a final drain"). The iteration-01 regression would have shown `hashCallCount == expectedTotalBytes` (byte-at-a-time).

**Exit criteria**:
- [ ] `Sources/SwiftAcervo/HasherCoordinator.swift` exists and compiles.
- [ ] `Tests/SwiftAcervoTests/HasherCoordinatorTests.swift` exists with the seven scenarios above.
- [ ] `make test` exits 0 with the new tests included.
- [ ] All seven scenarios use deterministic synchronization (`await` on the actor — no `Task.sleep`, no `DispatchSemaphore`).
- [ ] `grep -nE 'SEEK_HOLE|lseek|sparse' Sources/SwiftAcervo/HasherCoordinator.swift` returns no matches.
- [ ] `grep -nE 'sleep|DispatchSemaphore' Tests/SwiftAcervoTests/HasherCoordinatorTests.swift` returns no matches.
- [ ] Single commit `feat(hasher): explicit written-range interval HasherCoordinator + deterministic unit tests`.

**Hand-off note for CSR-3**: `HasherCoordinator` is decoupled — CSR-3 wires it into the new `PartFileWriter` and `runParallelRangeStream`. The `hashCallCount` seam is the deterministic signal CSR-4 will assert on.

---

### Sortie CSR-3: Rewire parallel-range streaming using new `HasherCoordinator`

**Layer**: 2
**Recommended model**: opus (integration with active concurrency)

**Entry criteria**:
- [ ] CSR-2 `COMPLETED`.
- [ ] `HasherCoordinator` test suite green.

**Tasks**:
1. Add `PartFileWriter` to `Sources/SwiftAcervo/AcervoDownloader.swift` (or a new file `Sources/SwiftAcervo/PartFileWriter.swift`, agent's choice). API:
   - `init(url: URL, totalBytes: Int64) throws` — opens (or creates and pre-allocates) the `.part` file.
   - `func write(_ data: Data, at offset: Int64) async throws -> Range<Int64>` — writes at the offset; returns the actual `[start, end)` range written (callers will pass the returned range to `HasherCoordinator.recordWrittenRange`).
   - Must be an `actor` for write serialization across range tasks.
2. Re-introduce `parallelRangeThreshold` and `parallelRangeCount` constants in `AcervoDownloader.swift` (defaults from iteration 01: threshold = 64 MiB, count = 4).
3. Implement `runParallelRangeStream(url:totalBytes:expectedSHA256:)` that:
   - Splits `[0, totalBytes)` into `parallelRangeCount` contiguous ranges.
   - Launches one `URLSessionDataTask` per range with an appropriate `Range:` header. Each task writes through `PartFileWriter.write(_:at:)` and reports completion to a single `HasherCoordinator` via `recordWrittenRange`.
   - After every successful write, calls `HasherCoordinator.drainContiguousHashedBytes()` (the actor no-ops if nothing new is contiguous).
   - After all tasks complete, calls `HasherCoordinator.finalize()` and compares to `expectedSHA256`. Mismatch → throw `AcervoError.sha256Mismatch`.
4. `streamDownloadFile` chooses the parallel path when `totalBytes >= parallelRangeThreshold`, falls back to single-request otherwise.
5. Preserve `SecureDownloadSession`'s redirect rejection — verify by re-running the existing redirect test from `StreamingChunkingTests`.
6. Preserve resume — when a `.part` file exists with N bytes, `runParallelRangeStream` must seed the `HasherCoordinator` with `recordWrittenRange(start: 0, end: N)` and skip re-downloading those bytes. Add the test `resume_parallel_recoversCorrectSHA` to `Tests/SwiftAcervoTests/StreamingChunkingTests.swift` (existing CI-plan file). The test pre-creates a `.part` file with a known prefix, runs the parallel-range path against an in-process URLProtocol, and asserts the final file's SHA equals the expected full SHA. No sleeps, no semaphores.

**Exit criteria**:
- [ ] `make build` exits 0.
- [ ] `make test` exits 0. Specifically: redirect-rejection test, existing resume tests in `StreamingChunkingTests`, the seven `HasherCoordinatorTests`, and the new resume+parallel test are all green.
- [ ] `Sources/SwiftAcervo/AcervoDownloader.swift` references both `PartFileWriter` and `HasherCoordinator`.
- [ ] No symbol named `SerialRangeURLProtocol` exists anywhere.
- [ ] `grep -nE 'sparse|short read' Sources/SwiftAcervo/AcervoDownloader.swift` returns no matches in comments suggesting contiguity is inferred from filesystem behavior.
- [ ] Single commit `feat(downloader): parallel-range streaming wired through interval-tracking HasherCoordinator`.

**Hand-off note for CSR-4**: The `hashCallCount` test seam exposed via `HasherCoordinator` from CSR-2 is the deterministic signal CSR-4's integration test asserts on, replacing iteration 01's wall-clock proxy.

---

### Sortie CSR-4: Deterministic out-of-order parallel-range correctness test (on CI plan)

**Layer**: 3
**Recommended model**: sonnet (test-authoring; spec is precise)

**Entry criteria**:
- [ ] CSR-3 `COMPLETED`.

**Tasks**:
1. Add `Tests/SwiftAcervoTests/ParallelRangeCorrectnessTests.swift` (new file, NOT in `StreamingPerformanceTests.swift`). This file MUST be on the CI test plan (`SwiftAcervo-macOS.xctestplan` / `SwiftAcervo-iOS.xctestplan`) — verify by inspecting the test plan JSON; the file must not appear under any `skippedTests` entry.
2. Build a `OutOfOrderRangeURLProtocol` mock that delivers range responses in a **deliberately scrambled order** (`[2, 0, 3, 1]`). Synchronization rule: use `DispatchQueue.global(qos: .userInitiated).async` to deliver each response. Absolute ordering between deliveries is enforced by **only initiating delivery N+1 after delivery N's `urlProtocol(_:didFinishLoading:)` has returned** — use `CheckedContinuation` resumed from the prior delivery's completion callback. NO `DispatchSemaphore`, NO `Thread.sleep`, NO `Task.sleep`.
3. Test 1 — `parallelRange_outOfOrderDelivery_producesCorrectSHA`: Use a 16 MiB synthetic file with a known SHA. Construct a dedicated `AcervoDownloader` instance via a `#if DEBUG` test-only init that accepts a low `parallelRangeThreshold` (e.g. 1 MiB) so 4 ranges fire on the 16 MiB fixture. Public-API callers see no change. Assert downloaded file matches the known SHA byte-for-byte.
4. Test 2 — `parallelRange_outOfOrderDelivery_boundsHasherInvocations`: Use the `hashCallCount` test seam from CSR-2 to assert `hashCallCount <= 2 * parallelRangeCount` (= 8 on this fixture). The intent: prove the hasher is driven by completed *ranges*, not by *bytes*. Iteration-01's regression would have surfaced as `hashCallCount == 16 * 1024 * 1024`.
5. Test 3 — `parallelRange_resumeFromPart_underOutOfOrder_producesCorrectSHA`: Pre-create a `.part` file with the first 4 MiB of the synthetic. Force out-of-order completion of the remaining 3 ranges. Assert final SHA matches.
6. Whole file must run in under 5 seconds on a clean CI runner. If any test exceeds 5s, reduce the synthetic file size or chunk count rather than adding sleep-based gating.

**Exit criteria**:
- [ ] `Tests/SwiftAcervoTests/ParallelRangeCorrectnessTests.swift` exists with the three tests above.
- [ ] `make test` exits 0; all three tests are reported as run (not skipped).
- [ ] `grep -nE 'sleep|DispatchSemaphore' Tests/SwiftAcervoTests/ParallelRangeCorrectnessTests.swift` returns no matches.
- [ ] `cat .swiftpm/xcode/xcshareddata/xctestplans/SwiftAcervo-macOS.xctestplan` does NOT list `ParallelRangeCorrectnessTests` under any `skippedTests` block.
- [ ] `time xcodebuild test -only-testing:SwiftAcervoTests/ParallelRangeCorrectnessTests …` reports under 5 seconds (record actual time in commit body).
- [ ] Single commit `test(parallel-range): deterministic out-of-order correctness on CI plan`.

---

### Sortie CSR-5: Wall-clock throughput test (Performance plan only)

**Layer**: 3
**Recommended model**: sonnet

**Entry criteria**:
- [ ] CSR-3 `COMPLETED`.

**Tasks**:
1. Add or update `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` with a single wall-clock test `parallelRange_256MB_synthetic_throughput`.
2. Use an in-process `URLProtocol` mock (NOT `OutOfOrderRangeURLProtocol`) that delivers ranges in natural arrival order with no artificial delays.
3. Assert wall-clock time below an empirically-calibrated ceiling. **Calibration procedure**: run the test 5 times on the developer's machine, record the median wall-clock time `T_median` in seconds, set the ceiling to `T_median * 2`. Record `T_median`, the 5 raw samples, the chosen ceiling, and the machine model in the test docstring. `XCTSkip` (not failure) is acceptable on slow hardware (perf plan, not CI).
4. The file MUST stay listed under `skippedTests` in `SwiftAcervo-macOS.xctestplan` and `SwiftAcervo-iOS.xctestplan` — it runs only via `make test-perf`.
5. Document the perf-plan invocation in `Docs/BUILD_AND_TEST.md`: `make test-perf` runs perf tests in the foreground; for long suites, capture output to a log file and use `ScheduleWakeup` for check-backs from a supervising agent.

**Exit criteria**:
- [ ] `make test-perf` runs `parallelRange_256MB_synthetic_throughput` and exits 0 on the developer's local machine (record runtime in commit body).
- [ ] `make test` (CI plan) does NOT run the perf test (verify via `xcodebuild test` output listing).
- [ ] `Docs/BUILD_AND_TEST.md` documents `make test-perf` and the background-invocation pattern.
- [ ] Single commit `test(perf): 256 MB parallel-range throughput on Performance test plan`.

---

## Work Unit: ci-hygiene

Goal: enforce "all non-perf tests run in CI" structurally, not by convention.

### Sortie CIH-1: Audit test-plan placement — every non-perf test on CI plan

**Layer**: 0
**Recommended model**: sonnet

**Entry criteria**:
- [ ] None (can run in parallel with CSR-1).

**Tasks**:
1. List every test class under `Tests/`. For each, determine whether it currently runs under `SwiftAcervo-macOS.xctestplan` and `SwiftAcervo-iOS.xctestplan`.
2. Confirm the ONLY entry under `skippedTests` on the CI plans is `StreamingPerformanceTests`.
3. Confirm `SwiftAcervo-Performance.xctestplan`'s `selectedTests` lists ONLY `StreamingPerformanceTests`.
4. If any test class outside `StreamingPerformanceTests` is excluded from CI for any reason, list it in `docs/incomplete/quartermaster-torrent-02/CI_AUDIT.md` with the reason. The audit doc is a deliverable even if no exclusions are found (then it documents the green state). **Create `docs/incomplete/quartermaster-torrent-02/` if it does not exist as the first task of this sortie.**
5. Do NOT modify any test plan in this sortie — that is CIH-2's job. This sortie is read-only audit.

**Exit criteria**:
- [ ] `docs/incomplete/quartermaster-torrent-02/CI_AUDIT.md` exists.
- [ ] The audit lists every test class with its plan membership.
- [ ] Single commit `docs(ci-audit): test-plan placement audit for iteration 02`.

---

### Sortie CIH-2: CI workflow + Makefile explicitly target CI test plans; add shape gate

**Layer**: 1
**Recommended model**: sonnet

**Entry criteria**:
- [ ] CIH-1 `COMPLETED`.

**Tasks**:
1. Inspect `.github/workflows/*.yml`. For every workflow that runs tests, verify the `xcodebuild test` invocation uses `-testPlan SwiftAcervo-macOS` (or `-iOS`), NOT `-testPlan SwiftAcervo-Performance` and NOT plan-less.
2. Inspect `Makefile`. Verify `make test` uses the CI plan and `make test-perf` uses the Performance plan. Fix either if wrong.
3. Add a Makefile target `test-ci-shape` (lightweight check, no tests run) that fails if either CI test plan lists a `skippedTests` entry other than `StreamingPerformanceTests`. **Use `jq`** (already universally available on macOS-26 runners): e.g. `jq -e '.testTargets[].skippedTests // [] | map(select(. != "StreamingPerformanceTests")) | length == 0' <plan>`.
4. Wire `test-ci-shape` into CI as a fast pre-test job so the structural invariant is gated.

**Exit criteria**:
- [ ] `make test-ci-shape` exits 0 on the current branch.
- [ ] `make test-ci-shape` exits non-zero if a test class other than `StreamingPerformanceTests` is added to `skippedTests` (verify with a temp local edit and revert; record the verification in the commit body).
- [ ] CI workflow runs `test-ci-shape` as a job (visible in `.github/workflows/*.yml`).
- [ ] Single commit `chore(ci): gate test-plan shape; CI runs all non-perf tests`.

---

## Work Unit: deferred-cleanup

Goal: finish the iteration-01 deferred S6 work — live `acervo ship --spec` mode and CDN manifest re-upload — so `withKnownIssue` wraps can come off.

### Sortie DC-1: Extend `acervo ship --spec` live mode to iterate components

**Layer**: 3
**Recommended model**: sonnet

**Entry criteria**:
- [ ] CSR-3 `COMPLETED` (manifest schema is stable through this iteration).

**Tasks**:
1. Open `Sources/acervo/ShipCommand.swift` (verified location at plan-refinement time; `runHuggingFaceDownload` is the private method at line 570; the spec-iteration code path is around lines 538–549). Today the live path calls `runHuggingFaceDownload(into:modelId:)` once with a single `modelId` (line 253); the `--spec` path only works under `--dry-run`.
2. Extend the live path to read `spec.components` from the spec JSON, iterate components, and run the full download → manifest → verify → upload pipeline once per component, sharing the `modelId` slug across them.
3. Add `Tests/AcervoToolTests/ShipSpecLiveTests.swift` (CI plan) that mocks the HF + R2 layers and asserts:
   - **Multi-component case**: given a spec with 3 components, the live path issues 3 downloads, generates 3 manifests, and 3 uploads, all with the same `modelId` field populated.
   - **Single-component-with-subfolders case** (added 2026-05-20 to cover FLUX.2 Klein): given a spec with one component whose staged tree contains subfolders (e.g. `transformer/diffusion_pytorch_model.safetensors`, `vae/config.json`), the generated manifest's `files[].path` values include the nested paths and the upload preserves the directory structure. Also assert HuggingFace cruft (`.cache/**`, `*.lock`, `*.metadata`, `.gitattributes`, `.DS_Store`) is excluded from both the manifest and the upload.
   **Mirror the staging pattern from `Tests/AcervoToolTests/ShipDryRunTests.swift` (the `specDryRun` test at line 148)** — same `makeComponentStagingDir` fixtures, same `AcervoCLI.parseAsRoot` invocation, same JSON spec shape. The HF and R2 mocks already used by `ShipDryRunTests` and `CDNUploaderTests`/`HuggingFaceClientTests` are the in-process mock layer.
4. Do NOT touch live CDN credentials or networks in tests.

**Exit criteria**:
- [ ] `acervo ship --spec components.json` (live, not `--dry-run`) iterates components in a unit-tested code path.
- [ ] `Tests/AcervoToolTests/ShipSpecLiveTests.swift` exists and is on the CI plan.
- [ ] Single-component-with-subfolders test passes: manifest enumerates nested paths; HF cruft excluded.
- [ ] `make test` exits 0.
- [ ] Single commit `feat(acervo-ship): --spec live mode iterates components and walks subfolders`.

**Hand-off note for DC-2**: With this in place, an operator can run `acervo ship --spec <spec.json>` against the live R2 to re-upload either (a) multi-repo models like pixart-sigma-xl or (b) single-repo-with-subfolders models like flux2-klein-4b. The subfolder support is what makes FLUX.2 shippable at all.

---

### Sortie DC-2: Live CDN re-upload of three Vinetas manifests (BACKGROUND, scheduled check-ins)

**Layer**: 4
**Recommended model**: sonnet (orchestration only; the long process is the `acervo-download-ship` skill)

**Entry criteria**:
- [ ] DC-1 `COMPLETED`.
- [ ] Operator (user) has confirmed credentials are present and the live R2 bucket is the intended target.
- [ ] Q-NU-1, Q-NU-2 both RESOLVED (see "Open Questions" — both confirmed via `hf models ls` on 2026-05-20 plus the "HF is source of truth" rule). Q-NU-3 (ShipCommand success grep pattern) resolved inline in task 1 below.

**Tasks**:
1. **DO NOT block the agent on the upload.** Use the `acervo-download-ship` skill to launch each `acervo ship` invocation as a detached background process with output captured to a log file under `docs/incomplete/quartermaster-torrent-02/ship-logs/` (create the directory if missing). Before kicking off the first ship, grep `Sources/acervo/ShipCommand.swift` for the upload-complete success emit and record the chosen grep pattern in `docs/incomplete/quartermaster-torrent-02/ship-logs/SUCCESS_PATTERN.md` (this is Q-NU-3).
2. Models to ship (one `--spec` invocation each; the skill enforces single-download-at-a-time). All three are single-component HF source repos with subfolders, so the DC-1 "single-component-with-subfolders" code path is what runs:
   - `pixart-sigma-xl`: `acervo ship --spec specs/pixart-sigma-xl.json`
   - `flux2-klein-4b`: `acervo ship --spec specs/flux2-klein-4b.json`
   - `flux2-klein-9b`: `acervo ship --spec specs/flux2-klein-9b.json`
3. Author the component spec JSONs under `docs/incomplete/quartermaster-torrent-02/specs/` (path verified at refinement time — no prior convention exists in-tree). Spec schema (derived from `Tests/AcervoToolTests/ShipDryRunTests.swift:160–172`): top-level JSON object with `modelId`, `primaryRepo`, `components` (array of HF repo strings). **flux2-klein-4b spec contents** (corrected 2026-05-20 from on-disk audit — see Q10 in the auto-resolved table for evidence):
   ```json
   {
     "modelId": "flux2-klein-4b",
     "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
     "components": [
       "black-forest-labs/FLUX.2-klein-4B"
     ]
   }
   ```
   The single-component shape is correct: FLUX.2 Klein ships `transformer/`, `vae/`, `text_encoder/`, `tokenizer/`, `scheduler/` as subfolders **inside one HF repo**, and the manifest enumerates those nested paths (`transformer/diffusion_pytorch_model.safetensors`, etc.). The manifest generator must walk subdirectories of the staged repo and skip HuggingFace cruft (`.cache/`, `.gitattributes`, `.DS_Store`, `*.lock`, `*.metadata`) — see REQUIREMENTS.md §1.2.
   **flux2-klein-9b spec** (confirmed 2026-05-20 via `hf models ls`):
   ```json
   {
     "modelId": "flux2-klein-9b",
     "primaryRepo": "black-forest-labs/FLUX.2-klein-9B",
     "components": ["black-forest-labs/FLUX.2-klein-9B"]
   }
   ```
   **pixart-sigma-xl spec** (per "HF is source of truth" — see Q-NU-1):
   ```json
   {
     "modelId": "pixart-sigma-xl",
     "primaryRepo": "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS",
     "components": ["PixArt-alpha/PixArt-Sigma-XL-2-1024-MS"]
   }
   ```
4. Between ships, use `ScheduleWakeup` with `delaySeconds` in the 1200–1800 range (long enough to amortize the prompt-cache miss; the `acervo-download-ship` skill notifies on completion). Do NOT poll in tight loops.
5. After all three ships succeed (per their log files), fetch the live manifests via `curl` (or the existing `AcervoTool` fetch path) and verify each has non-empty `modelId`, `primaryRepo`, and `components` fields.

**Exit criteria**:
- [ ] Three log files exist under `docs/incomplete/quartermaster-torrent-02/ship-logs/`. Each log's last 30 lines confirm success — agent must identify the canonical success line emitted by `ShipCommand` on the first invocation (read `Sources/acervo/ShipCommand.swift` for the upload-complete emit) and record the chosen grep pattern in `docs/incomplete/quartermaster-torrent-02/ship-logs/SUCCESS_PATTERN.md`. Subsequent ships are verified by that pattern. (See Q-NU-3.)
- [ ] `curl <cdn>/pixart-sigma-xl/manifest.json` returns a manifest with `modelId == "pixart-sigma-xl"`.
- [ ] Same for `flux2-klein-4b` and `flux2-klein-9b`, each with the full component list populated.
- [ ] No code commits required on the SwiftAcervo branch from this sortie EXCEPT the spec JSONs and log files; the CDN upload itself is the deliverable.

**Hand-off note for DC-3**: With live manifests carrying the new fields, the `withKnownIssue` wraps in `CDNManifestFetchTests` can come off.

**Out of scope / follow-up**:
- **Retire the legacy int4-quantized PixArt CDN repos.** `t5-xxl-encoder-int4`, `sdxl-vae-decoder-fp16`, `pixart-sigma-xl-dit-int4` were a CDN-side re-pack of a single HF source repo and predate the "HF is source of truth" rule (CLAUDE.md). After DC-2 ships the canonical `pixart-sigma-xl` manifest pointing at `PixArt-alpha/PixArt-Sigma-XL-2-1024-MS`, the three legacy repos should be deprecated (mark in CDN metadata) and eventually removed. Deferred to a separate sortie because the retirement window depends on consumer migration (Vinetas, etc.) which is out-of-scope for this mission.
- **Audit other slugs for similar legacy re-pack mismatches.** PixArt-Sigma-XL is unlikely to be unique. A follow-up audit should walk every slug currently advertised on the CDN, fetch the HF source repo listing, and flag any where the CDN packaging diverges from HF's packaging (re-quantization, repo splits, file renames). Each mismatch is a candidate for retirement-or-rename per the canonical rule.

---

### Sortie DC-3: Remove `withKnownIssue` wraps now that live manifests carry slug fields

**Layer**: 5
**Recommended model**: sonnet

**Entry criteria**:
- [ ] DC-2 `COMPLETED` (live manifests carry the new fields).

**Tasks**:
1. Open `Tests/AcervoToolTests/CDNManifestFetchTests.swift`. Find the two tests wrapped in `withKnownIssue` with the `TODO(slug-registry/S6 — deferred)` annotation.
2. Remove the `withKnownIssue` wrapper from each. Confirm the underlying `try`/`await` calls are present and not double-wrapped.
3. Clean up any SourceKit "no calls to throwing functions occur within 'try' expression" warnings on those tests (iteration-01 carry-forward).
4. Run `make test`. If these tests require live CDN access, document the requirement in the test docstring; if they use mocked CDN URLs, confirm the mocks now carry the new fields.

**Exit criteria**:
- [ ] `grep -n withKnownIssue Tests/AcervoToolTests/CDNManifestFetchTests.swift` returns no matches.
- [ ] `make test` exits 0.
- [ ] No SourceKit warnings on the two affected tests.
- [ ] Single commit `test(cdn-manifest): remove withKnownIssue wraps after live manifest migration`.

---

## Cross-cutting Rules (carry into every sortie dispatch prompt)

1. **No paper-overs.** If a test you are writing surfaces a real production bug, STOP and report `PARTIAL` with the bug location and recommended fix. Do not change the test to mask the bug. *This is what doomed iteration 01.*
2. **No flaky-test patterns.** Forbidden in new tests: `Thread.sleep`, `Task.sleep` as sole synchronization, `DispatchSemaphore` gating inside `URLProtocol` subclasses (caused libdispatch dispose crashes in iteration 01), live network calls, env-var-only gating, unseeded randomness.
3. **CI is the primary gate.** Every test except those in `StreamingPerformanceTests` MUST be on `SwiftAcervo-macOS.xctestplan` / `SwiftAcervo-iOS.xctestplan` and MUST pass under `make test`.
4. **Long processes go to the background.** Anything that takes more than ~60 seconds and is not a test (notably: live `acervo ship`) MUST be dispatched via the `acervo-download-ship` skill or `run_in_background`, with `ScheduleWakeup` (1200–1800s) for check-backs.
5. **Verify named APIs.** If a sortie names a specific Foundation API symbol, the agent must `grep` Foundation headers or cite Apple docs before using it. Iteration 01 burned a sortie on the non-existent `URLSessionConfiguration.assumesHTTP3Capable`.
6. **Filesystem-behavior assumptions require a verification step.** No design may rely on "short read past end of writes" or similar OS behavior without explicit citation to `man 2 read` or a written spike.
7. **Hand-off notes mandatory.** Every sortie report includes explicit hand-off notes naming the next sortie and what it should/shouldn't re-derive.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 3 |
| Total sorties | 10 |
| Layer 0 sorties (parallelizable at start) | 2 (CSR-1, CIH-1) |
| Layer 1 sorties | 2 (CSR-2, CIH-2) |
| Layer 2 sorties | 1 (CSR-3) |
| Layer 3 sorties | 3 (CSR-4, CSR-5, DC-1) |
| Layer 4 sorties | 1 (DC-2) |
| Layer 5 sorties | 1 (DC-3) |
| Dependency structure | layered; two work units parallel at layer 0; deferred-cleanup gated on chunked-streaming-rebuild/CSR-3 |
| Background-dispatched sorties | 1 (DC-2, via `acervo-download-ship` skill) |
| Mission branch (planned) | `mission/quartermaster-torrent/02` |
| Starting point (resolved) | `a12ed10` (current `mission/quartermaster-torrent/01` HEAD; slug-registry already applied — keeps the Salvage Inventory intact, aligns with iteration-01 brief `KEEP` verdict on slug-registry) |
