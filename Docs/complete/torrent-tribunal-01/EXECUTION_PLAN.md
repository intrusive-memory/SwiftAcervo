---
type: execution-plan
feature_name: OPERATION TORRENT TRIBUNAL
starting_point_commit: 15f58681fbe622f0bf2971eaf341470767478f67
mission_branch: mission/torrent-tribunal/01
iteration: 1
state: completed
---

# EXECUTION_PLAN.md — SwiftAcervo Download Performance Suite

Derived from [`REQUIREMENTS-performance.md`](REQUIREMENTS-performance.md) — a local-only,
human-driven performance test suite (`StreamingPerformanceTests`) that measures real
download-to-verified-on-disk throughput across the Acervo CDN path and **never runs in CI**.

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| Performance Suite | `Tests/SwiftAcervoTests/` (+ test plans, Makefile, .gitignore) | 7 | 0–4 | none |

This is a single-project mission. Sorties are layered for dependency gating and parallelism:

| Layer | Sorties | Notes |
|-------|---------|-------|
| 0 | Sortie 1 | Foundation — the gated suite file (skeleton + dropped-metric doc) must exist first |
| 1 | Sortie 2, Sortie 3 | Independent of each other; may run in parallel |
| 2 | Sortie 4, Sortie 5 | Both build on the Sortie 3 measurement core |
| 3 | Sortie 6 | Baseline regression mode — needs Sortie 4's medians |
| 4 | Sortie 7 | Final acceptance — needs everything in place |

---

### Sortie 1: Scaffold the gated performance suite skeleton

**Priority**: 23.0 — highest. Foundation for all six downstream sorties (dep_depth 6); establishes the gate, temp-root helpers, and tier constants every other sortie reuses.

**Entry criteria**:
- [ ] First sortie — no prerequisites
- [ ] `Tests/SwiftAcervoTests/IntegrationTests.swift` exists (reference pattern for helpers/gate)

**Tasks**:
1. Create `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` with `@Suite("StreamingPerformanceTests")`.
2. Add the file-header doc comment mirroring `IntegrationTests.swift`, including the one-line run command from REQUIREMENTS §7 (`ACERVO_PERF_TESTS=1 ACERVO_PERF_NET=wifi xcodebuild test -scheme SwiftAcervo-Package -testPlan SwiftAcervo-Performance -destination 'platform=macOS,arch=arm64'`).
3. Add a private `ACERVO_PERF_TESTS` gate helper (early `return` when unset), mirroring the `INTEGRATION_TESTS` guard pattern.
4. Add labeled tier model-id constants at the top of the suite (§4): `tinyModelId`, `smallModelId`, `largeModelId` — each clearly commented as engineer-swappable, with `largeModelId` carrying a `// TODO: set a published 3GB+ model id` note.
5. Reuse/define `makeTempSharedModels()` and `cleanupTempDirectory(_:)` temp-root helpers (copy the private helpers from `IntegrationTests.swift`).
6. Add exactly one minimal `@Test` method that is fully gated (early-returns with no network call when `ACERVO_PERF_TESTS` is unset), so the file compiles and the class name is real.
7. In the same file-header doc comment, record that `chunkedVsSingleRatio` (REQUIREMENTS §3) is **"not measurable via the public API"** — chunked streaming is always on and single-stream is an internal fallback with no app-facing control, so it falls outside this suite's charter ("if an app can't reach it, this suite doesn't time it", §1.1). (OQ-1 resolution — the metric is dropped, so no chunked-toggle code is ever written.)

**Exit criteria**:
- [ ] File `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` exists and `make build` succeeds
- [ ] `make test` passes and the test log contains **zero** `[PERF]` lines (gate proven to suppress the single placeholder test)
- [ ] `grep -c '@Suite("StreamingPerformanceTests")'` returns 1
- [ ] `grep -c "not measurable via the public API" Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` returns ≥1
- [ ] `grep -nE "AcervoDownloader|S3CDNClient" Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` returns no matches

---

### Sortie 2: Enforce three-mechanism CI isolation

**Priority**: 4.75 — low score but a safety-critical gate. Layer 1, parallel with Sortie 3; dispatch Sortie 3 first when serializing (higher priority), but Sortie 2 must land before any live-network sortie merges to guarantee the suite can never leak into CI.

