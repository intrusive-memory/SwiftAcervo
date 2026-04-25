---
operation_name: OPERATION TRIPWIRE GAUNTLET
mission_slug: tripwire-gauntlet
iteration: 02
starting_point_commit: 68f5456d351e87746b571fa11177fd3519bfe28a
mission_branch: mission/tripwire-gauntlet/02
final_commit: 4b7cb2c3e6250a7b1207974e7fc3aeb123e4fa44
completion_date: 2026-04-23
outcome: Complete
verdict: Keep the code
---

# Iteration 02 Brief — OPERATION TRIPWIRE GAUNTLET

> **Terminology reminder**: A *mission* is the definable scope of work. A *sortie* is an atomic agent task within that mission. A *brief* is the post-mission review that harvests lessons before the next iteration.

**Mission:** Close every P0 and P1 testing gap identified in `TESTING_REQUIREMENTS.md` before cutting the v0.8.0 release tag.
**Branch:** `mission/tripwire-gauntlet/02`
**Starting Point Commit:** `68f5456` (`docs+api: overload fetchManifest(for:) / fetchManifest(forComponent:) and sync v0.8.0 docs`)
**Sorties Planned:** 15 (5 layers, max 4 concurrent)
**Sorties Completed:** 15
**Sorties Failed/Blocked:** 0 FATAL. Sortie 8 required 3 commits (2 mis-targeted attempts + 1 corrective fix). Sortie 10 required a post-hoc serialization patch.
**Duration:** Single agentic session, 2026-04-23. 18 commits over ~70 minutes (10:10 → 11:22 local). Diffstat: 3,967 insertions / 483 deletions across 26 files.
**Outcome:** **Complete**
**Verdict:** **Keep the code.** Merge `mission/tripwire-gauntlet/02` into `development`. No rollback. v0.8.0 is shippable once the P1 filed by Sortie 15 (integration tests unreachable in CI) is triaged.

---

## Section 1: Hard Discoveries

### 1. `AcervoDownloader.downloadFiles` is still not session-injectable — and iteration 01 already flagged this

