---
type: mission-brief
state: completed
---

# Iteration 01 Brief — OPERATION TORRENT TRIBUNAL

**Mission:** A gated, local-only `StreamingPerformanceTests` suite that measures real CDN download-to-verified-on-disk throughput across the Acervo path and never runs in CI.
**Branch:** `mission/torrent-tribunal/01`
**Starting Point Commit:** `15f58681fbe622f0bf2971eaf341470767478f67`
**Sorties Planned:** 7
**Sorties Completed:** 7
**Sorties Failed/Blocked:** 0
**Duration:** 7 sorties, 0 retries; dominated by Sortie 7's ~22-min live ~5 GB acceptance run.
**Outcome:** Complete
**Verdict:** `KEEP` — all 7 sorties landed first-try, the suite is live-proven (13 `[PERF]` lines), and CI isolation is triple-guarded and verified.
**Tests pruned:** 0
**Tests flagged for review:** 0

---

## Section 1: Hard Discoveries

### 1. xcodebuild does not propagate shell env to the xctest runner
**What happened:** The plan's documented run command (`ACERVO_PERF_TESTS=1 … make test-perf`, from REQUIREMENTS §7) assumed the shell env var would reach the test process. It does not — the gate stayed shut and `make test-perf` emitted zero `[PERF]` lines on the first live attempt.
**What was built to handle it:** Sortie 7 added an `environmentVariableEntries` block to the **Performance plan only** (`ACERVO_PERF_TESTS=1`, `ACERVO_PERF_NET=wifi`, `ACERVO_APP_GROUP_ID`). The test plan is the reliable channel.
**Should we have known this?** Yes. The repo's own `Makefile` documents it (line ~21: "Shell env vars are NOT propagated by xcodebuild to the xctest runner"). The plan ignored its own codebase's note.
**Carry forward:** Any env an integration/perf test reads via `ProcessInfo` must be set through the `.xctestplan`, never assumed from the shell. Bake this into Sortie 1 of any future test-infra mission.

### 2. The Performance test plan was never registered in the scheme
**What happened:** `SwiftAcervo-Performance.xctestplan` existed but was absent from `SwiftAcervo-Package.xcscheme`'s `TestPlans`, so `xcodebuild … -testPlan SwiftAcervo-Performance` failed with error 64.
**What was built to handle it:** Sortie 7 added a `TestPlanReference` for the Performance plan to the scheme.
**Should we have known this?** Yes — a one-line pre-check (`grep Performance …xcscheme`) would have caught it. The plan assumed a `.xctestplan` file on disk was sufficient to run it.
**Carry forward:** Adding a test plan is two steps: the file *and* its scheme registration. Verify both.

### 3. The Performance plan crashed the runner without `ACERVO_APP_GROUP_ID`
**What happened:** With the gate finally open, the runner hit `fatalError` in `Acervo.sharedModelsDirectory` because the Performance plan set no `ACERVO_APP_GROUP_ID` (the macOS plan does).
**What was built to handle it:** Included `ACERVO_APP_GROUP_ID=group.acervo.testbundle.default` in the same Performance-plan env block.
**Should we have known this?** Partially — the no-fallback fatalError is documented in CLAUDE.md, but it wasn't obvious the perf path would resolve the shared dir even in temp mode.
**Carry forward:** Every plan that can load the perf suite needs `ACERVO_APP_GROUP_ID` set, independent of container mode.

---

## Section 2: Process Discoveries

### What the Agents Did Right
- **Surgical commit scoping.** Every sortie staged only its own files; the unrelated parked `skills/` edits were never swept into a single mission commit across all 7 sorties. Seven commits, one logical change each.
- **Defense-in-depth on the destructive path.** Sortie 4's canonical-container teardown (deletes a `SharedModels` tree) was guarded with capture-real-id-before-mutation, exact-inequality refusal, and double path-containment checks. The riskiest code in the mission was the most carefully guarded.
- **Each sortie preserved prior work** rather than rewriting the shared file.

### What the Agents Did Wrong
- Minor only: Sortie 4 hit a Swift type-inference snag with `Issue.record(_:)` overloads and worked around it by pre-building `String` messages. No wasted output, no rework.

### What the Planner Did Wrong
- **Under-scoped the test-infrastructure reality.** Three real defects (env propagation, scheme registration, missing app-group id) all surfaced at the very last sortie. The plan treated "wire `make test-perf`" as a doc-confirmation task; it was actually three infra fixes. A dedicated early "make the Performance plan actually runnable" sortie would have de-risked the critical path and surfaced these before five measurement sorties were built on an un-runnable harness.
- **Model selection was accurate.** opus for the two genuinely hard sorties (3 measurement core, 4 tiers+destructive-container); sonnet for the rest. Zero retries, zero forced upgrades — no evidence of mis-sizing.

---

## Section 3: Open Decisions

### 1. `largeModelId` is an empty TODO placeholder
**Why it matters:** The large (3 GB+) tier auto-skips until the engineer sets a published model id; §10.2 large-tier acceptance is unverified.
**Options:** (a) leave as documented human precondition; (b) pick a published 3 GB+ CDN model and wire it.
**Recommendation:** (a) — it's an intentional human-run precondition, not a defect. Set it when a real large measurement is wanted.