**Entry criteria**:
- [ ] Sortie 1 complete (`StreamingPerformanceTests` class exists)

**Tasks**:
1. Add `"StreamingPerformanceTests"` to the `skippedTests` array of `.swiftpm/xcode/xcshareddata/xctestplans/SwiftAcervo-macOS.xctestplan` (create the array on the `SwiftAcervoTests` target entry).
2. Add `"StreamingPerformanceTests"` to the `skippedTests` array of `.swiftpm/xcode/xcshareddata/xctestplans/SwiftAcervo-iOS.xctestplan`.
3. Confirm `SwiftAcervo-Performance.xctestplan` does **not** list `StreamingPerformanceTests` in its skip list (it must run there).
4. Confirm no GitHub workflow / Makefile CI target references the `-Performance` plan (`grep -rn "Performance" .github/ Makefile`).

**Exit criteria**:
- [ ] `make test-plan-shape` exits 0 (both CI plans report `OK`)
- [ ] `jq '.testTargets[].skippedTests' SwiftAcervo-Performance.xctestplan` does **not** contain `StreamingPerformanceTests`
- [ ] `grep -rn "Performance" .github/` returns no workflow invocation of the `-Performance` plan

---

### Sortie 3: Implement the four-phase measurement lifecycle and `[PERF]` line

**Priority**: 18.25 — second highest. The measurement core (dep_depth 4, live-CDN risk 3) that Sorties 4, 5, and 6 all build on. Highest-priority sortie in Layer 1.

**Entry criteria**:
- [ ] Sortie 1 complete (suite skeleton, gate, helpers, constants in place)

**Tasks**:
1. Implement the four-phase per-test cycle (§5.0) for the **small** tier: (1) ensure a fresh unique temp `SharedModels` root with no residue for the target model — fail if residue found; (2) start a `ContinuousClock`, call the **public** API (`Acervo.download(...)` / `Acervo.ensureComponentReady(...)` only — no `HuggingFaceClient.downloadRepo`, no `AcervoDownloader`/`S3CDNClient` statics), stop the clock when it returns "ready"; (3) independently validate the on-disk tree (canonical `{org}_{repo}/` layout, `config.json` present, file set matches manifest); (4) `defer`/teardown cleanup of the model dir and temp root.
2. Compute `throughputMBps` (`verifiedBytes / wallClockSeconds / 1_048_576`) and `wallClockSeconds`; compute `timeToFirstByte` from the progress callbacks.
3. Emit one compact, greppable `[PERF] …` summary line per measurement (§3 format: `model=… bytes=… wall=… thru=… ttfb=… cache=cold chunked=… container=temp verified=yes`) via `print`.
4. Record run environment in the summary: date, machine model, macOS version, and the `ACERVO_PERF_NET` descriptor passed by the engineer.

**Exit criteria**:
- [ ] `make build` succeeds and the suite compiles
- [ ] Code review confirms only public `Acervo.*` entry points are called inside the timed window, backed by `grep -nE "HuggingFaceClient|AcervoDownloader|S3CDNClient" Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` returning **no matches**
- [ ] On-disk validation runs **after** the clock stops (verification timing stays inside the clock per §1.1, correctness assertion stays outside)
- [ ] `make test` (no `ACERVO_PERF_TESTS`) still produces **zero** `[PERF]` lines

---

### Sortie 4: Add size tiers and median statistics

**Priority**: 12.25 — high. Produces the medians Sortie 6 serializes (dep_depth 2) and carries the heaviest live-CDN risk (multi-GB large tier + dedicated-container handling).

**Entry criteria**:
- [ ] Sortie 3 complete (single-tier measurement + `[PERF]` line working)