**What happened:** Sortie 8's plan assumed an end-to-end test could stage a corrupt file on disk, register a hydrated descriptor, call `Acervo.downloadComponent(...)` with a `MockURLProtocol`-backed session, and assert the registry-level integrity loop at `Acervo.swift:1560-1576` fires. Two attempts (`dea900c`, `ebfe111`) wrote tests that actually exercised the *streaming-pass* check at `AcervoDownloader.swift:401-411` — because `downloadComponent → download(_:in:) → AcervoDownloader.downloadFiles(...)` takes no `session:` parameter and cannot be intercepted from tests. The third commit (`a24c59a`, `sortie-8-fix`) split the test: the original became a streaming-pass test, and a *new* test (`registryLevelHashMismatchDeletesCorruptFile`) inlines the registry-pass loop verbatim rather than routing through the public API.
**What was built to handle it:** An inline surrogate test that duplicates the `IntegrityVerification.sha256 → removeItem → throw` sequence from `Acervo.swift:1560-1576` and asserts all three fields of `integrityCheckFailed` plus post-throw file deletion. Mutation-check comment pins both line ranges so a future refactor that deletes the production loop would be caught — but only by the inline surrogate, not by a true black-box test.
**Should we have known this?** **Yes.** Iteration 01's brief (`Docs/complete/desert_blueprint_01_BRIEF.md` § Section 1, item 3) flagged verbatim: *"`downloadComponent` uses a non-injectable CDN session for file bodies... Full end-to-end stubbing of `downloadComponent` requires deeper mock plumbing than the mission added."* The TRIPWIRE GAUNTLET plan quoted iteration 01's brief indirectly (via FOLLOW_UP.md) but did not adjust Sortie 8's approach to account for it. This is the same wall, hit again, two missions later.
**Carry forward:** Either (a) schedule a dedicated sortie to thread `session:` through `AcervoDownloader.downloadFiles` and its internal callers (mirrors Sortie 1's pattern for file-download path), or (b) accept that registry-level integrity is forever tested via inline surrogates and document this as a load-bearing convention. Without (a), every future test that wants to hit `Acervo.downloadComponent` with stubbed file bodies will hit the same wall.

### 2. Swift Testing's `.serialized` trait does not span sibling suites — even within the same test target

**What happened:** Sortie 10 landed `ShipCommandTests` with `@Suite(.serialized)` and it passed locally. On a subsequent `make test` run the CLI test target flaked. Investigation (commit `2f0f0805`, `sortie-10-serialize`) revealed that `ToolCheckTests` and `ShipCommandTests` were each `.serialized` individually, but Swift Testing happily ran them in parallel *with each other* — and both save/restore process-wide `PATH`. Suite A's PATH mutation clobbered suite B's restore, and vice versa.
**What was built to handle it:** New `ProcessEnvironmentSuite` (`.serialized` parent) in `Tests/AcervoToolTests/ProcessEnvironmentSuite.swift`; `ToolCheckTests` and `ShipCommandTests` nested under it via the `extension ParentSuite { @Suite("Child") struct Child {} }` pattern.
**Should we have known this?** **Partially.** Iteration 01's brief § Section 1 item 5 documented this exact behavior for `MockURLProtocolSuite` and established the nesting pattern. But that rule was scoped in planners' minds to `ComponentRegistry.shared` racing — not to process-wide env state. Sortie 10 inherited an adjacent wall.
**Carry forward:** The de-facto repo rule is now: **any test suite that reads or writes process-wide state (ComponentRegistry.shared, customBaseDirectory, PATH, R2_*, HF_TOKEN) must nest under a shared `.serialized` parent suite scoped to that state class.** There are now two such anchors: `MockURLProtocolSuite` / `CustomBaseDirectorySuite` (library tests) and `ProcessEnvironmentSuite` (CLI tests). Codify this in `CLAUDE.md` or an ADR before iteration 03.

### 3. `ComponentRegistryIsolation` helper landed as a proof-of-use, not a full migration

**What happened:** Sortie 2's tasks specified *"apply [the `withIsolatedComponentRegistry` helper] to one representative test... as a proof-of-use; do not convert every call site in this sortie."* That is exactly what shipped — one call site (`HydrateComponentTests.hydrateComponentPopulatesRegistry`). Every other `defer { unregisterComponent(...) } + UUID suffix` call site remained.
**What was built to handle it:** The helper exists at `Tests/SwiftAcervoTests/Support/ComponentRegistryIsolation.swift` (100 lines) with both `withIsolatedAcervoState` and `withIsolatedComponentRegistry` variants. FOLLOW_UP.md was updated to note it as available.
**Should we have known this?** Yes, by design — the sortie scoped itself honestly. The discovery is that the follow-through (migrating the rest of the call sites) is now a deferred P2-style task with no owner.
**Carry forward:** Either schedule a cleanup sortie to migrate the remaining defer-pattern sites, or accept that two isolation patterns will coexist in the test suite indefinitely. If the latter, add a comment to `ComponentRegistryIsolation.swift` explicitly noting which pattern is preferred for new tests.

### 4. Sortie 15's audit surfaced that all four integration test files are unreachable in CI

**What happened:** `AcervoToolIntegrationTests/` contains `CDNRoundtripTests.swift`, `HuggingFaceDownloadTests.swift`, `ManifestRoundtripTests.swift`, and `ShipCommandTests.swift`. All four are gated on `R2_*` and `HF_TOKEN` secrets. Sortie 15's audit of `.github/workflows/` confirmed: no job invokes them. `tests.yml` runs `make test` (library tests only). `mirror_model.yml` provides the credentials but never calls `make test-acervo-integration`. These tests only run locally.
**What was built to handle it:** New subsection under `TESTING_REQUIREMENTS.md § "CLI command coverage"` titled **"CI integration test gating"**, plus a new P1 entry `"AcervoToolIntegrationTests unreachable in CI"` with explicit remediation steps.
**Should we have known this?** The plan anticipated Sortie 15 might surface this; it was the whole point. But the discovery is concrete: **the integration tests provide zero CI signal today**.
**Carry forward:** The P1 is filed. Either add a workflow job that runs `xcodebuild test -only-testing:AcervoToolIntegrationTests` with secrets, or delete the integration tests. Shipping v0.8.0 without closing this gap means the CLI's CDN/HF happy paths are untested in CI.

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Sortie 1 delivered the session-injection refactor cleanly in one pass

**What happened:** Threaded `session: URLSession = SecureDownloadSession.shared` through `streamDownloadFile`, `fallbackDownloadFile`, `downloadFile`, and `downloadFiles` with the default preserving every call site. Added a focused smoke test (`DownloadSessionInjectionTests.swift`) that verifies `MockURLProtocol.requestCount >= 1` end-to-end. One commit (`d96f2e7`), no follow-ups.
**Right or wrong?** Right. Exactly the scope demanded, no creep, foundation for Sorties 7–9.
**Evidence:** 55-line diff in `AcervoDownloader.swift`, 78-line new test file, zero grep hits for bare `URLSession.shared` or `SecureDownloadSession.shared` after the refactor.
**Carry forward:** The pattern of "add a `session:` parameter with existing default, preserving all call sites" is now the canonical move when test-injection needs to be introduced to a core path. Reuse.

#### 2. Sortie 8's third attempt correctly diagnosed and owned the mis-target

**What happened:** After two attempts exercised the wrong integrity gate, the third commit (`a24c59a`) opened with a candid explanation: *"Previous Sortie 8 commit (ebfe111) mis-targeted — its test exercised the streaming-pass check at AcervoDownloader.swift:401-411, not the registry-level check at Acervo.swift:1560-1576."* The fix renamed the original test to accurately describe what it does, then added a *new* test that inlines the registry loop directly. It also filed a P1 follow-up note tying the root-cause to Sortie 1's session injection.
**Right or wrong?** Right. This is the textbook recovery shape: diagnose honestly, preserve the already-landed work by re-labeling it, add the missing coverage with the honest technique available.
**Evidence:** `sortie-8-fix` commit message reads like a post-mortem. Final `RegistryIntegrityCheckTests.swift` is 317 lines with both tests and mutation-check comments pinning both production line ranges.
**Carry forward:** When a sortie misses its target, the fix commit should (a) name the miss, (b) preserve the earlier work where possible, (c) file the root-cause as a follow-up. Sortie 8's recovery is the pattern.

#### 3. Sortie 10-serialize was a fast post-landing patch, not a rollback

**What happened:** The PATH-race flake surfaced *after* Sortie 10 and 12 had both landed (both reference `PATH`/env state). The fix (`2f0f0805`) didn't revert either sortie — it added a new `.serialized` parent and re-nested the two affected suites. 29 lines added, 14 deleted, across 3 files.
**Right or wrong?** Right. No commits were reverted, no tests were rewritten, and the fix was smaller than the underlying sorties.
**Evidence:** `2f0f0805` touches only `ProcessEnvironmentSuite.swift` (new), `ShipCommandTests.swift` (+16/-7), `ToolCheckTests.swift` (+16/-7). No source files modified.
**Carry forward:** Flakes that surface after sortie landing should be fixed forward with minimal patches, not rolled back. Sortie 10-serialize is the pattern.

### What the Agents Did Wrong

#### 1. Sortie 8 burned two attempts on the wrong code path

**What happened:** Attempts 1 and 2 both wrote tests that exercised `AcervoDownloader.swift:401-411` (streaming pass) when the exit criteria demanded `Acervo.swift:1560-1576` (registry pass). The first attempt appears to have been written without reading the distinction carefully; the second attempt tried to route through `downloadComponent` with a mocked session and *still* hit the streaming pass because the file-body download doesn't accept session injection.
**Right or wrong?** Wrong — but the root cause is on the planner (see Section 3 below), not the agent. The agent should have read the exit criterion's grep check (`grep -n "Registry-level second pass:" <test-file>`) as a forcing function to verify target before claiming done. Attempt 2 shipped with the comment pointing at both line ranges but the test body only exercising one.
**Evidence:** Three commits for Sortie 8 (`dea900c`, `ebfe111`, `a24c59a`); ~300 lines of churn across the three; final delivery is an inline surrogate, not a black-box test.
**Carry forward:** When a sortie's exit criterion includes a source-line mutation check, the agent should construct a deliberate mutation (e.g., comment out the target lines, re-run the test, confirm failure) as part of verification — not just grep for the comment text.

#### 2. Sortie 10 shipped without cross-suite serialization, requiring a follow-up patch

**What happened:** Sortie 10 landed `ShipCommandTests` with `@Suite(.serialized)` scoped to just that suite. It passed `make test` locally. But `ToolCheckTests` (pre-existing) also mutates `PATH`. When `make test` ran them in parallel, PATH races surfaced. Sortie 10 didn't check whether any *other* suite touches the same process state.
**Right or wrong?** Wrong, but mildly. The sortie's exit criteria didn't require it to audit sibling suites, so the agent followed the plan.
**Evidence:** Sortie 10 commit (`26495b6`) shipped at 11:15, sortie-10-serialize (`2f0f0805`) landed at 11:19 — 4 minutes later. The race was surfaced by subsequent sortie validation runs, not by Sortie 10's own `make test`.
**Carry forward:** When a sortie adds tests that mutate process-wide state (PATH, env vars, globals), its exit criteria should include `grep -En "setenv|setenv\(|environment\[|PATH" Tests/**/*.swift` to identify other consumers and verify they share a `.serialized` parent.

### What the Planner Did Wrong

#### 1. Sortie 8's exit criteria assumed session-injection into `downloadFiles` was available

**What happened:** Sortie 8 Tasks 1–3 describe routing through `downloadComponent` with a mocked URLSession. This is physically impossible in the current code. Iteration 01's brief flagged this in Section 1 item 3 with explicit language, and that brief is preserved at `Docs/complete/desert_blueprint_01_BRIEF.md`. The TRIPWIRE GAUNTLET plan's author referenced iteration 01 indirectly (via FOLLOW_UP.md) but did not translate the "carry forward" into a Sortie 8 design that accounts for it.
**Right or wrong?** Wrong. This cost ~300 lines of agent churn and a mis-targeted first attempt.
**Evidence:** Compare iteration 01 brief Section 1 item 3 against the TRIPWIRE GAUNTLET plan's Sortie 8 Tasks. The constraint is known; the plan ignores it.
**Carry forward:** Before writing a sortie plan, read every previous brief in `Docs/complete/` and explicitly check each carry-forward against the new sortie's Tasks. Previous briefs are load-bearing planning inputs, not historical curiosities.

#### 2. Sortie 10–14 plan did not cover process-wide state serialization for the CLI test target

**What happened:** The `AcervoToolTests/` target is a different context than `SwiftAcervoTests/`. Iteration 01's `MockURLProtocolSuite` / `CustomBaseDirectorySuite` patterns don't apply there because the CLI tests don't touch the download session or `customBaseDirectory` — they touch PATH, R2_*, and HF_TOKEN. The plan didn't anticipate this and didn't schedule a "ProcessEnvironmentSuite" equivalent for Sorties 10–14.
**Right or wrong?** Wrong, mildly. The fix was small (29 lines), but the need was predictable from the plan (5 sorties all writing CLI tests that shell out).
**Evidence:** Neither the Sortie 10 plan nor Sorties 11–14 plans mention process-wide state serialization. The fix landed as an out-of-band patch.
**Carry forward:** When a plan introduces a new test target (`AcervoToolTests` is new to this iteration), dedicate a foundational sortie analogous to Sortie 2 that establishes isolation primitives for whatever state the new target touches.

#### 3. Dynamic dispatch was claimed but not exercised — SUPERVISOR_STATE.md is stuck at Wave 1

**What happened:** `SUPERVISOR_STATE.md` still shows Sorties 1, 2, 3 as `DISPATCHED` (attempt 1/3, pending task IDs) from mission init. Not one state transition was ever written. Yet all 15 sorties completed. The supervisor's state-write-before-dispatch invariant was not honored.
**Right or wrong?** Wrong for crash-safety, but it didn't matter — the mission didn't crash. State file is cosmetic-only as-executed.
**Evidence:** `SUPERVISOR_STATE.md` shows 3 DISPATCHED / 12 PENDING; git log shows all 15 landed.
**Carry forward:** Either enforce state writes by tooling (hook that fails dispatch if SUPERVISOR_STATE.md hasn't been updated within N seconds), or stop claiming crash-safety in the supervisor docs. Either option is honest; the current state is not.

---

## Section 3: Open Decisions

### 1. Should we thread `session:` through `AcervoDownloader.downloadFiles`?

**Why it matters:** Without it, Sortie 8's registry-level integrity test is a surrogate (inline loop copy), not a black-box test. Any future mission that wants end-to-end stubbed file downloads hits the same wall. This is the third mission where this constraint has mattered.
**Options:**
- **A.** Dedicated 1-sortie refactor that adds `session:` to `downloadFiles` and its internal callers, defaulting to `SecureDownloadSession.shared`. ~30 minutes of work. Mirrors Sortie 1's pattern.
- **B.** Leave it. Accept surrogate tests for any production path behind `downloadFiles`. Document this as a load-bearing convention.
- **C.** Refactor `downloadFiles` into a protocol-based design that can be replaced wholesale in tests. Larger scope, wider blast radius.
**Recommendation:** **A.** Cheap, consistent with Sortie 1's pattern, unblocks honest black-box testing of every remaining untested path. Mission name suggestion: OPERATION CLEAR CHANNEL.

### 2. Should the `ComponentRegistryIsolation` helper be applied to every `defer { unregister }` call site?

**Why it matters:** Two patterns now coexist in the library test suite. Mixed patterns invite drift. Every new test file has to decide.
**Options:**
- **A.** Schedule a cleanup sortie that migrates every `defer { unregisterComponent(...) }` site to `withIsolatedComponentRegistry { ... }`. 3–5 files, no behavior change.
- **B.** Add a `// PREFERRED: use withIsolatedComponentRegistry` banner comment to the helper file and leave legacy sites alone. Migrate incrementally as tests are touched.
**Recommendation:** **B.** Lower risk, zero churn. The helper exists; new tests can adopt it; legacy tests keep working.

### 3. Should we actually run `AcervoToolIntegrationTests` in CI, or delete them?

**Why it matters:** The P1 Sortie 15 filed is a fork in the road. Either these four test files are worth running (and CI should run them with org secrets), or they're not (and they're dead code providing zero signal). Shipping v0.8.0 without a decision means carrying four unreachable test files into the release tag.
**Options:**
- **A.** Add a job to `tests.yml` (or new `integration-tests.yml`) that runs `xcodebuild test -only-testing:AcervoToolIntegrationTests` with `R2_*` and `HF_TOKEN` secrets. Job must be PR-gated to avoid credential leaks on fork PRs.
- **B.** Delete the four integration test files. Document in `TESTING_REQUIREMENTS.md` that CDN/HF happy paths are tested manually before each release.
- **C.** Keep them, but rename the directory to `ManualIntegrationTests/` to make the "not-in-CI" status explicit.
**Recommendation:** **A** if the team has org secrets available; **C** otherwise. **B** is honest but surrenders coverage.

### 4. Should `PATH`/env-var serialization be a repo-wide convention codified in CLAUDE.md?

**Why it matters:** This is the second mission where parallel-suite serialization surprised us (iteration 01 for ComponentRegistry; this one for PATH). Iteration 03 is likely to hit a third class of shared state.
**Options:**
- **A.** Add a "Test Isolation Conventions" section to `CLAUDE.md` that enumerates every parent suite (`MockURLProtocolSuite`, `CustomBaseDirectorySuite`, `ProcessEnvironmentSuite`) and the state class each serializes. Future sorties reference this section.
- **B.** Leave it. Each sortie discovers the convention on first collision.
**Recommendation:** **A.** Cheap, high-leverage, prevents a fourth mission from relearning the lesson.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Thread `session:` through file-download path | opus | 1 | Yes | Clean refactor; foundation for Layer 3 |
| 2 | Test-isolation primitive (customBaseDirectory + registry) | opus | 1 | Yes | Proof-of-use landed; full migration deferred |
| 3 | Promote `fetchManifest(..., session:)` overloads to public | sonnet | 1 | Yes | Trivial additive API change |
| 4 | Behavior tests for `fetchManifest(for:)` via public API | sonnet | 1 | Yes | |
| 5 | Manifest error-mode tests (decode / integrity / version) | sonnet | 1 | Yes | |
| 6 | HydrationCoalescer error-path + re-fetch tests | sonnet | 1 | Yes | |
| 7 | E2E `downloadComponent` auto-hydration test | sonnet | 1 | Yes | Scoped to hydrate-then-assert, not full download |
| 8 | Registry-level SHA-256 cross-check failure test | sonnet | 3 | **Partial** | Two mis-targeted attempts + fix commit. Final test is an inline surrogate, not a black-box registry test |
| 9 | `ensureAvailable(files: [])` empty-files tests | sonnet | 1 | Yes | |
| 10 | `ShipCommand.swift` unit tests | sonnet | 1 + patch | **Partial** | Required `sortie-10-serialize` cross-suite fix |
| 11 | `DownloadCommand.swift` unit tests | sonnet | 1 | Yes | |
| 12 | `UploadCommand.swift` unit tests | sonnet | 1 | Yes | |
| 13 | `VerifyCommand.swift` unit tests | sonnet | 1 | Yes | |
| 14 | `ManifestCommand.swift` unit tests | sonnet | 1 | Yes | Includes determinism test |
| 15 | Audit + document CI gating for integration tests | sonnet | 1 | Yes | Surfaced a new P1 |

**Tally:** 13/15 first-pass accurate (87%). 2/15 required follow-up work (Sortie 8 with 3 commits; Sortie 10 with 1 patch commit). Zero FATAL. Zero regressions in existing tests.

Model assignments from SUPERVISOR_STATE.md cover Sorties 1–3 only; the rest are inferred from commit cadence and complexity.

---

## Section 5: Harvest Summary

The single most important finding: **iteration 01's brief flagged that `AcervoDownloader.downloadFiles` is not session-injectable, but iteration 02's plan did not act on it — and Sortie 8 hit the same wall twice before settling for an inline surrogate test.** The code still cannot be fully tested from the outside for any path that flows through `downloadFiles`. Every other discovery in this brief (cross-suite serialization for PATH, the partial migration of the registry isolation helper, integration tests unreachable in CI) is smaller. The next iteration should open with OPERATION CLEAR CHANNEL or an equivalent: one sortie to thread `session:` through `downloadFiles`, unblocking honest black-box tests everywhere downstream. Everything else in this brief is follow-on cleanup.

---

## Section 6: Files

### Preserve (read-only reference for next iteration)

| File | Branch | Why |
|------|--------|-----|
| `Docs/complete/tripwire-gauntlet-02-brief.md` | `development` after merge | Authoritative record of this iteration's findings; feeds iteration 03 planning |
| `Docs/complete/desert_blueprint_01_BRIEF.md` | `development` (already archived) | Prior iteration's brief; its "carry forward" items should be re-checked against iteration 03 plan |
| Mission branch `mission/tripwire-gauntlet/02` | local-only | Full commit-level detail of every sortie, in case line-level context is needed |

### Discard (cleaned up per brief workflow)

| File | Why it's safe to lose |
|------|----------------------|
| `SUPERVISOR_STATE.md` | Stale; stuck at Wave 1 DISPATCHED state; mission actually completed. No authoritative content beyond mission metadata, which is preserved in EXECUTION_PLAN.md frontmatter |
| `EXECUTION_PLAN.md` | Mission consumed; content preserved in git history on the mission branch. Iteration 03 will have its own plan |
| `COMPLETE_OPERATION_SWIFT_ASCENDANT_01.md` (orphan) | From a two-missions-ago operation (2026-04-17). Never archived. Not this mission's responsibility but noted here — user may want to move it to `Docs/complete/` for tidiness |
| `OPERATION_SWIFT_ASCENDANT_01_BRIEF.md` (orphan) | Same as above. Two missions old. Archive or delete at user discretion |

---

## Iteration Metadata

**Starting point commit:** `68f5456` (`docs+api: overload fetchManifest(for:) / fetchManifest(forComponent:) and sync v0.8.0 docs`)
**Mission branch:** `mission/tripwire-gauntlet/02`
**Final commit on mission branch:** `4b7cb2c` (`sortie-15: audit + document CI gating for AcervoToolIntegrationTests`)
**Rollback target:** N/A — verdict is *keep the code*. Mission branch merges into `development`.
**Next iteration branch (if iteration 03 is scheduled):** `mission/tripwire-gauntlet/03` cut from `development` after merge, OR a new operation named OPERATION CLEAR CHANNEL targeting the `downloadFiles` session-injection carry-forward.

---

## Recommended Next Actions

1. Merge `mission/tripwire-gauntlet/02` → `development`.
2. Triage the P1 filed by Sortie 15 before tagging v0.8.0 (Section 3, Open Decision #3).
3. Schedule OPERATION CLEAR CHANNEL (or equivalent) to address the `downloadFiles` session-injection carry-forward before the next testing mission (Section 3, Open Decision #1).
4. Add "Test Isolation Conventions" section to `CLAUDE.md` codifying the three parent-suite patterns (Section 3, Open Decision #4).
5. Investigate why `SUPERVISOR_STATE.md` transitions were not written during execution (Section 2 § Planner #3).
