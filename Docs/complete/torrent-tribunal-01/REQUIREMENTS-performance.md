---
type: requirements
state: completed
---

# SwiftAcervo — Download Performance Requirements

**Status:** Draft, awaiting implementation
**Scope:** A local-only performance test suite that measures real model download throughput across the Acervo CDN path.
**Test plan:** `SwiftAcervo-Performance` (`.swiftpm/xcode/xcshareddata/xctestplans/SwiftAcervo-Performance.xctestplan`)
**Suite class:** `StreamingPerformanceTests` (already whitelisted by the `test-plan-shape` gate)
**Priority:** P3 — diagnostic tooling, not a correctness gate. Never blocks a release.

---

## 1. Why this exists

Acervo's value proposition is *fast* model delivery from the private R2 CDN — the v0.20.1
chunked-streaming work claimed "10–40× faster large-model downloads." That number is
currently unverified by any repeatable measurement. This suite exists to let an engineer,
**on their own machine, on their own network**, answer:

- What is the real end-to-end throughput (MB/s) of `Acervo.download` against the live CDN?
- Does chunked CDN streaming actually beat the single-stream path, and by how much, for a
  given file size?
- How much does a warm on-disk cache save versus a cold download?
- Has a code change regressed download speed relative to a previously recorded baseline?

It is **diagnostic instrumentation for humans**, not a pass/fail correctness check. Its
output is numbers and a verdict, printed to the test log, that the engineer reads.

### 1.1 Measure the path an app actually takes

The number that matters is what a real consumer app experiences: a user taps "download," and
SwiftAcervo doesn't report "ready" until every file is on disk **and SHA-256 verified against
the manifest**. So the suite measures the *whole* download-to-verified-on-disk pipeline as the
app drives it, not raw socket bandwidth:

- **Drive only the public, app-facing API** — `Acervo.download(...)`,
  `Acervo.ensureComponentReady(...)`, and the component-registry hydration path. Do **not**
  call internal shortcuts (`HuggingFaceClient.downloadRepo`, `AcervoDownloader` statics,
  `S3CDNClient`) directly. If an app can't reach it, this suite doesn't time it.
- **The timed window includes the work the app waits on**: manifest fetch → per-component
  byte transfer → per-file streaming SHA-256 verification → atomic move into the container.
  Verification is not "overhead to exclude"; it is part of the latency the user feels, so it
  stays inside the clock.
- **Throughput is reported against verified bytes**, i.e. `MB/s` is computed over the bytes
  that survived integrity checking and landed in the canonical layout
  (`{org}_{repo}/…`), not over bytes pulled off the wire.

## 2. Hard constraint: this NEVER runs in CI

This is the central requirement. It must be enforced by **three independent mechanisms**, so
that no single misconfiguration can leak a multi-gigabyte network download into a CI runner:

1. **Test-plan isolation.** The suite lives *only* in `SwiftAcervo-Performance.xctestplan`.
   CI invokes exactly two plans — `SwiftAcervo-macOS` and `SwiftAcervo-iOS` (see the `test`
   and `test-ios` Makefile targets and the GitHub workflow). The `-Performance` plan has no
   CI invocation and must never gain one.

2. **Explicit skip on the CI plans.** `StreamingPerformanceTests` must appear in the
   `skippedTests` array of *both* `SwiftAcervo-macOS.xctestplan` and
   `SwiftAcervo-iOS.xctestplan`. The existing `test-plan-shape` gate already permits exactly
   this one class to be skipped (and *only* this one) — so adding the suite under that name
   keeps the shape gate green without modification.

3. **Runtime env-var gate.** Every test method must early-`return` (swift-testing) /
   `XCTSkipUnless` (XCTest) unless `ACERVO_PERF_TESTS` is set in the environment, mirroring
   the `INTEGRATION_TESTS` pattern in `IntegrationTests.swift`. This guarantees that even if
   the suite is somehow invoked directly, it self-skips without touching the network unless a
   human opted in.

A reviewer should be able to delete any **two** of these three and the suite still does not
run in CI.

### Why a test plan and not just `@Suite(.disabled)`

A disabled suite is dead weight that never reports anything. A dedicated plan keeps the suite
**runnable on demand** (`make test-perf`, or directly via Xcode by selecting the Performance
plan) while remaining invisible to the automated pipeline. The split is the whole point.

## 3. What it measures

The suite drives **real `Acervo.download` calls against the live R2 CDN** — no mocks, no
`MockURLProtocol`. Mocked throughput is meaningless; the question is what the actual CDN and
the user's network deliver.

