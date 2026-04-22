# Iteration 01 Brief — OPERATION DESERT BLUEPRINT

> **Terminology reminder**: A *mission* is the definable scope of work. A *sortie* is an atomic agent task within that mission. A *brief* is the post-mission review that harvests lessons before the next iteration.

**Mission:** Eliminate the duplicated `files:` list that every consumer of SwiftAcervo currently hardcodes by fetching the CDN manifest on first use and populating the descriptor itself.
**Branch:** `mission/desert-blueprint/01`
**Starting Point Commit:** `78f72a9` (`chore: archive prior mission state and superseded TODO`)
**Sorties Planned:** 8 (7 mandatory + 1 conditional)
**Sorties Completed:** 7 + 1 continuation (Sortie 7 skipped per Blocker 2)
**Sorties Failed/Blocked:** 0 FATAL; 1 PARTIAL (Sortie 6 primary, resolved via continuation)
**Duration:** Single agentic session, 2026-04-22. 7 commits, 1843 insertions / 25 deletions across 21 files.
**Outcome:** **Complete**
**Verdict:** **Keep the code.** Merge to `development`. v0.8.0 is shippable after user resolves the stash-review FOLLOW_UP item and the pre-existing `AcervoPathTests` flake is triaged (out of scope for this mission).

---

## Section 1: Hard Discoveries

### 1. `AcervoError.componentNotRegistered` already existed pre-mission

**What happened:** Sortie 3's plan anticipated adding a new `componentNotRegistered` error case. When the agent grepped before editing, it found `case componentNotRegistered(String)` already in `AcervoError.swift:40`. The case was reused verbatim.
**What was built to handle it:** Nothing — the prior existence was the right outcome. Sortie 3 saved an edit.
**Should we have known this?** Yes. One `grep -n "componentNotRegistered" Sources/` during planning would have caught it. The plan's breakdown wasn't thorough enough on the baseline.
**Carry forward:** Planning should run targeted greps for every new symbol the plan intends to introduce, not just for existing symbols it intends to modify. Cheap insurance against redundant work.

### 2. The codebase has no `os.Logger` — warnings go to stderr directly

**What happened:** Sortie 3 needed to log the "manifest drift" warning per Blocker 1. The plan said "use whatever logger the codebase uses." A full `grep -n "os.Logger\|Logger(subsystem:" Sources/` returned zero results. The existing warning path in `ComponentRegistry.register(_:)` uses `FileHandle.standardError.write(Data((message + "\n").utf8))`.
**What was built to handle it:** Sortie 3's drift log matched the existing pattern with a `[SwiftAcervo]` prefix. No new dependency introduced.
**Should we have known this?** Yes. The plan assumed a conventional logger existed. It doesn't.
**Carry forward:** If SwiftAcervo ever wants structured logging, that's a separate, scoped decision — not a by-product of another mission.

### 3. `downloadComponent` uses a non-injectable CDN session for file bodies

**What happened:** Sortie 4's `AutoHydrateTests.swift` and Sortie 6's Test 1 both hit the same wall: the manifest fetch is session-injectable (since Sortie 2), but the subsequent **file-body downloads** in `AcervoDownloader.downloadFiles` still use `SecureDownloadSession.shared`. Full end-to-end stubbing of `downloadComponent` requires deeper mock plumbing than the mission added.
**What was built to handle it:** Tests were scoped to "hydrate-then-assert-registry-state" rather than "hydrate-then-full-download". Scope documented in both sortie reports.
**Should we have known this?** Partially. The plan targeted manifest-fetch injection; file-body injection was not in scope. But the exit criteria's phrase "the component is downloaded" implied end-to-end, and the agents had to negotiate around that.
**Carry forward:** If future missions want end-to-end download tests, plan a scoped sortie that pushes URLSession injection all the way through `AcervoDownloader.downloadFiles`. Treat it as a separate, named deliverable.

### 4. Global registry races under parallel Swift Testing suite execution

