---
feature_name: OPERATION SHARED PANTRY
mission_branch: mission/shared-pantry/01
starting_point_commit: 1ec90e7ad72c1993d357102ff6af86bf4919b88f
iteration: 1
---

# EXECUTION_PLAN.md — SwiftAcervo: Manifest-as-Bundle Components

**Source requirements**: `REQUIREMENTS-manifest-as-bundle.md`
**Target version**: next minor release (additive contract refinement)
**Project root**: `/Users/stovak/Projects/SwiftAcervo`
**Refinement status**: refined (atomicity / priority / parallelism / open-questions passes complete)

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

Make "many components, one CDN manifest" a first-class supported shape in SwiftAcervo's component-keyed contract, alongside the existing per-component-manifest shape. The trigger case is `black-forest-labs/FLUX.2-klein-4B` (one HF/CDN repo bundling transformer + text_encoder + tokenizer + vae + scheduler), which broke SwiftVinetas's Flux2Engine when it tried to consume the component-keyed API. The architecture is *partially* there — `ComponentDescriptor` already accepts an explicit `files` list and the registry deduplicates by `id`, not `repoId` — but it is not known whether every component-keyed API actually honors that file scope.

The mission proceeds **audit-first**: read the code, map current behavior against requirements R1–R6, then write tests to pin those behaviors, then make minimal targeted edits where audit + tests surface gaps, then document the bundle pattern, then validate end-to-end against a real bundle manifest.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| swiftacervo-bundle-components | `/Users/stovak/Projects/SwiftAcervo` | 7 | 0–4 | none |

This is a single Swift package; one work unit suffices. Layers reflect dependency gating between sorties within the unit.

---

## Behavioral Requirements (referenced throughout)

For a `ComponentDescriptor` `D` with `files = [f1, f2, ...]` where `D.repoId` resolves to a CDN manifest covering a superset `{f1, f2, ..., fN}`:

- **R1.** `ensureComponentReady(D.id)` downloads exactly `D.files`. No more, no less.
- **R2.** `withComponentAccess(D.id) { handle in … }` exposes those files via paths consistent with their on-disk layout (preserve subfolder structure).
- **R3.** `isComponentReady(D.id)` returns true iff every file in `D.files` is on disk and checksums match. Other files in the same manifest are irrelevant.
- **R4.** `deleteComponent(D.id)` removes `D.files`. It does **not** remove files belonging to sibling components (other descriptors with same `repoId` but different `id`).
- **R5.** `Acervo.fetchManifest(forComponent: D.id)` returns the full CDN manifest unchanged.
- **R6.** Registering N distinct components against the same `repoId` (each with a unique `id`) does not fire the re-register canary. Registering the same `id` twice with a different file scope **does** fire it.

---

## Sorties

### Sortie 1: Audit current component-keyed APIs against R1–R6

**Layer**: 0
**Dependencies**: none (first sortie)
**Priority**: 22 — foundation; blocks all six downstream sorties; resolves Q1–Q5 (dep_depth=6, foundation=1, risk=1, complexity=2).
**Agent**: sub-agent eligible (read-only; writes one markdown doc; no build).

**Entry criteria**:
- [ ] First sortie — no prerequisites.

**Tasks**:
1. Read `Sources/SwiftAcervo/ComponentDescriptor.swift` (descriptor type, file-list initializer at line 122).
2. Read `Sources/SwiftAcervo/ComponentRegistry.swift` (id-keyed dedup, re-register canary).
3. Trace `ensureComponentReady` end-to-end through `Acervo.swift` and `AcervoDownloader.swift` (line 34) — does it iterate `descriptor.files` or the full manifest?
4. Trace `withComponentAccess` and the returned `ComponentHandle` (`ComponentHandle.swift`) — is the handle scoped to declared files only? Is subfolder layout preserved?
5. Trace `isComponentReady` — does it check declared files only, or scan the whole `org_repo/` directory?
6. Trace `deleteComponent` (`Acervo+CDNMutation.swift` and surrounding code) — does it remove only declared files, or the whole `org_repo/` directory?
7. Trace `fetchManifest(forComponent:)` (`Acervo.swift:1519`) — confirm it returns the full manifest (R5).
8. Trace `Acervo.diskSize(forComponent:)` and resolve open question Q2 (declared-files-only vs. whole directory).
9. Resolve open questions **Q1–Q5** with concrete recommendations grounded in code reading.
10. Write `docs/incomplete/manifest-as-bundle-audit.md` with one section per requirement (R1–R6) — each entry cites file:line and notes whether existing tests cover it (or names the gap).

