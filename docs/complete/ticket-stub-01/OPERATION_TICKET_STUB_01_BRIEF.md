---
state: completed
---

# Iteration 01 Brief — OPERATION TICKET STUB

**Mission:** Make SwiftAcervo's `availability` surface authoritative with three states (`notAvailable`, `downloading(progress:)`, `available`), make downloads resumable via `.part` files, and dedup concurrent callers via an `InFlightDownloads` actor.
**Branch:** `mission/ticket-stub/01`
**Starting Point Commit:** `d725931` (`docs: capture three-state availability + resumable download plan`)
**Sorties Planned:** 7 (3 in WU1, 4 in WU2)
**Sorties Completed:** 7
**Sorties Failed/Blocked:** 0
**Duration:** ~9 commits, 1 mission session. No BACKOFF, no FATAL, no PARTIAL transitions — every sortie succeeded on first attempt.
**Outcome:** Complete
**Verdict:** `KEEP` — Every sortie completed first-attempt-clean, test-cleanup found nothing to remove, the breaking-semantic-change in `isModelAvailable` is correctly routed to a minor version bump, and the 2 in-flight deviations are well-justified and improve testability.
**Tests pruned:** 0
**Tests flagged for review:** 3 (advisory only — timing-sensitive concurrency tests using 100ms sleeps for ordering/polling; not flaky, just slow under heavy CI load)

---

## Terminology

- **Mission:** definable scope of work (this whole plan).
- **Sortie:** atomic agent task within the mission.
- **Work Unit:** grouping of sorties (WU1 = resumable downloads, WU2 = three-state availability).

---

## Section 1: Hard Discoveries

### 1. SecureDownloadSession.shared has frozen protocol classes at init

**What happened:** Sortie 6's plan was to use `MockURLProtocol` to drive concurrent `ensureAvailable` calls. But `SecureDownloadSession.shared` is a `let`-immutable singleton whose `URLSessionConfiguration.protocolClasses` is set at init; `URLProtocol.registerClass(_:)` does NOT retroactively affect already-built sessions. The test would have silently called the real CDN.
**What was built to handle it:** Sortie 6 added a `session: URLSession? = nil` test-injection parameter to the INTERNAL `Acervo.download` and `Acervo.ensureAvailable` overloads. Default `nil` reproduces production behavior verbatim. The public API surface is unchanged. The pattern matches existing seams already used by `hydrateComponent`, `fetchManifest`, and `AcervoDownloader.downloadFiles`.
**Should we have known this?** Yes. A 30-second `grep -rn "session:" Sources/` before refinement pass 5 would have surfaced the existing seam pattern and we'd have included it in the Sortie 6 component definitions. Pass 5 missed it because it focused on cited line ranges, not on the cross-cutting "how do tests inject URLSession" question.
**Carry forward:** When a sortie's tests depend on `MockURLProtocol`, the plan must explicitly state which seam the agent uses (existing or new). For SwiftAcervo specifically: any public method that ultimately calls `SecureDownloadSession.shared` needs a `session:` injection point on its internal overload, or the test path is unreachable.

### 2. AcervoManager() initializer is private; tests cannot construct fresh instances