**Tasks**:
1. Extend the lifecycle across all three tiers (§4): tiny (`config.json`-only fetch), small (full small model), large (multi-GB, engineer-supplied id). **Precondition (non-blocking)**: the large tier is gated on the engineer replacing the `largeModelId` `// TODO` placeholder from Sortie 1 with a published 3GB+ model id; the sortie wires the tier and leaves the placeholder in place if no id is supplied, and the large-tier `[PERF]` line is only expected once a real id is set. This is a documented human-run precondition, not an unresolved decision.
2. For tiers fast enough to repeat (tiny/small), run N≥5 iterations and report **median plus min/max**; run the large tier once and state so in the output (§5 "Median, not mean").
3. Implement the two container modes (§5): default `container=temp` (unique temp root), and opt-in `ACERVO_PERF_CANONICAL=1` exercising the app-group code path (`Acervo.sharedModelsDirectory`) against a **dedicated testing app-group container that is never the developer's real container** (OQ-2 resolution). Resolve the testing container from a test-only group id (`ACERVO_PERF_APP_GROUP_ID`, defaulting to a throwaway value distinct from `ACERVO_APP_GROUP_ID`); refuse to run if `ACERVO_PERF_APP_GROUP_ID` equals the real `ACERVO_APP_GROUP_ID`. Teardown must **completely remove** the testing container's `SharedModels` tree.
4. Stamp `container=temp|canonical` into each `[PERF]` line.

**Exit criteria**:
- [ ] `make build` succeeds
- [ ] Tiny/small tiers emit a median + min/max line; large tier emits a single-run line labeled as such (verified manually with `ACERVO_PERF_TESTS=1 make test-perf`)
- [ ] Code review confirms canonical mode resolves to a dedicated testing container (refuses to run when `ACERVO_PERF_APP_GROUP_ID` equals the real `ACERVO_APP_GROUP_ID`) and its teardown deletes the testing container's `SharedModels` tree entirely — the developer's real container is never targeted
- [ ] `make test` still produces zero `[PERF]` lines

---

### Sortie 5: Add cold-vs-warm and per-component throughput metrics

**Priority**: 7.0 — medium. Independent metrics layer on the Sortie 3 core (live-CDN risk 3); only Sortie 7 depends on it. Parallel with Sortie 4.

**Entry criteria**:
- [ ] Sortie 3 complete (measurement core in place)

**Tasks**:
1. Implement `coldVsWarmRatio` (§3): a cold run on a fresh temp root, then a second warm run against the same populated root (cache-hit path timed); report the ratio.
2. Implement `perComponentThroughput` (§3) for the small-tier model (`smallModelId`, a multi-file model) by reading per-file `AcervoDownloadProgress` reports and computing MB/s per file.
3. Add `cache=cold|warm` to the `[PERF]` line for the two warm/cold passes.

**Exit criteria**:
- [ ] `make build` succeeds
- [ ] A cold pass and a warm pass each emit a `[PERF]` line with the correct `cache=` value, and a `coldVsWarmRatio` is printed (verified via `make test-perf`)
- [ ] Per-file MB/s lines are emitted for the `smallModelId` multi-file model
- [ ] `make test` still produces zero `[PERF]` lines

---

### Sortie 6: Add optional baseline regression mode

**Priority**: 6.0 — medium-low. JSON read/write + regression-warn logic (file I/O risk 2); depends on Sortie 4's medians and feeds only Sortie 7.

**Entry criteria**:
- [ ] Sortie 4 complete (median throughput numbers exist to compare/serialize)

**Tasks**:
1. When `ACERVO_PERF_BASELINE=<path>` is set, read the JSON baseline and compare current median throughput; **warn** (print, do not fail) when slower than the regression margin — configurable via the `ACERVO_PERF_MARGIN` env var (a fractional value, default `0.25` = 25%) (§6).
2. Make failure-on-regression require a second opt-in `ACERVO_PERF_STRICT=1`; default behavior is print-and-continue. Never `#expect` against an absolute hardcoded MB/s (§5).
3. When `ACERVO_PERF_BASELINE_WRITE=<path>` is set, serialize current medians to JSON.
4. Add the baseline artifact pattern (e.g. `*.acervo-perf-baseline.json`) to `.gitignore` so baselines are never committed.

**Exit criteria**:
- [ ] `make build` succeeds
- [ ] A `BASELINE_WRITE` run produces a JSON file; a subsequent `BASELINE` run reads it and prints a comparison line; with `STRICT=1` a >25% regression fails the test, without it only warns (verified via `make test-perf`)
- [ ] `git check-ignore` confirms the baseline artifact pattern is ignored
- [ ] No assertion against an absolute throughput constant exists in the suite

---

### Sortie 7: Document runner ergonomics and verify acceptance

**Priority**: 2.0 — lowest, by design. Terminal acceptance gate (dep_depth 0); runs last because it verifies everything else is in place.