**Exit criteria** (machine-verifiable):
- [ ] `test -f docs/incomplete/manifest-as-bundle-audit.md` succeeds.
- [ ] `grep -c '^## R[1-6]' docs/incomplete/manifest-as-bundle-audit.md` returns `6` (one section per requirement).
- [ ] Each R-section contains a verdict line matching `^**Verdict:** (HONORED|GAP|UNKNOWN — TEST NEEDED)$` (verifiable: `grep -c '^\*\*Verdict:\*\*'` returns ≥ 6).
- [ ] Each R-section contains at least one citation matching `Sources/.+:\d+` or `Tests/.+:\d+` (verifiable by grep).
- [ ] A `## Resolutions` section exists with sub-sections `### Q1` through `### Q5` (verifiable: `grep -c '^### Q[1-5]'` returns `5`).
- [ ] `git diff --name-only` shows only `docs/incomplete/manifest-as-bundle-audit.md` as added; no files under `Sources/` modified.

---

### Sortie 2: Bundle test fixtures + R1, R3 tests (download & readiness)

**Layer**: 1
**Dependencies**: Sortie 1
**Priority**: 20 — fixture foundation reused by Sorties 3 and 4; gates all subsequent test sorties (dep_depth=5, foundation=1, risk=2, complexity=2).
**Agent**: supervising-agent only (runs `make test`).

**Entry criteria**:
- [ ] `docs/incomplete/manifest-as-bundle-audit.md` exists and has been read.
- [ ] Existing test infrastructure under `Tests/SwiftAcervoTests/Fixtures/` and `MockURLProtocolTests.swift` has been examined to identify the canonical pattern for mock-CDN-backed component tests.
- [ ] Sub-folder isolation helper at `Tests/SwiftAcervoTests/Support/ComponentRegistryIsolation.swift` has been examined (registry isolation is mandatory for component tests).

**Tasks**:
1. Add a bundle-style mock CDN manifest fixture (covering at least 5 files across 3 distinct subfolders: `transformer/model.safetensors`, `text_encoder/config.json`, `text_encoder/model.safetensors`, `vae/config.json`, `vae/diffusion_pytorch_model.safetensors`) under `Tests/SwiftAcervoTests/Fixtures/`. Expose it via a Swift type with a static factory (e.g., `enum BundleFixtures { static func fluxStyleManifest() -> ... }`) so Sorties 3 and 4 call the same factory.
2. Add a new test file `Tests/SwiftAcervoTests/BundleComponentTests.swift` that registers 3 distinct component IDs (`bundle-transformer`, `bundle-text-encoder`, `bundle-vae`) all pointing at the same `repoId`, each declaring a different subset of files.
3. **R1 test**: After `ensureComponentReady("bundle-transformer")`, assert that exactly the transformer files are on disk and the text_encoder/vae files are NOT.
4. **R1 test**: After also calling `ensureComponentReady("bundle-text-encoder")`, assert that transformer + text_encoder files are on disk and vae files are NOT.
5. **R3 test**: With only transformer files on disk, assert `isComponentReady("bundle-transformer")` is `true` and `isComponentReady("bundle-vae")` is `false`. After all components are ensured, assert all three return `true`.
6. **R3 test**: Delete one declared file from disk for the transformer component; assert `isComponentReady("bundle-transformer")` flips to `false`.

**Exit criteria** (machine-verifiable):
- [ ] `test -f Tests/SwiftAcervoTests/BundleComponentTests.swift` succeeds.
- [ ] `grep -c '^    func test' Tests/SwiftAcervoTests/BundleComponentTests.swift` returns ≥ 4 (R1 ≥ 2 tests, R3 ≥ 2 tests).
- [ ] `make test` invokes the new tests (verifiable: their names appear in test output, whether passing or failing).
- [ ] The bundle fixture is exposed as a Swift symbol callable from other test files (verifiable: a `public` or `internal` static factory method declared in a fixture type/enum, e.g. `BundleFixtures.fluxStyleManifest()`).
- [ ] If any new test fails, append failure details (test name + assertion message) to a new `## Test results` section in `docs/incomplete/manifest-as-bundle-audit.md` for Sortie 5 to consume.

---

### Sortie 3: R2, R5 tests (access scope & manifest fetch)