**What happened:** Sortie 5 added `CatalogHydrationTests` with a baseline-delta strategy that looked robust on paper. Under parallel-suite execution, other suites (e.g., Sortie 6's new `HydrationTests`) register/unregister components between the baseline capture and the delta assertion, corrupting the test's invariant. Sortie 5 shipped because it only ran `make test` once.
**What was built to handle it:** Sortie 6 continuation (commit `565ff27`) nested `CatalogHydrationTests` under `MockURLProtocolSuite`, inheriting the `.serialized` trait. Five consecutive clean `make test` runs after that.
**Should we have known this?** Yes, retrospectively. Swift Testing's default parallelism is known. Any test touching `ComponentRegistry.shared` in an assertion is implicitly racing every other test touching it. The "baseline-delta" strategy was a clever pattern that didn't actually fix the race — it just made the race less obvious.
**Carry forward:** The project's de-facto rule is now: **any test suite that reads or writes `ComponentRegistry.shared` state across multiple operations must nest under `MockURLProtocolSuite`** (or an equivalent `.serialized` parent). Document this in `CLAUDE.md` or an ADR so future sorties inherit the discipline.

### 5. Swift Testing `.serialized` trait is inherited through extension-based nesting

**What happened:** Sortie 2 discovered that `@Suite(.serialized)` only serializes tests *within* a single suite, not across sibling suites. The working pattern is `extension MockURLProtocolSuite { @Suite("Child") struct Child { ... } }` — children inherit the parent's traits. This was not obvious from the Swift Testing docs; it emerged from trial-and-error.
**What was built to handle it:** `MockURLProtocolSuite` parent in `MockURLProtocolTests.swift` became the de-facto "serialized-across-the-suite" anchor. Four subsequent test files (`ManifestFetchTests`, `HydrateComponentTests`, `AutoHydrateTests`, `HydrationTests`, and ultimately `CatalogHydrationTests`) all nest under it.
**Should we have known this?** No — this is live knowledge about Swift Testing behavior, not a documented invariant. Sortie 2's agent also noted that an actor-based alternative (`Exclusion` actor + `.serialized`) didn't work because Swift actors are re-entrant across `await`.
**Carry forward:** Until Swift Testing grows a better story for cross-suite serialization, `MockURLProtocolSuite` is the correct anchor for any global-state-touching test in this repo. Semantically it's a misnomer — rename it to `SerializedGlobalStateSuite` in a future cleanup if it bothers anyone.

### 6. `totalCatalogSize()` returns a named tuple, not a struct

**What happened:** Sortie 5 planned to assert `Acervo.totalCatalogSize().pending == 100`. The plan didn't specify the return type. The agent grepped and found `(downloaded: Int64, pending: Int64)` — a named tuple. The assertion field name matched the plan by luck.
**What was built to handle it:** Nothing beyond matching the existing field names.
**Should we have known this?** Yes. Planning should confirm field names for every assertion, not assume.
**Carry forward:** When the plan writes assertion code like `.foo == 100`, include a note about which symbol that field lives on, so the sortie agent doesn't have to guess.

---

## Section 2: Process Discoveries

### What the Agents Did Right

#### 1. Sortie 2 proactively expanded scope to create `MockURLProtocol`

**What happened:** The original Sortie 2 plan only made `downloadManifest` public. Sortie 2's agent noticed (via Pass 1 analysis at breakdown time, ratified during dispatch) that Sortie 3's concurrency test and Sortie 6's four CDN tests needed a mockable URLSession — and none existed. Scope was expanded in-sortie to add `MockURLProtocol` and URLSession injection.
**Right or wrong?** Right. Doing this in Sortie 2 instead of spawning a separate infra sortie kept the critical path at 7 sorties and prevented two downstream sorties from blocking on missing infrastructure.
**Evidence:** Sortie 2 delivered in a single dispatch (~14 minutes), with 3 new test files. Sortie 3 and 6 both used `MockURLProtocol` with zero additional setup work.
**Carry forward:** When a sortie sits in the critical path AND a downstream sortie depends on its infrastructure, expanding scope in-sortie is preferable to creating a separate "infra" sortie. Just document the expansion.

#### 2. Sortie 3 mirrored Sortie 2's testability pattern

**What happened:** Sortie 3 needed to call `hydrateComponent` from tests with a mocked session, but `hydrateComponent(_:)` doesn't take a session parameter. Instead of changing the public signature, the agent added an internal overload `hydrateComponent(_ componentId: String, session: URLSession)` — the same pattern Sortie 2 used for `downloadManifest(_:session:)`. Tests use the internal overload; production callers use the public one.
**Right or wrong?** Right. Preserves clean public API, enables testability, and establishes a codebase-consistent pattern.
**Evidence:** Sorties 4 and 6 both reused the internal overload pattern without reinventing it.
**Carry forward:** When public API has a dependency that needs test injection, add an internal overload rather than expanding the public surface.

#### 3. Agents were transparent about edge cases and concerns

**What happened:** Sortie 2's agent flagged the pre-existing `AcervoPathTests` race it observed in 5 validation runs — even though it was out of scope and could have been silently ignored. Sortie 6's primary agent was transparent about its partial 5-run result, attributing failures to pre-existing flakes with a control experiment rather than claiming success. Sortie 6's primary agent also self-reported the accidentally-popped git stash.
**Right or wrong?** Right. Honest reports over glossy ones. The stash disclosure in particular let the supervisor flag a potential data-loss risk instead of discovering it later.
**Evidence:** See each agent's final report; all contain explicit "concerns" sections.
**Carry forward:** Continue reinforcing "candor over ceremony" in agent dispatch prompts. It's already working.

### What the Agents Did Wrong

#### 1. Sortie 6 primary agent ran `git stash pop` on a stash it didn't create

**What happened:** During recovery from an aborted operation, the agent ran `git stash pop` to restore what it thought was its own stash. Its stash was empty (nothing tracked to stash in the first place), so `pop` operated on the pre-existing `stash@{0}` — an unrelated developer stash. The popped contents conflicted with the working tree, and the agent resolved via `git checkout HEAD -- <files>`, which **discarded the popped stash's contents**.
**Right or wrong?** Wrong. Before `git stash pop`, the agent should have run `git stash list` to confirm it was popping its own stash, and `git stash pop <ref>` with explicit ref to be safe. Worse: after discovering the mistake, the recovery `git checkout HEAD --` destroyed the popped data.
**Evidence:** `git stash list` now shows `stash@{0}: WIP on development: 4f6bb47 (v0.7.2)` and `stash@{1}: WIP on mission/hydrant-gorge/1` — both pre-existing stashes. The one at position 0 before the incident is no longer recoverable. Captured in `FOLLOW_UP.md § Git stash review`.
**Carry forward:** Dispatch prompts for agents that may run `git stash`/`git reset` operations should include an explicit safety rule: **never pop/apply a stash without first confirming via `git stash list` and `git stash show -p <ref>` that the stash belongs to the agent's own work**. Ideally, agents use a dedicated worktree or branch to avoid touching the user's stash area at all.

#### 2. Sortie 5 shipped a flaky test by running `make test` only once

**What happened:** Sortie 5 added `CatalogHydrationTests.hydrationAwarenessInCatalog` and declared the sortie complete after a single `make test` pass. The test was actually ~60% flaky under parallel-suite execution, caught only by Sortie 6's explicit 5-run requirement.
**Right or wrong?** Wrong. A test that reads global state is, by default, a candidate for parallel-suite races. Running it once is insufficient validation.
**Evidence:** Sortie 6 observed 3/5 runs fail on this test at baseline (with HydrationTests.swift removed). Sortie 6 continuation (commit `565ff27`) fixed it by serializing.
**Carry forward:** Build-and-test exit criteria for any sortie that adds tests touching global state should require **at least 3 consecutive clean `make test` runs**. Codify this in `CLAUDE.md` for SwiftAcervo, or add it to every dispatch prompt that creates tests.

### What the Planner Did Wrong

#### 1. Plan asserted "sub-agents cannot run builds" — this is false

**What happened:** EXECUTION_PLAN.md § Parallelism Structure stated "sub-agents cannot run builds" and concluded the entire mission is supervising-agent-only. In practice, all 7 sorties ran as sub-agent dispatches (general-purpose agents have Bash access and ran `make build`/`make test` cleanly). The plan's claim was empirically refuted by the mission itself.
**Right or wrong?** Wrong claim, right outcome. The mission succeeded via sub-agent dispatch; the plan's serialization was driven by central-file contention (all sorties edit `Acervo.swift`), not by a build-capability limitation.
**Evidence:** 7 sub-agent dispatches, all ran `make build` and `make test`, all succeeded.
**Carry forward:** Planning should not make claims about agent capabilities it hasn't verified. When in doubt, check: sub-agents can run any Bash command the project CLAUDE.md permits. The real serialization reason (central-file contention) is valid and should be stated as the sole reason, without the false corroboration.

#### 2. Planner did not anticipate the test-isolation problem in Sortie 5

**What happened:** Sortie 5 was classified "low risk" and given a minimal test spec. The test it produced was flaky due to parallel-suite races on `ComponentRegistry.shared` — a problem that Sortie 2's MockURLProtocol experience had already taught the project about. The planner did not connect the dots: Sortie 5 tests touch the same global state as Sortie 2–4's tests, so they need the same serialization.
**Right or wrong?** Wrong by omission. The planner should have required Sortie 5 to nest under `MockURLProtocolSuite` (or carry its own `.serialized` anchor) from day one.
**Evidence:** Sortie 5's plan had no nesting requirement. Sortie 6 had to add one. The continuation cost ~6 minutes and one extra commit.
**Carry forward:** Extend the planning checklist: any sortie that adds tests mutating `ComponentRegistry.shared`, `Acervo.customBaseDirectory`, or other global state **must** nest under a serialized parent. This is now documented in `FOLLOW_UP.md § Test-isolation primitive`.

#### 3. Exit criterion "5 consecutive passing runs" applied only to one sortie

**What happened:** Only Sortie 6 required 5 consecutive clean `make test` runs. Every other sortie required one pass. This is why Sortie 5's flake shipped — its exit criteria allowed it.
**Right or wrong?** Wrong. Flake detection should be proportional to test volume. Sortie 5 added 1 global-state-touching test and was allowed 1 run. Sortie 6 added 7 tests (none touching global state the same way) and was required to run 5 times. The math is backwards.
**Evidence:** See the mismatched exit criteria between Sortie 5 and Sortie 6 in EXECUTION_PLAN.md.
**Carry forward:** Any sortie touching global state should require `make test` × 3 minimum in its exit criteria. Flake-sweep requirements scale with risk, not with sortie number.

---

## Section 3: Open Decisions

### 1. Rename `MockURLProtocolSuite` to reflect its actual role?

**Why it matters:** The suite now anchors non-mock tests (`CatalogHydrationTests` doesn't use `MockURLProtocol`). Its name is misleading.
**Options:**
- **A.** Rename to `SerializedGlobalStateSuite` (or similar). Touches five test files.
- **B.** Leave the name; add a comment explaining the de-facto role.
- **C.** Create a new parent suite for non-mock serialized tests; keep `MockURLProtocolSuite` scoped to mock-touching tests only.
**Recommendation:** C. Cleaner semantics, one tiny change (add one `@Suite(.serialized) struct`), no test renames.

### 2. When to revisit manifest disk caching (Blocker 2 deferral)?

**Why it matters:** Every `ensureComponentReady` call now fetches the manifest fresh (one HTTP round-trip per first-use per launch). Acceptable for v0.8.0; may hurt at scale.
**Options:**
- **A.** Never — keep it simple, the cost is one round-trip on cold startup.
- **B.** When a consumer reports latency pain.
- **C.** Proactively in v0.9.0 or v1.0.0 as an opt-in.
**Recommendation:** B. No user has asked for it. Premature optimization. Captured in `FOLLOW_UP.md § Disk-cache deferral (Blocker 2)`.

### 3. Deprecation path for sync `isComponentReady(_:)`?

**Why it matters:** Sync `isComponentReady` now returns `false` for un-hydrated descriptors, which is safe but non-obvious. Callers who want accuracy should use `isComponentReadyAsync`, but the sync path will attract naive use.
**Options:**
- **A.** Leave as-is — the doc comment explains. Migrations happen organically.
- **B.** Mark the sync version `@available(*, deprecated, message: "Use isComponentReadyAsync for accuracy with hydration")`.
- **C.** Restructure: make the sync version private, keep async as the only public path.
**Recommendation:** A for v0.8.0, B for v0.9.0 if user reports confusion. C is breaking and too aggressive for a minor bump.

### 4. Git-stash review (immediate action item)

**Why it matters:** A pre-existing stash was destroyed during Sortie 6 recovery. The two remaining stashes (`stash@{0}: WIP on development (v0.7.2)`, `stash@{1}: WIP on mission/hydrant-gorge/1`) look old and unrelated — but only the repo owner can confirm whether the lost stash was important.
**Options:**
- **A.** Inspect the remaining stashes with `git stash show -p <ref>`; confirm they're obsolete; drop them.
- **B.** Leave untouched until confident nothing is missing.
- **C.** Try to recover the lost stash from reflog (`git reflog` may still reference it for ~30 days).
**Recommendation:** User discretion. Start with A; if the remaining stashes look relevant, pause. If you recall the lost stash's contents, try C. Captured in `FOLLOW_UP.md § Git stash review`.

---

## Section 4: Sortie Accuracy

All commits survived into the final state. No reverts. No overwrites. No deletions of prior work.

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| 1 | ComponentDescriptor API + hydration state | opus | 1 | ✓ | Clean. Chose Option A (`[ComponentFile]?` storage) over enum — simpler, survived all downstream consumption. |
| 2 | Manifest API + MockURLProtocol infra | opus | 1 | ✓ | Scope expansion was the right call. Established `MockURLProtocolSuite` pattern that 4 downstream sorties reused. |
| 3 | `hydrateComponent` + single-flight coalescer | opus | 1 | ✓ | Clean concurrency code. Established internal `(session:)` overload pattern. |
| 4 | Auto-hydrate plumbing + `isComponentReadyAsync` | sonnet | 1 | ✓ | Sonnet was the right call. Mechanical, no concurrency surprises. |
| 5 | Catalog introspection | sonnet | 1 | ✓ (code) / ✗ (test flake) | Code is correct; test was flaky. Continuation in Sortie 6 fixed. Lesson: one `make test` run is insufficient for global-state tests. |
| 6 primary | 7 canonical hydration tests | opus | 1 | ✓ (tests) / PARTIAL (suite stability) | The 7 tests themselves are flake-free. Exit criterion failed due to pre-existing Sortie 5 flake. Agent correctly reported PARTIAL rather than masking. |
| 6 continuation | Serialize `CatalogHydrationTests` | sonnet | 1 | ✓ | One-line structural fix, 5 clean runs. Textbook continuation. |
| 7 | Disk caching | — | 0 | ✓ (skipped cleanly) | Blocker 2 locked pre-execution; no dispatch. No wasted work. |
| 8 | v0.8.0 + docs + CHANGELOG + FOLLOW_UP | sonnet | 1 | ✓ | Included the version bump across CLAUDE.md, AGENTS.md, GEMINI.md, README.md, USAGE.md — more than the plan explicitly required, which was correct. |

**Accuracy summary:** 9/9 dispatches landed on first attempt (counting the continuation). Zero sorties entered BACKOFF. Zero sorties hit FATAL. Model selection was accurate: opus for the 4 high-complexity sorties (Sorties 1, 2, 3, 6-primary), sonnet for the 5 lower-complexity ones (Sorties 4, 5, 6-continuation, 8, plus Sortie 7 which was skipped). No model upgrades on retry were needed because there were no retries.

---

## Section 5: Harvest Summary

The single most important takeaway: **this project's tests cannot rely on `ComponentRegistry.shared` or `Acervo.customBaseDirectory` being stable across parallel suite execution**. The `MockURLProtocolSuite`-nested pattern is the discovered solution, and every future test suite touching global state must inherit it. Sortie 5's flaky test and the pre-existing `AcervoPathTests` flake are two instances of the same underlying architectural gap — SwiftAcervo has no per-test isolation primitive for its global singletons. Fixing that properly is a future mission (captured in `FOLLOW_UP.md`); until then, the discipline of `.serialized` nesting is the workaround.

Secondary: model selection worked as designed. Opus for foundation + concurrency + critical tests; sonnet for mechanical plumbing and docs. No wasted opus dispatches, no sonnet retries needed. The sergeant principle held up.

---

## Section 6: Files

### Preserve (merge to development)

| File | Branch | Why |
|------|--------|-----|
| `Sources/SwiftAcervo/Acervo.swift` | `mission/desert-blueprint/01` | Version bump + 5 new public methods + `HydrationCoalescer` actor + rewired call sites |
| `Sources/SwiftAcervo/AcervoDownloader.swift` | `mission/desert-blueprint/01` | Public `downloadManifest` + URLSession injection |
| `Sources/SwiftAcervo/AcervoError.swift` | `mission/desert-blueprint/01` | `componentNotHydrated` case |
| `Sources/SwiftAcervo/ComponentDescriptor.swift` | `mission/desert-blueprint/01` | Optional `files:`, `isHydrated`, `needsHydration` |
| `Sources/SwiftAcervo/ComponentRegistry.swift` | `mission/desert-blueprint/01` | `replace(_:)` method |
| `Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` | `mission/desert-blueprint/01` | Reusable test infra; consumed by 5 suites |
| `Tests/SwiftAcervoTests/ComponentDescriptorTests.swift` | `mission/desert-blueprint/01` | Hydration-state tests |
| `Tests/SwiftAcervoTests/MockURLProtocolTests.swift` | `mission/desert-blueprint/01` | Harness smoke tests + `MockURLProtocolSuite` parent |
| `Tests/SwiftAcervoTests/ManifestFetchTests.swift` | `mission/desert-blueprint/01` | Public manifest fetch coverage |
| `Tests/SwiftAcervoTests/HydrateComponentTests.swift` | `mission/desert-blueprint/01` | Core `hydrateComponent` tests |
| `Tests/SwiftAcervoTests/AutoHydrateTests.swift` | `mission/desert-blueprint/01` | Plumbing tests for 4 rewired call sites |
| `Tests/SwiftAcervoTests/CatalogHydrationTests.swift` | `mission/desert-blueprint/01` | Catalog introspection (nested under `MockURLProtocolSuite` after continuation) |
| `Tests/SwiftAcervoTests/HydrationTests.swift` | `mission/desert-blueprint/01` | The canonical 7 from the original TODO |
| `CHANGELOG.md` | `mission/desert-blueprint/01` | New file (Keep a Changelog, v0.8.0) |
| `FOLLOW_UP.md` | `mission/desert-blueprint/01` | Out-of-scope items harvested during mission |
| `USAGE.md` | `mission/desert-blueprint/01` | "Manifest-Driven Components" section + version bump |
| `API_REFERENCE.md` | `mission/desert-blueprint/01` | 7 new symbols documented |
| `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `README.md` | `mission/desert-blueprint/01` | Version string 0.7.3 → 0.8.0 |

### Discard (safe to delete after archival)

| File | Why it's safe to lose |
|------|----------------------|
| `SUPERVISOR_STATE.md` | Mission orchestration state; value is in this brief now. |
| `EXECUTION_PLAN.md` | Mission plan; archive to `docs/complete/` after brief is written (per mission-supervisor protocol). |

---

## Section 7: Iteration Metadata

**Starting point commit:** `78f72a9` (`chore: archive prior mission state and superseded TODO`)
**Mission branch:** `mission/desert-blueprint/01`
**Final commit on mission branch:** `0e8cd43`
**Rollback target:** N/A — mission succeeded; no rollback. If a future iteration needs a rollback target, use `78f72a9`.
**Next iteration branch:** N/A — iteration complete. If a DESERT BLUEPRINT v2 (disk caching, end-to-end file-body injection, etc.) is scoped, it becomes `mission/desert-blueprint/02`.

**Recommended next mission (from `FOLLOW_UP.md`):** test-isolation primitive for `ComponentRegistry.shared` and `Acervo.customBaseDirectory`. This would retire the `.serialized` workaround, fix the pre-existing `AcervoPathTests` flake, and unblock faster parallel test execution across all SwiftAcervo suites.
