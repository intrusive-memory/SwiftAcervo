# Iteration 01 Brief — OPERATION SHARED PANTRY

> **Terminology**: A *mission* is the definable scope of work. A *sortie* is an atomic agent task within that mission. A *brief* is this post-mission review.

**Mission:** Make "many components, one CDN manifest" a first-class supported shape in SwiftAcervo's component-keyed contract.
**Branch:** `mission/shared-pantry/01`
**Starting Point Commit:** `1ec90e7` (Release v0.11.1: register idempotent short-circuit + version normalization)
**Sorties Planned:** 7
**Sorties Completed:** 7
**Sorties Failed/Blocked:** 0
**Retries:** 0
**Cost (relative):** 7× sonnet dispatches, ~0× haiku, 0× opus
**Outcome:** **Complete**
**Verdict:** **KEEP THE WORK. Do NOT roll back.** Commit and ship through the normal release flow.

---

## Verdict in plain language — Do we roll back?

**No.** Rollback is the wrong move here. Reasoning:

1. **Every sortie completed first-try.** Zero retries, zero FATAL escalations, zero context exhaustion. The only "drift" detected was Sortie 1's macOS-case-insensitive `docs/` vs `Docs/` slip, which landed in the right place because the repo uses `Docs/` and the FS reconciled it. Linux CI would have been fine.

2. **The deliverables are minimal and correct.** Sources/ diff is 46 inserted lines across 2 files (`Acervo.swift` + `ComponentDescriptor.swift`). No new public symbols. The R4 fix is the smallest possible change: replace whole-dir-remove with per-file iterate + upward-prune. No refactor, no scope creep, no premature abstraction.

3. **Tests are green.** 537 unit tests + 69 CLI tool tests pass. 13 new bundle tests cover R1–R6 (R1 ×2, R2 ×2, R3 ×2, R4 ×3, R5 ×1, R6 ×3). One operator-attested smoke test gated behind `INTEGRATION_TESTS`.

4. **There is no garbage to discard.** No half-finished features, no temporary scaffolding, no over-engineered abstractions. Even the audit doc is keepable as a contract specification (recommend moving from `Docs/incomplete/` → `Docs/` after release).

5. **Rollback would actively hurt you.** HEAD is still at `1ec90e7`. The mission branch has zero commits. The 6 modified + 7 untracked files exist only in the working tree. A `git checkout 1ec90e7 -- .` or `git reset --hard 1ec90e7` would erase the entire mission's output. That's destructive, not iterative.

The only thing left is git hygiene: **commit the work to `mission/shared-pantry/01`**, then merge through the development branch per repo convention. After that, run `/ship-swift-library` to bump 0.11.1 → 0.12.0 and tag.

---

## Section 1: Hard Discoveries

Constraints discovered through collision with reality during this mission.

### 1. `deleteComponent` removed the whole `<slug>/` directory

**What happened:** Audit (Sortie 1) found `Acervo.swift:1842` called `FileManager.removeItem(at: slugDir)`. For non-bundle components this was harmless (each component had its own slug); for bundle components it was silent destruction — deleting one component wiped its siblings.

**What was built to handle it:** Sortie 5 replaced the body of `deleteComponent` with a per-file iteration, then an upward prune of empty subdirectories, removing the slug directory only when it ends up empty. 38-line change, no new public surface.

**Should we have known this?** Partially. The component-vs-bundle distinction was implicit in the architecture — `ComponentDescriptor.repoId` was always intended to be many-to-one — but the delete path predated the bundle use case. SwiftVinetas's Flux2Engine breakage made it visible.

**Carry forward:** When the registry deduplicates on key A but a downstream operation acts on derived key B, every operation must explicitly use key A's scope. The bundle pattern is now first-class and documented; new operations that touch on-disk files must follow `descriptor.files` iteration, not slug-dir blast radius.

### 2. `performHydration` overwrites `descriptor.files` with the full manifest

**What happened:** `Acervo.swift:1611` replaces `descriptor.files` with all files from the CDN manifest when the descriptor is registered un-hydrated. For non-bundle components this is the design (auto-discover the file list). For bundle components it silently negates the file scope.

**What was built to handle it:** Doc-comment on `ComponentDescriptor`'s file-list initializer stating that bundle descriptors must always be registered pre-hydrated. Code-comment at the gap site explaining why the behavior is intentional (and incompatible) for bundles.

**Should we have known this?** Yes, on closer reading of `Acervo+Hydration.swift`. The audit caught it on first pass. We considered adding a runtime guard (`if descriptor.isHydrated { return }`); rejected because `performHydration` is only called when `needsHydration == true`, so the guard would be dead code.