**Layer**: 1
**Dependencies**: Sortie 2 (reuses bundle fixture)
**Priority**: 12 — adds R2/R5 coverage; produces failure list for Sortie 5 (dep_depth=3, foundation=0, risk=2, complexity=1.5).
**Agent**: supervising-agent only (runs `make test`).
**Note**: Nominally parallel-eligible with Sortie 4 (both depend only on Sortie 2), but in practice **must execute sequentially** because both require the supervising agent (build/test) and both modify `BundleComponentTests.swift`. See Parallelism Structure.

**Entry criteria**:
- [ ] Bundle fixture from Sortie 2 exists and is loadable (verifiable: factory method symbol resolves).
- [ ] `Tests/SwiftAcervoTests/BundleComponentTests.swift` exists.

**Tasks**:
1. **R2 test**: Call `withComponentAccess("bundle-transformer") { handle in … }` and assert `handle` exposes only the transformer files via whatever API `ComponentHandle` provides (paths, file enumeration). If the handle exposes a directory, assert iterating it yields only declared files OR that path resolution refuses non-declared files.
2. **R2 test**: Assert subfolder structure is preserved on disk — e.g., `text_encoder/config.json` lives at `<sharedModelsDirectory>/<slug>/text_encoder/config.json`, not flattened.
3. **R5 test**: Call `Acervo.fetchManifest(forComponent: "bundle-transformer")` and assert the returned manifest includes ALL files in the bundle (not just the transformer subset), and matches the manifest returned by `Acervo.fetchManifest(for: repoId)`.