**What happened:** Sortie 5's plan asked for "a fresh `AcervoManager` instance if possible to avoid singleton state interference." The agent discovered `AcervoManager()` is `private` — the type is singleton-only via `AcervoManager.shared`. The forwarder test had to fall back to `.shared`, which probes `sharedModelsDirectory` (process-global, set by `ACERVO_APP_GROUP_ID`), so the test cannot directly assert "static and forwarder return the same value for the same fixture" using a temp base directory.
**What was built to handle it:** The test asserts the forwarder returns `.notAvailable` for the shared-singleton path (model doesn't exist in `sharedModelsDirectory`) and the static `(in:)` overload returns `.available` for the temp fixture. Both halves probe a real code path; the test loses the strongest possible "forwarder equality" assertion but the forwarder itself is a one-line `await Acervo.availability(modelId)` whose correctness is structural.
**Should we have known this?** Yes. Reading `AcervoManager.swift` for ~30 seconds would have shown the `private init`. Pass 5 didn't think to check it.
**Carry forward:** AcervoManager is a singleton by design. If a future test wants to exercise a forwarder against a temp directory, either (a) add a fresh-instance test seam (test-only `internal init` or similar) or (b) write the assertion as a structural check (verify the forwarder body forwards) rather than a value-equality check.

### 3. SourceKit lags badly behind compile reality during multi-commit mission sessions

**What happened:** After every WU2 sortie commit, SourceKit emitted false-positive "Cannot find type" / "Cannot find … in scope" diagnostics for `ModelAvailability` and `InFlightDownloads`, plus a "no calls to throwing functions" warning on `try await sharedTask.value` (where `Task<Void, Error>.value` is genuinely `async throws`). `make test` confirmed all symbols compile and tests pass; SourceKit was simply not reindexing across rapid file additions in a session.
**What was built to handle it:** Verified via `grep` after each sortie that symbols actually exist in source. Confirmed compile reality through `make test`'s exit code.
**Should we have known this?** Not really — this is tooling behavior, not a code property. But the supervisor should treat SourceKit diagnostics as advisory during a mission, never as ground truth.
**Carry forward:** Treat SourceKit diagnostics as advisory. The build/test pass is ground truth. Future supervisors verifying sortie outcomes should never block on SourceKit alone.

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### A1. Sortie 1's failure-path policy was so thorough Sortie 2 became pure documentation

**What happened:** Sortie 1 fully reworked the `.part`-file failure policy (delete only on validated corruption — oversize/SHA/size mismatch; keep on transient failures). When Sortie 2 audited for residual cleanup paths, it found nothing to delete.
**Right or wrong?** Right. Sortie 1 absorbed scope that the plan had allocated to Sortie 2 because it was the natural place to do so.
**Evidence:** Sortie 2's diff is 12 inserted lines + 4 deleted (the new fallback doc comment + minor tightening). Zero `try? fm.removeItem` deletions.
**Carry forward:** When a sortie naturally absorbs its successor's scope, that's good — it means the abstraction held. Don't fight it; let the successor sortie shrink to its actual remaining work.

#### A2. Sortie 4's test migration was systematic and complete

**What happened:** Sortie 4 was the breaking-semantic-change sortie, with 7 dependent test files to migrate. The agent produced an explicit per-call-site migration table covering each file with disposition (migrated to `isModelConfigPresent` / kept + manifest seeded / kept naturally stronger / no-op).
**Right or wrong?** Right. The migration table is auditable and surfaced 1 extra migration the plan didn't enumerate (`AcervoDownloadAPITests.ensureAvailableSkipsExistingModel`).
**Evidence:** All 565+ tests pass post-migration; the test that was previously "passing under loose semantics" is now concretely migrated.
**Carry forward:** When a sortie carries a semantic-contract change, the plan should require an explicit per-call-site migration table in the agent's report. Sortie 4's report became a useful diff-of-the-diff.

### What the Agents Did Wrong

None significant. Two minor process-quality observations:

#### B1. Sortie 6's joiner-test required a deterministic sleep that the plan didn't predict

**What happened:** The plan's `dedup_joinerWithDifferentFilesRidesOriginator` test launched both calls with `async let`, but actor-serialization makes registration order non-deterministic — the joiner could win the race and the originator would ride on the 1-file subset, making `requestCount == 2`. The agent added a `Task.sleep(100ms)` between launches to make ordering deterministic.
**Right or wrong?** Right call given the test's intent. The semantics being verified is "first-to-register wins," so the labels "originator" and "joiner" must describe registration order. But the test now has a 100ms timing dependency.
**Evidence:** `TEST_CLEANUP_REPORT.md` flags this test (3 of 3 flagged tests come from this Sortie 6 cluster).
**Carry forward:** Concurrency tests need either (a) a primitive that makes ordering deterministic (semaphore, expectation) or (b) an explicit acknowledgment in the plan that timing-based ordering is acceptable. Future versions should use a `CheckedContinuation`-based latch instead of `Task.sleep` for the joiner test.

### What the Planner Did Wrong

#### C1. Pass-5 missed the URLSession-injection requirement for Sortie 6

**What happened:** Pass 5 code-walked the cited line ranges in `Sources/SwiftAcervo/` but didn't audit "what seams do tests use to inject `URLSession`?" That's why Sortie 6 had to expand its scope to add the `session:` parameter on internal overloads.
**Right or wrong?** Wrong. Sortie 6 absorbed the scope cleanly, but it expanded the sortie's surface area beyond what was planned. Could have caused a context overrun; didn't, only because the agent was efficient.
**Evidence:** Sortie 6 used 63 tool uses and ~17m duration — by far the longest sortie. The expanded scope contributed.
**Carry forward:** Pass-5 audit should include a cross-cutting "test injection seams" question for any sortie that touches network code. Specifically: "For each sortie that requires `MockURLProtocol`, does the production code path expose an existing seam, or does the sortie need to add one?"

#### C2. Plan didn't enumerate the `AcervoDownloadAPITests.ensureAvailableSkipsExistingModel` migration

**What happened:** The plan listed 5 candidate test files for migration in Sortie 4 but missed this one. The agent caught it and migrated it.
**Right or wrong?** Wrong. Acceptable miss — the plan said "every prior call to `isModelAvailable` must be audited" so the agent had a guardrail. But a complete enumeration would have been better.
**Evidence:** Sortie 4 report explicitly flags this as a deviation: "expands the migration scope beyond what the plan enumerated."
**Carry forward:** For semantic-change sorties, the plan should include the complete output of `grep -rn "<old-symbol>" Tests/` in the sortie spec, not a sample.

---

## Section 3: Open Decisions

### 1. Should the 3 timing-sensitive dedup tests be hardened?

**Why it matters:** They're not flaky today, but under heavy CI load (a busy macOS-26 runner) the 100ms ordering window or the polling-based progress observation could miss. If they start flaking 6 months from now, the team will need to context-switch back into actor concurrency to debug. Cheaper to harden now while context is fresh.
**Options:**
- **A**: Replace `Task.sleep`-based ordering with a `CheckedContinuation`-based latch the originator signals before returning from `start()`. ~30 minutes of work; eliminates timing dependency.
- **B**: Leave the tests as-is. They pass today, the failure mode is well understood, and `TEST_CLEANUP_REPORT.md` documents the concern.
- **C**: Convert them to "integration-only" tests gated by `CONCURRENCY_TESTS=1`, removing them from default CI.
**Recommendation:** **A** — small investment, big robustness payoff, prevents future flake-triage cost. Could be a single follow-up patch release sortie.

### 2. Should `AcervoManager` get a test-only `init` seam?

**Why it matters:** The private `init` makes `AcervoManager` untestable except via `.shared`. Any future test that wants per-test isolation of manager state has the same problem Sortie 5 hit.
**Options:**
- **A**: Add `internal init(...)` annotated test-only. Compromises the singleton invariant.
- **B**: Add a `reset()` method on the singleton (similar to `InFlightDownloads.reset()`).
- **C**: Leave it. The forwarder is one line; structural verification is sufficient.
**Recommendation:** **C** for now. **B** if a real per-test isolation need surfaces.

### 3. When does REQUIREMENTS § 4.4 (chunked streaming) ship?

**Why it matters:** Already documented as deferred. The follow-up mission needs a perf bench harness that doesn't exist yet. If the chunked-streaming work happens before the bench, we'll have no way to validate the claimed win.
**Options:**
- **A**: Next mission builds the bench harness first (one sortie), then ships the `URLSessionDataDelegate` rewrite.
- **B**: Bundle bench + rewrite in a single mission (~5 sorties).
- **C**: Defer indefinitely until a downstream consumer (SwiftBruja, mlx-audio-swift) files a perf-regression issue.
**Recommendation:** **B** with explicit "bench-first" sortie ordering — single mission, clear measurement gate.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| WU1.1 | Resumable `.part` downloads + 6 tests | opus | 1 | ✓ Highly accurate | First-shot landing. Did its successor's job too (cleanup policy fully reworked). Two minor judgment calls flagged (partSize==0 treated as absent — correct; `UUID().uuidString` zero-hits everywhere — observation only). |
| WU1.2 | Delete residual cleanup + doc fallback | haiku | 1 | ✓ Accurate (but trivial) | Sortie 1 left nothing to delete. Reduced to pure documentation. Not a failure of S2 — a sign S1 was thorough. |
| WU1.3 | Version bump 0.13.1-dev → 0.13.2 + CHANGELOG | haiku | 1 | ✓ Accurate | Clean release-prep. No deviations. |
| WU2.4 | Strict availability + manifest persist + isModelConfigPresent + test migration | opus | 1 | ✓ Highly accurate | Largest sortie (~84% of 50-turn budget). 7 test files migrated with per-call-site disposition table. Caught 1 migration the plan didn't enumerate. |
| WU2.5 | ModelAvailability enum + availability(_:) stub | sonnet | 1 | ✓ Accurate | Clean. Hit the private-init constraint and gracefully fell back; flagged for brief. |
| WU2.6 | InFlightDownloads actor + dedup + remove S5 stub | opus | 1 | ✓ Accurate (with scope expansion) | Added the `session:` test-injection seam — necessary, well-precedented, but planner-missed. Joiner test uses 100ms ordering sleep — flagged for hardening. |
| WU2.7 | Version bump 0.13.2 → 0.14.0 + CHANGELOG + API_REFERENCE | haiku | 1 | ✓ Accurate | Clean release-prep. No deviations. |
| post-mission | test-cleanup audit | haiku | 1 | ✓ Accurate | 0 deletions; 3 advisory flags. Confirms suite is CI-safe. |

**Aggregate accuracy: 8/8 first-attempt success. No BACKOFF, no FATAL, no PARTIAL.** This is the cleanest run profile possible.

---

## Section 5: Harvest Summary

The plan held. Five refinement passes (especially pass 5's code-walk against HEAD `d0aa8da`) eliminated the failure modes that would have shown up at execution time — specifically, the AsyncBytes-batching dead-end that the original plan would have wasted Sortie 1 on. Every sortie completed first-attempt-clean, no test was deleted by the cleanup pass, and the breaking-semantic-change in `isModelAvailable` is correctly routed to a minor version bump (0.14.0) with documented migration guidance.

The single most important thing that changes about the next iteration: **Pass-5 audits should include a cross-cutting "test injection seams" question** for any sortie that touches network or session code. Sortie 6 had to add a `session:` injection seam on the fly — it absorbed the scope cleanly because the agent was efficient, but a planner-aware pass would have folded it into Sortie 6's spec from the start.

`TEST_CLEANUP_REPORT.md`: 0 of 79 mission tests pruned; 3 advisory flags. All flags are the same root cause (`Task.sleep`-based ordering/polling in `AvailabilityThreeStateTests`). Recommendation: a single follow-up patch sortie to swap `Task.sleep` for a `CheckedContinuation` latch.

---

## Section 6: Files

**Preserve (read-only reference for next iteration):**

| File | Branch | Why |
|------|--------|-----|
| `EXECUTION_PLAN.md` | mission/ticket-stub/01 | The plan that worked. Useful template for future SwiftAcervo missions. Note: ships pass-5 code-walk methodology. |
| `OPERATION_TICKET_STUB_01_BRIEF.md` | mission/ticket-stub/01 | This brief. Hard discoveries about SecureDownloadSession seam, AcervoManager singleton, SourceKit lag. |
| `TEST_CLEANUP_REPORT.md` | mission/ticket-stub/01 | The 3 flagged tests; input for the follow-up `Task.sleep` → `CheckedContinuation` patch. |
| `SUPERVISOR_STATE.md` | mission/ticket-stub/01 | Audit trail: every sortie's model selection, attempt count, decisions log. |

**Discard (will not exist after rollback):**

| File | Why it's safe to lose |
|------|----------------------|
| (none) | The mission is being KEPT. No rollback. All files persist. |

---

## Section 7: Iteration Metadata

**Starting point commit:** `d725931` (`docs: capture three-state availability + resumable download plan`)
**Mission branch:** `mission/ticket-stub/01`
**Final commit on mission branch:** `8080097` (`test-cleanup: audit (no deletions) for OPERATION TICKET STUB`)
**Rollback target:** `d725931` (NOT BEING USED — verdict is KEEP)
**Next iteration branch:** `mission/ticket-stub/02` — would only be needed if the follow-up `Task.sleep` → `CheckedContinuation` patch is treated as a new mission; more likely a single-PR patch off `development` post-merge.

---

## Section 8: Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** All 7 planned sorties completed first-attempt-clean (no BACKOFF, no FATAL, no PARTIAL). Test cleanup found nothing to delete (0/79 tests pruned; 3 advisory flags, all timing-related, all clustered in one test file). The breaking-semantic-change in `Acervo.isModelAvailable(_:)` is contained, documented in `CHANGELOG.md` with a migration path (`isModelConfigPresent` as escape hatch), and correctly routes to a minor version bump (0.14.0). The two in-flight deviations (session-injection seam on internal overloads; AcervoManager forwarder test using `.shared`) are well-justified, match existing project patterns, and improve testability rather than degrade it. This is a clean, mergeable mission.

**Recommended action — KEEP:**

1. **Merge the mission branch** through the project's normal development → main flow. Recommend a PR onto `development` rather than direct push, so a human can scan the breaking-semantic-change in `isModelAvailable` one more time before it lands.
2. **File a follow-up patch ticket** for the 3 timing-flagged tests: swap `Task.sleep`-based ordering/polling in `AvailabilityThreeStateTests` for a `CheckedContinuation` latch (Section 3, Decision 1, Option A). Single sortie, ~30 minutes.
3. **Schedule the deferred mission** for REQUIREMENTS § 4.4 (chunked streaming via `URLSessionDataDelegate`) with the "bench-first" sortie ordering recommended in Section 3, Decision 3.
4. **Carry forward the pass-5 audit improvement** documented in Section 1, Discovery 1: any future SwiftAcervo mission whose sorties depend on `MockURLProtocol` must declare the test-injection seam in its component definitions, not discover it at execution time.

No follow-up tickets needed for open decisions 2 (AcervoManager init seam) — recommendation is to leave it; revisit only if a real need surfaces.