**Carry forward:** The bundle pattern requires explicit `files:` registration. This is a contract constraint, not a runtime check. Future plugin authors will read the doc-comment.

### 3. `ComponentHandle.url(for:)` is FS-existence-only, not scoped to declared files

**What happened:** Sortie 3 (R2 tests) discovered that `ComponentHandle.url(for: <path>)` returns a URL whenever the file exists on disk, regardless of whether the path is in `descriptor.files`. If a sibling bundle component has downloaded `vae/config.json` into the same slug directory, calling `transformerHandle.url(for: "vae/config.json")` returns that URL.

**What was built to handle it:** Nothing. The R2 tests assert behavior through the *documented* access methods (`availableFiles()`, `url(matching:)`) which ARE scoped. `url(for:)` and `rootDirectoryURL` are filesystem escape hatches; the audit verdict (R2 HONORED) accepted this because the documented access methods are the contract surface.

**Should we have known this?** Yes — easy to confirm by reading `ComponentHandle.swift`. Audit caught it but didn't flag as a gap.

**Carry forward:** **Open decision** — see Section 3, item 1.

### 4. `diskSize(forComponent:)` doesn't actually exist

**What happened:** EXECUTION_PLAN.md Sortie 1 task 8 said "Trace `Acervo.diskSize(forComponent:)` and resolve open question Q2". REQUIREMENTS-manifest-as-bundle.md also referenced it. It does not exist in the codebase.

**What was built to handle it:** Sortie 1 noted the absence in its summary; Q2 was resolved hypothetically ("when implemented, sum declared files only"). No source code was written to add the function.

**Should we have known this?** Yes — should have been caught in plan refinement. A grep of `Sources/` would have surfaced the absence.

**Carry forward:** During plan refinement, every API the plan says to "trace" or "audit" should be confirmed to exist via a grep before the plan is locked.

---

## Section 2: Process Discoveries

### What the agents did right

#### 1. The fixture factory paid off across three downstream sorties

**What happened:** Sortie 2 was instructed to "expose the bundle fixture as a Swift symbol callable from other test files." Sortie 2 produced `BundleFixtures.fluxStyleManifest()`, `.makeResponder()`, and `.bundleDescriptors()`. Sorties 3, 4, and 7 reused all three.

**Right or wrong?** Right. The exit criterion paid for itself.

**Evidence:** Zero duplicated fixture code across `BundleComponentTests.swift` (7 R1–R5 tests + 6 R4/R6 tests) and `BundleComponentSmokeTests.swift`.

**Carry forward:** When a sortie produces a primitive that downstream sorties will consume, make "expose as a callable symbol" an explicit exit criterion, not just an implicit assumption. It worked here because the prompt was explicit.

#### 2. R4 tests written before R4 fix — punch-list pattern

**What happened:** Sortie 4 wrote 3 R4 tests against the *intended* behavior, ran `make test`, captured the 6 assertion failures with full messages, and appended them to a `## Test results` section in the audit doc. Sortie 5 read this section and used it as a concrete checklist for the source fix.

**Right or wrong?** Right. Test-first within a multi-sortie mission worked beautifully.

**Evidence:** Sortie 5 needed 38 lines to fix `deleteComponent`. No back-and-forth, no ambiguity about what "fixed" meant.

**Carry forward:** For any "fix a behavioral gap" sortie, split into "write failing tests + capture failures" → "make them pass." Each sortie has one clear goal.

#### 3. Trust-but-verify on every sortie report

**What happened:** After each sortie's task notification, ran a small set of grep-based exit-criteria checks before marking COMPLETED. Caught the `Docs/` vs `docs/` casing mismatch on Sortie 1 (cheap to fix forward; would have broken Linux CI if propagated).

**Right or wrong?** Right.

**Evidence:** ~10 seconds of `grep` per sortie, caught one real issue, gave high confidence in the rest.

**Carry forward:** Keep doing this. It's not duplication of agent work — it's verification of agent reporting. Different thing.

### What the agents did wrong

#### 4. Sortie 7's tokenizer-file selection is best-effort

**What happened:** Sortie 7's smoke test picks `tokenizer_config.json` based on standard HuggingFace layout. Whether `black-forest-labs/FLUX.2-klein-4B` actually has it at root is unverified. If it doesn't, the operator gets `AcervoError.fileNotInManifest` and has to substitute.

**Right or wrong?** Slightly wrong. The agent had a recon option (`acervo manifest --print`) to verify the file existence and SHA — it chose not to use it. The risk is bounded (smoke test, operator-attested) but it's avoidable friction.

**Evidence:** Sortie 7's final report explicitly says "If the live CDN manifest does not include `tokenizer_config.json`, the operator should substitute."