**Exit criteria** (machine-verifiable):
- [ ] `grep -c '^    func test' Tests/SwiftAcervoTests/BundleComponentTests.swift` returned at least 3 more than the count after Sortie 2 (verifiable by comparing to Sortie 2's recorded count).
- [ ] At least one new test method per requirement R2 and R5 exists (verifiable by grep for distinctive assertions or by test method name including `R2` / `R5`).
- [ ] `make test` invokes the new tests; their pass/fail status is captured.
- [ ] If any new test fails, the failure list is appended to the `## Test results` section in `docs/incomplete/manifest-as-bundle-audit.md` (R2/R5 entries clearly marked).

---

### Sortie 4: R4 (delete semantics) + R6 (re-register canary) tests

**Layer**: 1
**Dependencies**: Sortie 2; runs after Sortie 3 (both edit `BundleComponentTests.swift` — serialized).
**Priority**: 12 — adds R4/R6 coverage; produces failure list for Sortie 5 (dep_depth=3, foundation=0, risk=2, complexity=1.5).
**Agent**: supervising-agent only (runs `make test`).

**Entry criteria**:
- [ ] Bundle fixture from Sortie 2 exists.
- [ ] `Tests/SwiftAcervoTests/BundleComponentTests.swift` exists.
- [ ] Sortie 3 has merged its R2/R5 tests into `BundleComponentTests.swift` (avoid file conflict).

**Tasks**:
1. **R4 test**: Register 3 bundle components, ensure-ready all three, then `deleteComponent("bundle-transformer")`. Assert transformer files are gone from disk AND text_encoder + vae files remain on disk untouched.
2. **R4 test**: After the partial delete, assert `isComponentReady("bundle-text-encoder")` and `isComponentReady("bundle-vae")` still return `true`.
3. **R4 test**: After deleting all three components, assert the `<slug>/` directory is empty (or removed — whichever Sortie 1's audit determined is current behavior; cite Q1's resolution).
4. **R6 test (negative — should not fire)**: Capture stderr while registering 3 distinct component IDs against the same `repoId`. Assert NO re-register warning text appears.
5. **R6 test (positive — should fire)**: Register `id = "X"` with one file list, then re-register `id = "X"` with a different file list. Assert the re-register canary fires (check stderr or whatever observability the canary uses).
6. **R6 test (idempotent — should not fire)**: Register `id = "X"` twice with the *same* descriptor (equivalent file list, type, etc.). Assert canary does NOT fire (this is the manifest-destiny-01 idempotent short-circuit; confirm it still holds).

**Exit criteria** (machine-verifiable):
- [ ] `grep -c '^    func test' Tests/SwiftAcervoTests/BundleComponentTests.swift` increased by at least 5 over Sortie 3's count.
- [ ] At least one new test method per requirement R4 and R6 exists (verifiable by grep).
- [ ] Together with Sorties 2 and 3, the new test file covers all six requirements R1–R6 (verifiable: each Rn appears in at least one test method name or a recorded mapping comment in the file's header).
- [ ] `make test` invokes the new tests; pass/fail status captured.
- [ ] If any new test fails, the failure list is appended to the `## Test results` section in `docs/incomplete/manifest-as-bundle-audit.md` (R4/R6 entries clearly marked).

---

### Sortie 5: Implement minimal targeted fixes for any R1–R6 gaps

**Layer**: 2
**Dependencies**: Sorties 1, 2, 3, 4
**Priority**: 9 — adaptive scope; gated by audit + test failure list; blocks docs and smoke (dep_depth=2, foundation=0, risk=2, complexity=2).
**Agent**: supervising-agent only (runs `make test`; may modify source).
**Scope risk**: this is the only sortie with adaptive scope. If the audit surfaces gaps in 3+ of the R1–R6 APIs, consider whether this should be split mid-flight into Sortie 5a/5b along subsystem lines (e.g., one sortie for download/readiness fixes, one for delete/registry fixes). The supervising agent should monitor turn budget and call for a split if the estimated work exceeds 35 turns.

**Entry criteria**:
- [ ] Audit doc identifies which of R1–R6 currently fail (or `UNKNOWN`).
- [ ] All R1–R6 tests from Sorties 2–4 exist and have been run.
- [ ] List of failing tests is captured under `## Test results` in `docs/incomplete/manifest-as-bundle-audit.md` (re-run `make test` to confirm the list is current).

**Tasks**:
1. For each failing R1–R6 test, identify the smallest source change that makes it pass without breaking pre-existing tests.
2. Apply targeted edits (likely candidates per the requirements doc: `Acervo.swift`'s ensure/ready/delete code paths, `ComponentHandle` scoping, `ComponentRegistry` canary). Touch only what's needed.
3. Run `make test` after each edit cluster. After all edits, run `make test` once more from a clean state to confirm no regressions.
4. If audit identified that R1–R6 are already honored end-to-end, this sortie's deliverable is a **no-op confirmation note** stating that all bundle tests pass without code changes — but that note must be backed by a passing `make test` showing zero failures across the new and existing suites.

**Exit criteria** (machine-verifiable):
- [ ] `make test` exits 0 (verifiable: `$? == 0`). All new bundle tests AND all pre-existing tests pass — no regressions anywhere in `Tests/SwiftAcervoTests/`.
- [ ] If code was changed: `git diff --stat Sources/` shows only edits to files identified in the audit; no new public types appear in `git diff Sources/` unless a test requires them (verifiable: spot-check `git diff` for `public ` additions outside test-required surface).
- [ ] If no code was changed: `git diff Sources/` is empty AND a sortie completion note in `docs/incomplete/manifest-as-bundle-audit.md` (under a `## Sortie 5 outcome` section) explicitly states "audit confirmed R1–R6 honored; no source edits required".
- [ ] Every requirement R1–R6 has at least one test that PASSES (verifiable: parse `make test` output for each Rn-tagged test and confirm pass status).

---

### Sortie 6: Documentation + CHANGELOG

**Layer**: 3
**Dependencies**: Sortie 5
**Priority**: 5 — terminal-side polish; blocks only smoke validation (dep_depth=1, foundation=0, risk=1, complexity=1.5).
**Agent**: sub-agent eligible (docs only; no build).

**Entry criteria**:
- [ ] All R1–R6 tests pass (Sortie 5 exit confirmed; `make test` exits 0).
- [ ] Resolutions to open questions Q1–Q5 from Sortie 1 audit are settled and recorded in `docs/incomplete/manifest-as-bundle-audit.md`.

**Tasks**:
1. Add a "Bundle components" section to `API_REFERENCE.md` with: (a) when to use, (b) how to declare descriptors (one per logical component, sharing `repoId`, each with own `files`), (c) contract guarantees R1–R6 phrased for plugin authors, (d) worked example using `black-forest-labs/FLUX.2-klein-4B` (transformer + text_encoder + vae descriptors).
2. Update `DESIGN_PATTERNS.md` to list the bundle pattern as a recognized choice alongside the existing per-component-manifest pattern.
3. Update `ARCHITECTURE.md` with a brief note that the registry supports both 1:1 and N:1 component-to-manifest mappings.
4. Confirm `CDN_ARCHITECTURE.md` does not need changes (manifest format is unchanged) — if any sentence misleads about 1:1 manifest:component, fix it.
5. Add a CHANGELOG entry under the next minor release version describing the contract refinement, marked as **additive** (no consumer breakage).

**Exit criteria** (machine-verifiable):
- [ ] `grep -c '^## .*Bundle components' API_REFERENCE.md` returns ≥ 1.
- [ ] `grep -c 'FLUX.2-klein-4B' API_REFERENCE.md` returns ≥ 1 (worked example present).
- [ ] `grep -c -E 'R[1-6]\b' API_REFERENCE.md` returns ≥ 6 (each R-contract referenced in the new section).
- [ ] `grep -i 'bundle' DESIGN_PATTERNS.md` returns at least one match.
- [ ] `grep -iE 'bundle|N:1|many.+manifest' ARCHITECTURE.md` returns at least one match.
- [ ] CHANGELOG file (whatever it is named — `CHANGELOG.md` or in-repo equivalent) contains a new entry mentioning "bundle" and "next minor release version" / a relative-version phrase, with the additive guarantee called out.
- [ ] `git diff --name-only` for this sortie touches only `*.md` files at the project root and under `docs/`; no `Sources/` or `Tests/` paths modified.

---

### Sortie 7: Smoke validation against real CDN bundle manifest

**Layer**: 4
**Dependencies**: Sortie 5 (passing tests), Sortie 6 (docs reflect the contract)
**Priority**: 3 — terminal node; local-only validation; does not block anything (dep_depth=0, foundation=0, risk=2, complexity=1.5).
**Agent**: supervising-agent only (runs `make test`).

**Entry criteria**:
- [ ] All unit tests pass (Sortie 5 confirmed; `make test` exits 0).
- [ ] Documentation describes the bundle pattern (Sortie 6 confirmed).

**Tasks**:
1. Add a new test file (e.g., `Tests/SwiftAcervoTests/BundleComponentSmokeTests.swift`) gated behind the existing `INTEGRATION_TESTS` environment variable (this is the actual gate used elsewhere in this repo — `Tests/SwiftAcervoTests/IntegrationTests.swift` and `ModelDownloadManagerTests.swift` use this exact name; do not invent a new one).
2. Test downloads a small real subset from `black-forest-labs/FLUX.2-klein-4B` — pick the smallest viable files (suggestion: `text_encoder/config.json` plus one tokenizer file — both small JSON / config files, free).
3. Register two bundle components against `black-forest-labs/FLUX.2-klein-4B` with distinct file subsets.
4. `ensureComponentReady` for both, assert files land at `<sharedModelsDirectory>/black-forest-labs_FLUX.2-klein-4B/<subfolder>/<file>` with subfolder structure preserved.
5. `deleteComponent` for one, assert only its files are removed and the sibling's files persist.
6. Skip the test gracefully via `XCTSkip` (matching the existing `guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { ... }` pattern in `IntegrationTests.swift`) when the gate is unset.

**Exit criteria** (machine-verifiable):
- [ ] New smoke test file or test methods exist; `grep -c 'INTEGRATION_TESTS' Tests/SwiftAcervoTests/BundleComponentSmokeTests.swift` returns ≥ 1 (gating is in place using the canonical env-var name).
- [ ] `grep -c 'TEST_RUNNER' Tests/SwiftAcervoTests/BundleComponentSmokeTests.swift` returns `0` (the wrong/legacy name is not used).
- [ ] `make test` (without `INTEGRATION_TESTS` set) exits 0 AND the smoke test reports as skipped (verifiable: skip count > 0 in test output).
- [ ] When run with `INTEGRATION_TESTS=1` against the live CDN locally, the smoke test passes (verified manually by the operator; capture the result in the sortie completion note — this exit is operator-attested, not CI-enforced).

---

## Parallelism Structure

**Critical path**: Sortie 1 → Sortie 2 → Sortie 3 → Sortie 4 → Sortie 5 → Sortie 6 → Sortie 7 (length: **7 sorties**).

**Parallel groups**: none with practical speedup. Sorties 3 and 4 are nominally parallel-eligible (both depend only on Sortie 2 and live in Layer 1) but cannot actually parallelize for two reasons:

1. **Build constraint**: Both sorties run `make test`. Per supervisor rule, sub-agents do not run builds — they would be supervising-agent-only. Only one supervising agent exists at a time.
2. **File contention**: Both sorties modify `Tests/SwiftAcervoTests/BundleComponentTests.swift`. Even if (1) were waived, the second sortie would need a merge step.

**Honest verdict**: this plan gets **zero practical parallelism gain**. Every sortie has a hard predecessor and most run builds. Sortie 1 (read-only audit) and Sortie 6 (docs only) are sub-agent eligible in principle, but there is no overlapping work to do during them — they sit on the critical path.

**Agent allocation**:
- **Supervising agent**: Sorties 2, 3, 4, 5, 7 (all run `make test`).
- **Sub-agent eligible**: Sorties 1, 6 (no builds). In practice still serialized due to dependencies.
- **Maximum simultaneous agents**: 1.

**If acceleration becomes a priority later**: split `BundleComponentTests.swift` into `BundleAccessTests.swift` (R2/R5) and `BundleDeleteTests.swift` (R4/R6), and reframe Sorties 3/4 as sub-agent test-writing tasks where the supervising agent does the `make test` invocation afterward. This trades simplicity for at most one sortie's worth of wall-clock savings — not recommended for this mission.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 7 |
| Layers | 5 (Layer 0–4) |
| Critical path length | 7 sorties (no parallelism) |
| Average estimated turns/sortie | ~16 (range 13–20; budget 50) |
| Dependency structure | Layered: audit → fixture+R1/R3 tests → R2/R5 tests → R4/R6 tests → implementation → docs → smoke |
| Source files likely touched | `Sources/SwiftAcervo/Acervo.swift`, `ComponentRegistry.swift`, `ComponentHandle.swift`, `Acervo+CDNMutation.swift` (only where audit shows gaps) |
| New test files | `Tests/SwiftAcervoTests/BundleComponentTests.swift`, `Tests/SwiftAcervoTests/BundleComponentSmokeTests.swift` |
| New docs | `docs/incomplete/manifest-as-bundle-audit.md`, "Bundle components" section in `API_REFERENCE.md`, updates to `DESIGN_PATTERNS.md` and `ARCHITECTURE.md`, CHANGELOG entry |
| Live-CDN test gate | `INTEGRATION_TESTS` env var (matches existing repo convention) |

---

## Open Questions Carried Into Refinement

These are listed in the requirements doc §8 and are explicitly assigned to **Sortie 1's audit** for resolution. Their resolutions must be recorded in the `## Resolutions` section of `docs/incomplete/manifest-as-bundle-audit.md` (one sub-section per question) before Sortie 6 documentation can begin:

- **Q1.** `deleteComponent` for a bundle component — refuse if files shared with another registered component, or just delete declared files? (Recommendation grounding: requirements §5.1 R4 leans toward "delete declared files only".)
- **Q2.** `Acervo.diskSize(forComponent:)` for a bundle component — declared files only, or whole shared directory? (Requirements §5.1 implies declared-files-only.)
- **Q3.** `ensureComponentReady` for a bundle component sharing files with already-ready siblings — re-verify checksums or short-circuit?
- **Q4.** Patch or minor version bump? Decided by Sortie 5 outcome: minor if non-trivial implementation changes were needed, patch if R1–R6 were already honored.
- **Q5.** Add a `BundleComponentDescriptor` convenience initializer? Recommendation: defer.

**Refinement-pass verdict on Q1–Q5**: not blocking. Each is appropriately deferred to Sortie 1's audit, and the audit's exit criterion requires a written resolution per question.

---

## Refinement Pass Results

| Pass | Status | Changes |
|------|--------|---------|
| 1. Atomicity & Testability | ✓ PASS | 0 splits, 0 merges. 5 vague exit criteria tightened (Sorties 2 ×2, 3, 4, 7). Sortie 1 task-9 wording fix (Q1, Q3, Q4, Q5 → Q1–Q5). All sorties fit budget (13–20 turns of 50). |
| 2. Prioritization | ✓ PASS | Priority scores added per sortie. No reordering — original layer order is already correct. |
| 3. Parallelism | ✓ PASS | Critical path is 7 sorties. Zero practical parallelism due to build constraint + file contention on Sorties 3/4. Recorded honestly rather than fabricated. |
| 4. Open Questions & Vague Criteria | ✓ PASS | 5 issues auto-fixed. **Important factual fix**: Sortie 7 corrected from `TEST_RUNNER_*` (does not exist in repo) to `INTEGRATION_TESTS` (verified via `grep` against `Tests/SwiftAcervoTests/IntegrationTests.swift`). 0 blocking issues. Q1–Q5 explicitly assigned to Sortie 1. |

**VERDICT**: ✓ Plan is ready to execute.

**Next step**: `/mission-supervisor name-feature` (THE RITUAL — generate operation name) followed by `/mission-supervisor start`.