**Entry criteria**:
- [ ] Sorties 1–6 complete

**Tasks**:
1. Add/confirm the `test-perf` Makefile target comment documents the required env (`ACERVO_PERF_TESTS=1`, `ACERVO_APP_GROUP_ID` or the temp-root pattern, live network) (§7).
2. Confirm the one-line run command is present in the suite file header (§7).
3. Verify acceptance (§10): run `make test` and `make test-ios`, grep the logs for `[PERF]` — must be **absent**; confirm `make test-plan-shape` stays green.
4. Confirm `ACERVO_PERF_TESTS=1 make test-perf` prints per-tier throughput summaries against the live CDN.

**Exit criteria**:
- [ ] `make test` and `make test-ios` logs contain **zero** `[PERF]` lines (§10.1)
- [ ] `make test-plan-shape` exits 0
- [ ] `ACERVO_PERF_TESTS=1 make test-perf` prints at least one `[PERF]` per-tier summary line (§10.2)
- [ ] The `test-perf` Makefile comment and the suite header both document the run invocation and required env

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 3 → Sortie 4 → Sortie 6 → Sortie 7 (length: 5 sorties)

**Hard serialization constraint**: Sorties 1, 3, 4, 5, and 6 all author/modify the single file `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift`. Even where the dependency graph would permit concurrency (e.g. Sorties 4 and 5 are both Layer 2), running them in parallel would collide on that file. They must run **sequentially on the supervising agent**. Sortie 2 is the only sortie touching a disjoint file set (the `.xctestplan` JSONs), so it is the sole genuine parallel opportunity.

**Parallel Execution Groups**:
- **Group 1** (after Sortie 1 lands):
  - Sortie 3 — measurement core, edits the suite file — **SUPERVISING AGENT ONLY** (live build + live-network verification)
  - Sortie 2 — CI-isolation test-plan edits, disjoint files — **NO BUILD** (sub-agent authors the JSON edits + grep confirmations; supervising agent runs `make test-plan-shape` to verify)
- **Group 2** (sequential, depends on Group 1): Sortie 4, then Sortie 5 — both edit the suite file — **SUPERVISING AGENT ONLY**
- **Group 3** (depends on Sortie 4): Sortie 6 — baseline mode, edits the suite file + `.gitignore` — **SUPERVISING AGENT ONLY**
- **Group 4** (depends on all): Sortie 7 — acceptance verification — **SUPERVISING AGENT ONLY**

**Agent Constraints**:
- **Supervising agent**: handles every sortie with a build/compile/live-network step — i.e. Sorties 1, 3, 4, 5, 6, 7, and the verification of Sortie 2.
- **Sub-agents (1 useful here)**: limited to pure file authoring with no compile — the Sortie 2 test-plan/`.gitignore` edits. The same-file serialization on the suite means additional sub-agents would have no non-conflicting work; max useful parallelism is **2** (1 supervising + 1 sub-agent), not the 4-agent ceiling.

**Missed Opportunities**: none recoverable — Sorties 4↔5 (same layer) and the Layer-1 pair cannot be parallelized further because they share `StreamingPerformanceTests.swift`. The mission is inherently near-serial.

---

## Open Questions

<!-- Consumed by Pass 1 of refine (`refine-blockers`). Each entry MUST be resolved before refinement can proceed past Pass 1. -->

_No blocking open questions remain. Both OQ-1 and OQ-2 were resolved during refinement (Pass 1) — see Decisions Log below._

### Decisions Log

| # | Affects | Decision | Source |
|---|---------|----------|--------|
| OQ-1 | Sortie 6 | **Drop** `chunkedVsSingleRatio` — single-stream is an internal fallback with no app-facing control; document in the suite header as "not measurable via the public API." | breakdown recommendation (accepted) |
| OQ-2 | Sortie 4 | Canonical mode uses a **dedicated testing app-group container that is never the developer's real container** (resolved via `ACERVO_PERF_APP_GROUP_ID`, distinct from `ACERVO_APP_GROUP_ID`) and **completely removes** that testing container's `SharedModels` tree on teardown. | user override |

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 7 |
| Open questions | 0 (2 resolved in refinement) |
| Dependency structure | layered (0–4), with parallelism at layers 1–2 |