**Carry forward:** Smoke tests against real systems should verify resource existence ahead of time, not assume it. Add this to plan refinement: "any test referring to specific live-system files must be preceded by a recon step verifying those files exist."

### What the planner did wrong

#### 5. Plan referenced a non-existent API (`diskSize(forComponent:)`)

**What happened:** Plan task 8 of Sortie 1 asked the agent to trace a function that doesn't exist. Sortie 1 noted the absence; no harm done, but it wasted a small amount of attention.

**Right or wrong?** Wrong, mildly.

**Evidence:** Sortie 1's "Anything surprising" report flagged it.

**Carry forward:** Plan refinement should grep `Sources/` for every API name the plan asks to audit/trace.

#### 6. Plan referenced `docs/` (lowercase) when repo uses `Docs/`

**What happened:** EXECUTION_PLAN.md said `docs/incomplete/manifest-as-bundle-audit.md`. Repo convention is `Docs/`. macOS case-insensitivity hid the slip. Linux CI would have failed.

**Right or wrong?** Wrong, low impact.

**Evidence:** `git ls-files` shows all existing entries use `Docs/`.

**Carry forward:** Plan refinement should validate every path it specifies against `git ls-files` for existing convention.

#### 7. Planned parallelism = 0 was correctly diagnosed and reported honestly

**What happened:** Refinement Pass 3 honestly recorded that Sorties 3 and 4 are nominally parallel-eligible but practically serialized due to (a) build constraint, (b) file contention. No fake parallelism speedup was claimed.

**Right or wrong?** Right. (Listed under planner-wrong only because I want to highlight it as the kind of thing planners often get wrong by being optimistic.)

**Evidence:** Plan's Parallelism Structure section.

**Carry forward:** Continue calling out "zero practical parallelism" rather than fabricating splits. Honest is better than fast.

---

## Section 3: Open Decisions

### 1. `ComponentHandle.url(for:)` — escape hatch or guarded?

**Why it matters:** A bundle consumer holding a transformer handle could call `handle.url(for: "vae/config.json")` and get a real URL if the sibling component has been ensured-ready. This is not the documented contract, but it's reachable. If a future caller does this and the sibling is later deleted, the URL will dangle without warning.

**Options:**
- **A.** Leave as-is. Document `url(for:)` and `rootDirectoryURL` as documented escape hatches.
- **B.** Add a `descriptor.files.contains(path)` guard inside `url(for:)`, returning `nil` for non-declared paths.
- **C.** Mark `url(for:)` and `rootDirectoryURL` as `@available(*, deprecated)` and provide only `url(matching:)` going forward.