| Metric | Definition | Source |
|---|---|---|
| `throughputMBps` | `totalBytes / wallClockSeconds / 1_048_576` for a full cold download | wall clock around `Acervo.download` |
| `wallClockSeconds` | end-to-end time from call to all files verified on disk | `ContinuousClock` |
| `timeToFirstByte` | manifest fetch → first component byte written | progress callbacks |
| `coldVsWarmRatio` | cold-cache download time ÷ warm-cache (cache-hit) time | two sequential runs |
| `chunkedVsSingleRatio` | streaming-chunked time ÷ single-stream time for the same file | toggle the streaming path |
| `perComponentThroughput` | MB/s per file in a multi-file model | `AcervoDownloadProgress` reports |

Each run prints a compact, greppable summary line, e.g.:

```
[PERF] model=mlx-community/Llama-3.2-1B-Instruct-4bit bytes=812043264 wall=7.41s thru=104.6MB/s ttfb=0.38s cache=cold chunked=yes container=temp verified=yes
```

## 4. Test corpus (model size tiers)

Throughput is size-dependent (TTFB dominates small files; steady-state bandwidth dominates
large ones), so the suite must exercise at least three tiers. Models must already be published
to the CDN. Use small/known-public ids so the cold runs are not punishing:

| Tier | Purpose | Suggested model | Rough size |
|---|---|---|---|
| Tiny | TTFB / per-request overhead; manifest path | a `config.json`-only fetch from `mlx-community/Llama-3.2-1B-Instruct-4bit` | < 1 MB |
| Small | full small model, single-stream baseline | `mlx-community/Llama-3.2-1B-Instruct-4bit` (full) | ~0.5–1 GB |
| Large | steady-state bandwidth + chunked-streaming win | a multi-GB published model (engineer's choice; document which one was used in the run) | 3 GB+ |

The model ids must be **constants at the top of the suite**, clearly labeled, so the engineer
can swap them for whatever is currently published. Do not hardcode a model the suite cannot
verify exists in the manifest.

## 5. Methodology requirements

### 5.0 Per-test lifecycle (the four phases)

Every measurement is a self-contained, four-phase cycle. A test that crashes or fails
mid-cycle must still reach phase 4 (use `defer`):

1. **Ensure empty directory.** Create a fresh, unique `SharedModels` root (temp by default,
   §5 below) and assert it contains nothing for the target model. This guarantees a true cold
   start — no pre-existing files, no warm cache. A run that finds residue must fail rather than
   silently report an inflated (cache-assisted) number.

2. **Download, timing the speed.** Start the clock, call the public app API
   (`Acervo.download` / `Acervo.ensureComponentReady`), stop the clock when it returns
   "ready." This window is the headline measurement and **includes the per-file SHA-256
   verification the library itself performs** before declaring success — because that is
   exactly the wait an app experiences. Compute `throughputMBps`, `ttfb`, etc. from this phase.

3. **Validate the locally-downloaded version.** *After* the clock stops, the test
   independently confirms the on-disk result is real and usable: the canonical
   `{org}_{repo}/` layout exists, `config.json` is present (the universal validity marker),
   the file set matches the manifest, and byte counts / hashes line up. This is the test's own
   correctness assertion — separate from, and not counted in, the phase-2 timing. A fast
   download that produced a corrupt or incomplete tree is a **failed** measurement, not a fast
   one.

4. **Clean up / removal.** Delete the model directory (and the temp root, in default mode) in
   a `defer`/teardown so the machine is returned to its starting state. These trees are
   multi-GB; leaking them across iterations would both fill the disk and warm the cache for the
   next run. In `ACERVO_PERF_CANONICAL=1` mode, removal also restores the developer's real
   container to its pre-test contents.

The rest of this section refines how each phase is carried out.

- **Cold cache per measurement.** Each cold-download measurement starts from a unique temp
  `SharedModels` root (reuse `makeTempSharedModels()` / `cleanupTempDirectory()` from
  `IntegrationTests.swift`) so the OS/Acervo cache cannot skew the number. Clean up in a
  `defer`/teardown — these directories are multi-GB.
- **Two container modes; default to the safe one.** The on-disk *location* doesn't change
  throughput meaningfully, so the **default** mode writes to a temp root (clean cold cache, no
  pollution of the developer's real models). An **opt-in** `ACERVO_PERF_CANONICAL=1` mode
  instead targets the real app-group container (`Acervo.sharedModelsDirectory` via
  `ACERVO_APP_GROUP_ID`) for true on-device, in-app fidelity — at the cost of cleaning the
  developer's actual cache to force a cold run. The summary line records which mode produced
  the number (`container=temp|canonical`).
- **Warm measurement runs second**, against the same populated temp root, so the cache-hit
  path is what is timed.
- **Median, not mean.** For tiers fast enough to repeat (tiny/small), run N≥5 iterations and
  report the median plus min/max. The large tier may run once given its cost; say so in the
  output.
- **Record the environment.** The summary must include enough context to compare two runs:
  date, machine model, macOS version, and a coarse network descriptor the engineer passes in
  (e.g. `ACERVO_PERF_NET=wifi-100mbps`). A throughput number with no network context is
  noise.
- **No assertions on absolute throughput.** The suite must NOT `#expect(thru > X)` against a
  hardcoded MB/s — that would make the result depend on the runner's network and turn a
  diagnostic into a flaky failure. The only acceptable automated assertion is an **optional**
  regression check (§6).

## 6. Optional baseline regression mode

When `ACERVO_PERF_BASELINE=<path>` points at a previously captured JSON baseline, the suite
may compare the current median throughput against it and **warn** (not fail by default) if the
current run is more than a configurable margin (default 25%) slower. Failing the run on
regression must require a *second, explicit* opt-in (`ACERVO_PERF_STRICT=1`), because network
variance alone can exceed 25%. Default behavior is print-and-continue.

Baseline capture: a run with `ACERVO_PERF_BASELINE_WRITE=<path>` serializes the current
medians to JSON for future comparison. The baseline file is a local artifact and must be
`.gitignore`d, not committed.

## 7. Runner ergonomics

- `make test-perf` already targets the `-Performance` plan. The suite must run under it. The
  target should be documented as requiring `ACERVO_PERF_TESTS=1` and `ACERVO_APP_GROUP_ID`
  (or the temp-root pattern, which sidesteps the app-group requirement) and live network.
- A one-line invocation must appear in the suite's file header doc comment, mirroring the
  `IntegrationTests.swift` header, e.g.:

  ```
  ACERVO_PERF_TESTS=1 ACERVO_PERF_NET=wifi xcodebuild test \
      -scheme SwiftAcervo-Package -testPlan SwiftAcervo-Performance \
      -destination 'platform=macOS,arch=arm64'
  ```

- Output goes to the test log via `print`. This is the one suite where `print` is acceptable
  (it is the deliverable); it is invisible to CI because the suite never runs there.

## 8. Out of scope

- **Inference / model-loading speed.** SwiftAcervo finds and downloads; it does not load
  models into a framework. "Loading" here means *download to verified-on-disk*, nothing about
  MLX load time. (The original ask says "loading models" — for this library that is the
  download path. A true inference-load benchmark belongs in SwiftBruja / mlx-audio-swift.)
- **Publish/upload throughput** (`Acervo.publishModel`, `recache`). Could be a sibling suite
  later; not this one.
- **Micro-benchmarks of `SigV4Signer`, SHA streaming, Levenshtein**, etc. Those are
  CPU-bound unit concerns, not the ecosystem download speed this suite is about.
- **CI-side performance tracking / dashboards.** By definition this never runs in CI.

## 9. Implementation checklist

- [ ] Add `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` with `@Suite("StreamingPerformanceTests")`
- [ ] Every test method gates on `ACERVO_PERF_TESTS` (early return when unset)
- [ ] Add `StreamingPerformanceTests` to `skippedTests` in `SwiftAcervo-macOS.xctestplan` and `SwiftAcervo-iOS.xctestplan` (keeps `test-plan-shape` green)
- [ ] Ensure `SwiftAcervo-Performance.xctestplan` does **not** skip `StreamingPerformanceTests` (it is the one suite that plan runs)
- [ ] Confirm no CI workflow references the `-Performance` plan
- [ ] Implement size tiers (§4) with model ids as labeled constants
- [ ] Implement the four-phase lifecycle per test (§5.0): ensure-empty → timed download → independent on-disk validation → `defer` cleanup
- [ ] Implement cold/warm + chunked/single comparisons (§3) on unique temp roots with cleanup
- [ ] Print the `[PERF] …` summary line per measurement (§3)
- [ ] Implement optional baseline read/write + regression warn (§6); `.gitignore` baseline files
- [ ] Document the run command in the file header and in the Makefile `test-perf` comment
- [ ] Verify `make test` / `make test-ios` do not execute the suite (grep the test log for `[PERF]` — must be absent)

## 10. Acceptance

The work is done when:

1. `make test` and `make test-ios` produce **zero** `[PERF]` output and zero perf-suite
   execution (proven by the shape gate staying green and a clean CI run).
2. `ACERVO_PERF_TESTS=1 make test-perf` on a developer machine prints per-tier throughput
   summaries against the live CDN.
3. Two consecutive `test-perf` runs on the same machine produce comparable medians, and a
   deliberately throttled network produces a visibly lower number — confirming the suite
   measures real throughput.