### 2. The parked `skills/acervo-integration-ci/*` edits ride on this branch
**Why it matters:** Five unrelated modified files are uncommitted on `mission/torrent-tribunal/01`. They must not land in a perf-suite PR.
**Options:** (a) stash/move them to their own branch before merging; (b) commit them separately first.
**Recommendation:** (a) before any merge of this mission.

### 3. Measured throughput is genuinely slow (~6 MB/s median, small tier)
**Why it matters:** The first real data point shows ~6 MB/s for a 712 MB model (one cold pass at 1.85 MB/s). Is this the test network or an Acervo download-path concern? Surfacing exactly this is the suite's job.
**Options:** rerun on a faster network with `ACERVO_PERF_NET=` set accordingly before drawing conclusions.
**Recommendation:** treat this run as a baseline data point, not a verdict on Acervo perf.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Scaffold gated skeleton | sonnet | 1 | Yes | Helpers/gate/constants reused by all downstream sorties; survived unchanged |
| 2 | CI-isolation test plans | sonnet | 1 | Yes | Skip entries held through end of mission |
| 3 | Measurement core + `[PERF]` | opus | 1 | Yes | Validation-after-clock structure correct; live-proven in Sortie 7 |
| 4 | Tiers + medians + canonical mode | opus | 1 | Yes | Destructive teardown well-guarded; line-59 deprecation also cleaned |
| 5 | Cold/warm + per-component | sonnet | 1 | Yes | `cache=` parameterized cleanly |
| 6 | Baseline regression mode | sonnet | 1 | Yes | Warn-default/strict-opt-in; no absolute-MB/s assertions; gitignored |
| 7 | Acceptance + docs | sonnet | 1 | Yes | Found+fixed 3 infra defects; live run emitted 13 `[PERF]` lines |

Every sortie's output survived into final state with zero rework. 100% accuracy.

---

## Section 5: Harvest Summary

We now know the suite **actually runs** — not just compiles. The live acceptance produced 13 well-formed `[PERF]` lines across the tiny and small tiers, with sane cold (1.85–6 MB/s) vs warm (cache-hit, ~instant) contrast. The single most important lesson for any future test-infra mission: **the gating risk for a non-CI test suite is the test-plan/scheme wiring, not the test code.** All three real defects were in `.xctestplan`/`.xcscheme` plumbing, invisible to compile-time checks and only exposed by a live run — which is exactly why running the live acceptance (rather than deferring it) was the right call. Test-cleanup pruned nothing: the suite's network/timing patterns are its purpose and are fully neutralized by the gate+skip+scheme isolation.

---

## Section 6: Files

**Preserve (the deliverable):**

| File | Branch | Why |
|------|--------|-----|
| `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` | `mission/torrent-tribunal/01` | The suite itself — gated, three-tier, live-proven |
| `.swiftpm/.../SwiftAcervo-{macOS,iOS}.xctestplan` | same | CI skip entries (Sortie 2) |
| `.swiftpm/.../SwiftAcervo-Performance.xctestplan` | same | Env entries that make `make test-perf` runnable (Sortie 7) |
| `.swiftpm/.../SwiftAcervo-Package.xcscheme` | same | Performance plan registration (Sortie 7) |
| `Makefile` | same | `test-perf` ergonomics comment (Sortie 7) |
| `.gitignore` | same | Baseline-artifact ignore pattern (Sortie 6) |

**Discard:** none — verdict is `KEEP`.

---

## Iteration Metadata

**Starting point commit:** `15f58681fbe622f0bf2971eaf341470767478f67` (`Add acervo-integration-ci skill`)
**Mission branch:** `mission/torrent-tribunal/01`
**Final commit on mission branch:** `47a84a7`
**Rollback target:** `15f58681fbe622f0bf2971eaf341470767478f67` (unused — verdict is KEEP)
**Next iteration branch:** `mission/torrent-tribunal/02` (only if a future iteration is needed)

---

## Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** All work units COMPLETED with zero retries and zero BLOCKED/FATAL sorties (Section 4). The three hard discoveries (Section 1) were test-plumbing fixes cleanly absorbed within Sortie 7, not foundation-level misunderstandings. The suite is live-verified — 13 `[PERF]` lines against the real CDN (Section 5) — and CI isolation is triple-guarded and confirmed (Section, TEST_CLEANUP_REPORT). Test cleanup removed 0% of mission tests. Although this is iteration 1 (where the honest default leans toward ROLLBACK to avoid accreting bad foundation), the foundation here is sound and proven, so KEEP is the correct call.

**Recommended action:**
- Merge the mission branch — **after** separating the parked `skills/acervo-integration-ci/*` edits (Open Decision 2).
- Follow-up tickets: set a real `largeModelId` when large-tier numbers are wanted (Open Decision 1); re-run on a known-fast network to interpret the ~6 MB/s baseline (Open Decision 3).