**Recommendation:** **A** for v0.12.0 (don't change behavior in a fix release). Document the escape hatches in `API_REFERENCE.md` (Sortie 6 should have done this; small follow-up). Revisit B/C in v0.13 if a real consumer hits the issue.

### 2. Should we add a regression test for un-hydrated bundle registration?

**Why it matters:** The audit identified that registering a bundle component un-hydrated (no `files:` argument) causes hydration to overwrite `files` with the full manifest. We added a doc-comment but no test. A future refactor of `performHydration` could break the hydration assumption without the test catching it.

**Options:**
- **A.** Add a single test in v0.12.0 asserting that un-hydrated bundle registration produces a descriptor with `files == manifest.allFiles` (current behavior — pin it as a known limitation).
- **B.** Defer; rely on the doc-comment.

**Recommendation:** **A**, but as a follow-up PR (not v0.12.0 scope). Cheap insurance, and it pins the failure mode for future authors.

### 3. Audit doc location after release

**Why it matters:** The audit doc lives at `Docs/incomplete/manifest-as-bundle-audit.md`. Once the contract is shipped, it's no longer "incomplete" — it's the authoritative spec.

**Options:**
- **A.** Move to `Docs/contracts/manifest-as-bundle.md` (or similar) as a contract spec.
- **B.** Move to `Docs/complete/operation-shared-pantry-01/` via the standard `clean` archival.
- **C.** Distill into `API_REFERENCE.md` and discard the audit doc.

**Recommendation:** **B** for now (standard `clean` archival keeps the mission record together). The contract is already in `API_REFERENCE.md` for plugin authors; the audit doc is mission history, not user-facing reference.

---

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | Audit R1–R6 | sonnet | 1 | **Yes** | Verdicts and citations were the spec for everything downstream. Path-casing slip auto-resolved by macOS FS. Phantom `diskSize` API noted. |
| 2 | Bundle fixtures + R1/R3 tests | sonnet | 1 | **Yes** | Fixture factory reused by Sorties 3, 4, 7. Zero rework. |
| 3 | R2/R5 tests | sonnet | 1 | **Yes** | Discovered `url(for:)` is FS-existence-only — surfaced in report, did not assert it (correct call). |
| 4 | R4/R6 tests | sonnet | 1 | **Yes** | R4 failures captured as Sortie 5 punch list — exemplary handoff. R6 stderr capture worked first try. |
| 5 | R4 source fix + R1 doc | sonnet | 1 | **Yes** | Smallest possible change. Option (b) hydration guard correctly rejected as dead code. |
| 6 | Docs + CHANGELOG | sonnet | 1 | **Yes (caveat)** | Cross-cutting markdown additions matched repo conventions. Did not document `url(for:)` / `rootDirectoryURL` as escape hatches — minor follow-up. |
| 7 | Smoke test | sonnet | 1 | **Yes (caveat)** | `tokenizer_config.json` is best-effort guess; operator may need to substitute. Skip-when-unset pattern is exact-match with repo convention. |

**Aggregate:** 7/7 first-try success. No retries. Two minor follow-ups identified (open decisions 1 & 2 above), both deferrable past v0.12.0.

---

## Section 5: Harvest Summary

The single most important thing this mission revealed: **SwiftAcervo's component-keyed APIs were already 4-out-of-6 honoring the bundle contract.** R2, R3, R5, R6 needed only test pinning. The architecture was right; the implementation had two specific gaps (R4 destruction, R1 hydration) and one undocumented escape hatch (`url(for:)`). One small fix, one doc-comment, and a contract spec made the bundle pattern first-class.

For the next iteration: start every mission with an audit-only sortie. Doing the audit first turned what could have been a sprawling refactor into a 38-line surgical change. Tests written against the *intended* contract before the source fix made the fix unambiguous.

---

## Section 6: Files

### Preserve (read-only reference for next iteration)

| File | Branch | Why |
|------|--------|-----|
| `OPERATION_SHARED_PANTRY_01_BRIEF.md` | `mission/shared-pantry/01` | This brief, archived by `clean` |
| `Docs/incomplete/manifest-as-bundle-audit.md` | `mission/shared-pantry/01` | R1–R6 audit + Q1–Q5 resolutions; archived by `clean` |
| `EXECUTION_PLAN.md` | `mission/shared-pantry/01` | Plan as executed; archived by `clean` |
| `SUPERVISOR_STATE.md` | `mission/shared-pantry/01` | Decisions Log + Sortie roster; archived by `clean` |
| `REQUIREMENTS-manifest-as-bundle.md` | `mission/shared-pantry/01` | Original requirements; archived by `clean` |

### Discard (will not exist after rollback) — N/A: NOT ROLLING BACK

| File | Why it's safe to lose |
|------|----------------------|
| _(empty — this mission's verdict is KEEP, not DISCARD)_ | |

If the user changes their mind and rolls back, the entire working tree (6 modified + 7 untracked files) would be discarded. Listing them here for audit:

| File | Status | Lines |
|------|--------|-------|
| `Sources/SwiftAcervo/Acervo.swift` | modified | +36 / -2 |
| `Sources/SwiftAcervo/ComponentDescriptor.swift` | modified | +10 |
| `API_REFERENCE.md` | modified | +117 |
| `ARCHITECTURE.md` | modified | +4 |
| `CHANGELOG.md` | modified | +16 |
| `DESIGN_PATTERNS.md` | modified | +38 |
| `Tests/SwiftAcervoTests/Fixtures/BundleFixtures.swift` | new | 200 |
| `Tests/SwiftAcervoTests/BundleComponentTests.swift` | new | 1076 |
| `Tests/SwiftAcervoTests/BundleComponentSmokeTests.swift` | new | (smoke) |

---

## Section 7: Iteration Metadata

**Starting point commit:** `1ec90e7ad72c1993d357102ff6af86bf4919b88f` (Release v0.11.1: register idempotent short-circuit + version normalization)
**Mission branch:** `mission/shared-pantry/01`
**Final commit on mission branch:** _(none — work is uncommitted)_
**Rollback target:** `1ec90e7` (same as starting point — would be destructive at current state because work is uncommitted)
**Next iteration branch:** _N/A — mission complete, no iteration needed_

**Critical git note:** All sortie work is uncommitted in the working tree. Before any further action (clean, ship, rollback), the user should:

```bash
git -C /Users/stovak/Projects/SwiftAcervo add Sources/ Tests/ Docs/ \
    API_REFERENCE.md ARCHITECTURE.md CHANGELOG.md DESIGN_PATTERNS.md
git -C /Users/stovak/Projects/SwiftAcervo commit -m "OPERATION SHARED PANTRY: bundle component contract"
```

(Supervisor will not commit on the user's behalf — git operations on shared state require explicit authorization.)
