---
operation_name: OPERATION EIGHTH-MASTER
iteration: 01
state: running
status: launched 2026-05-23 — Sortie EM-1 dispatched
source_requirements: ./REQUIREMENTS.md
created: 2026-05-23
starting_point_commit: 347e1366fa27282d3cf7317219792e29cee67e36
mission_branch: mission/eighth-master/01
---

# EXECUTION_PLAN.md — OPERATION EIGHTH-MASTER iteration 01

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Mission Synopsis

Make `Acervo.availability(slug)` tell the truth about whether a model is actually usable by replacing the presence-only validity check with a manifest-driven oracle, then unify the local manifest format with the CDN manifest so the oracle has a single source of truth on disk. Sweep up five carry-over sorties from the parked QUARTERMASTER-02 plan that are tightly bound to the same artifact: CIH-1/CIH-2 (CI hygiene) and DC-1/DC-2/DC-3 (CLI port to PublishRunner architecture, live R2 re-uploads, and `withKnownIssue` cleanup).

Sequencing (per 2026-05-23 decision): §1+§2 library work first (Layer 1) → CIH-* second (Layer 2) → DC-* last (Layer 3). DC-1 now subsumes the S5 CLI port that did not cherry-pick through the QM01 salvage merge.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| validity-oracle | Docs/incomplete/eighth-master-01/ | 3 | 1 | none |
| ci-hygiene | Docs/incomplete/eighth-master-01/ | 2 | 2 | validity-oracle |
| deferred-cleanup | Docs/incomplete/eighth-master-01/ | 3 | 3 | ci-hygiene |

---

## Work Unit: validity-oracle (Layer 1)

### Sortie EM-1: Manifest persistence + schema invariant foundation

**Priority**: 26 — blocks all 7 downstream sorties; establishes the `ModelAvailability.partial` case and `manifest.json` artifact every later sortie reads from.

**Goal**: Establish the on-disk manifest artifact and the type changes that EM-2 and EM-3 build on.

**Entry criteria**:
- [ ] First sortie of mission — no prerequisites beyond the F1 working-tree audit and mission-branch creation.

**Tasks**:
1. Extend `ModelAvailability` enum with `.partial(missing: [String])` case (additive flavor matching existing `.downloading(progress:)`). Update any exhaustive switches the compiler flags.
2. In `AcervoDownloader` (or wherever post-download finalization lives), persist the CDN manifest atomically (`tempfile + rename`) to `<model-dir>/manifest.json` on the same code path as the final SHA-256 verify. This must be byte-equal to the CDN manifest the model came from.
3. Confirm the manifest Codable shape supports nested `files[].path` POSIX subdirectories of arbitrary depth. Add `mkdir -p` along the path before writing any downloaded shard. (Downloader-side only; generator-side recursion is owned by DC-1.)
4. Add round-trip test: serialize a sample CDN manifest with nested paths to disk, decode it back through the existing manifest decoder, assert byte-equal. This is the §2 invariant.
5. Add unit test that a `.partial(missing:)` value round-trips through any internal encoding/`Sendable` boundary it crosses.

**Exit criteria**:
- [ ] `ModelAvailability.partial(missing: [String])` exists in source; project compiles.
- [ ] After a simulated successful download in a tempdir fixture, `<model-dir>/manifest.json` exists and is byte-equal to the input CDN manifest.
- [ ] Nested-path test: a manifest with `files[].path = "transformer/model-00001-of-00003.safetensors"` (depth ≥ 1) downloads to the correct subdirectory.
- [ ] Round-trip test green on `SwiftAcervo-macOS.xctestplan`.
- [ ] `make build` exits 0 and `make test` exits 0 at sortie HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED` in the same dispatch as the work. (F2)

---

### Sortie EM-2: Manifest-driven validity oracle

**Priority**: 23 — blocks EM-3 and every Layer-2/3 sortie that depends on truthful availability; the 3-tier oracle is the mission's core deliverable.

**Goal**: Replace presence-only validity with the 3-tier manifest-driven algorithm; produce correct results for the audited false-positive and false-negative cases.

**Entry criteria**:
- [ ] EM-1 `COMPLETED` with commit SHA recorded.
- [ ] `ModelAvailability.partial(missing:)` available.
- [ ] Local `manifest.json` write path landed.

**Tasks**:
1. Replace `Acervo.availability(_:)`'s presence-only check with the 3-tier algorithm:
   - (a) Local `manifest.json` exists → verify every entry in `files` exists on disk at matching size. Return `.available` if all present; `.partial(missing: [...])` if some missing. (SHA-256 verification is opt-in via a separate parameter — see OQ-2 resolution; default off.)
   - (b) No local manifest → fall back to the in-memory CDN manifest cache from the slug-registry work (already shipped in PR mission/quartermaster-salvage/01).
   - (c) No manifest reachable → last-resort heuristic: `model_index.json` OR `config.json` present, **and** every file enumerated in `model.safetensors.index.json`'s `weight_map` values is on disk.
2. Update every internal "is this model present" check that currently uses `config.json` presence to use the new oracle (or accept `model_index.json` as equivalent root marker).
3. Add the opt-in SHA-256 surface as `public static func availability(_ modelId: String, verifyHashes: Bool = false) async -> ModelAvailability` on `Acervo` (and the matching `AcervoManager.availability(_:verifyHashes:)` actor method). Default false. When `verifyHashes: true`, after the presence-and-size pass succeeds, stream-hash each file declared in `manifest.json` and compare to the manifest's recorded SHA-256; any mismatch → `.partial(missing: [<path>])` (treat hash-mismatch as effectively missing, same way the consumer should re-download). Document the cost in the doc-comment.
4. Add acceptance test: `await Acervo.availability("mlx-community/Qwen3-Coder-Next-4bit")` against a fixture matching the audited disk state (config.json + index.json declaring 9 shards, zero shards present) returns `.partial(missing: [<the 9 shard filenames>])`, **not** `.available`. (§1.3 acceptance #1)
5. Add acceptance test: `await Acervo.availability("black-forest-labs/FLUX.2-klein-4B")` against a fixture matching the audited disk state (no top-level `config.json`, `model_index.json` present, all shards present in subdirs) returns `.available`. (§1.3 acceptance #2)
6. Add unit tests for each of the three fallback tiers in isolation.

**Exit criteria**:
- [ ] §1.3 acceptance #1 test green (Qwen3-Coder-Next-shaped fixture → `.partial`).
- [ ] §1.3 acceptance #2 test green (FLUX.2-shaped fixture → `.available`).
- [ ] All three fallback tiers individually unit-tested.
- [ ] `model_index.json`-equivalence test green.
- [ ] All tests use in-memory or tempdir fixtures — no live disk dependency.
- [ ] **F7 clause honored**: if writing the tests surfaced a real bug in EM-1's manifest write or elsewhere, the sortie reported PARTIAL with bug location + recommended fix instead of editing tests around it.
- [ ] `make build` + `make test` exit 0 at sortie HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

### Sortie EM-3: `localModels()` housekeeping + remaining §1.3 acceptance

**Priority**: 16.75 — closes the §1.3 acceptance loop and adds the `gcEmptyModelDirectories()` API; blocks Layer-2 entry.

**Goal**: Filter empty model directories from listing, expose explicit GC, close out §1.3 acceptance #3, #4, #5.

**Entry criteria**:
- [ ] EM-1, EM-2 `COMPLETED` with commit SHAs recorded.

**Tasks**:
1. Modify `Acervo.localModels()` to filter out directories with no `config.json` AND no `model_index.json` AND no `manifest.json` at listing time. Non-destructive — directories remain on disk; they are just hidden from the listing.
2. Add `Acervo.gcEmptyModelDirectories()` that physically removes those filtered directories, for callers that want explicit pruning. Atomic per-directory; reports the list of removed paths.
3. Add acceptance test: a tempdir fixture containing the 11 real models + 8 empty-directory stubs from the 2026-05-20 audit (or equivalent shape) → `Acervo.localModels()` returns exactly the 11 real models. (§1.3 acceptance #4)
4. Add acceptance test: after `Acervo.ensureAvailable(...)` against a fixture model, `<model-dir>/manifest.json` exists and is byte-equal to the CDN manifest the model came from. (§1.3 acceptance #3 — closes the loop on EM-1's write path through the full public API.)
5. Add acceptance test for `gcEmptyModelDirectories()`: pre-populate empty stubs, call it, confirm only those are removed and the real model directories are untouched.

**Exit criteria**:
- [ ] `Acervo.gcEmptyModelDirectories()` exists in the public API surface with documentation comment describing destructiveness.
- [ ] §1.3 acceptance #3 test green (post-`ensureAvailable` manifest persisted and byte-equal).
- [ ] §1.3 acceptance #4 test green (`localModels()` excludes empty stubs).
- [ ] §1.3 acceptance #5 satisfied: all §1.3 acceptance tests are on `SwiftAcervo-macOS.xctestplan`; none use live disk dependencies.
- [ ] **F7 clause honored**: tests STOPped and reported PARTIAL if they uncovered a real bug rather than masking it.
- [ ] `make build` + `make test` exit 0 at sortie HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

## Work Unit: ci-hygiene (Layer 2)

### Sortie CIH-1: Audit test-plan placement

**Priority**: 13.5 — read-only audit that gates CIH-2's mechanical fixes; dependency-pinned before CIH-2 despite CIH-2's slightly higher raw score.

**Goal**: Produce a read-only report listing every test class and its current xctestplan, flagging mis-placements.

**Entry criteria**:
- [ ] validity-oracle work unit `COMPLETED` (all of EM-1, EM-2, EM-3). The new tests added in EM-1/2/3 must be in scope of the audit so CIH-2 can rule on them.

**Tasks**:
1. Walk every test class in `Tests/SwiftAcervoTests/` and `Tests/AcervoToolTests/`.
2. For each class, record which of `SwiftAcervo-macOS.xctestplan`, `SwiftAcervo-iOS.xctestplan`, `SwiftAcervo-Performance.xctestplan` it appears in (and whether it appears in `skippedTests` on any plan).
3. Flag any deterministic correctness test that lives on `SwiftAcervo-Performance.xctestplan` (the QM01 planner-wrong-#1 mistake — Test F was wrongly perf-gated).
4. Write the report to `Docs/incomplete/eighth-master-01/CIH1_TEST_PLAN_AUDIT.md` with a table: `class | macOS plan | iOS plan | perf plan | classification (correctness / perf / mixed) | recommendation`.
5. Reuse the parked plan's CIH-1 task list at `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` as the starting template; re-validate against the v0.15.x test tree before dispatching findings.

**Exit criteria**:
- [ ] `CIH1_TEST_PLAN_AUDIT.md` exists with one row per test class.
- [ ] No source files modified by this sortie (read-only audit).
- [ ] Audit explicitly notes whether any deterministic correctness test is perf-gated; if none, that's stated.
- [ ] `make build` + `make test` exit 0 (sanity — should be unchanged since no source edits). (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

### Sortie CIH-2: CI workflow + Makefile + shape gate

**Priority**: 13.75 — installs the durable shape gate reused by DC-1/2/3; constrained to follow CIH-1.

**Goal**: Apply CIH-1's mechanical findings; add an automated shape gate that prevents future regression.

**Entry criteria**:
- [ ] CIH-1 `COMPLETED` with `CIH1_TEST_PLAN_AUDIT.md` committed.

**Tasks**:
1. Apply each mechanical recommendation in CIH-1's report (test-plan moves only — no test code changes).
2. Update the `test` and `test-perf` targets in the Makefile to explicitly name their test plans via `-testPlan <name>`. No implicit defaults.
3. Add a shape gate Makefile target named `make test-plan-shape` that uses `jq` against each `.xctestplan` JSON and asserts no test class except `StreamingPerformanceTests` appears in `skippedTests` on the CI plans (`SwiftAcervo-macOS.xctestplan`, `SwiftAcervo-iOS.xctestplan`). Wire it into CI workflow before `make test`.
4. Update CI workflow file(s) to invoke the shape gate before `make test`.
5. **Scope discipline**: If CIH-1 surfaced findings that are NOT mechanical (require test code edits, new test code, or design decisions), file each as a carry-forward entry in `Docs/incomplete/QUEUE.md`. Do not grow CIH-2 to absorb them. (See OQ-5 resolution.)

**Exit criteria**:
- [ ] `make test` and `make test-perf` targets explicitly name their plans.
- [ ] `make test-plan-shape` target exists and exits 0 against the current `.xctestplan` files.
- [ ] Shape gate is invoked in CI workflow before `make test`.
- [ ] Any non-mechanical CIH-1 finding has a corresponding row in `QUEUE.md` carry-forwards.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0 at sortie HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

## Work Unit: deferred-cleanup (Layer 3)

### Sortie DC-1: Port S5 CLI flags to PublishRunner architecture

**Priority**: 11 — restores the CLI surface DC-2 invokes (`--spec`, `--dry-run`, `--output-dir`); also owns the generator-side recursion EM-1 punted.

**Goal**: Restore the `acervo ship --slug` / `--spec` / `--dry-run` / `--output-dir` CLI surface (S5 from QM01 salvage that did not cherry-pick) on top of the v0.15.0 PublishRunner architecture, and extend `--spec` live mode to iterate components.

**Entry criteria**:
- [ ] validity-oracle work unit `COMPLETED`.
- [ ] ci-hygiene work unit `COMPLETED`.
- [ ] Refinement Pass F8 (API-symbol verification) confirms that any Foundation / standard-library symbols this sortie names exist in the current SDK. (No specific symbols named here — flag during refinement if any are introduced.)

**Tasks**:
1. Extend `ManifestGenerator` to recurse into subdirectories of the staged repo when enumerating files, excluding HuggingFace cruft (`.cache/`, `.gitattributes`, `.gitignore`, `.DS_Store`, `*.lock`, `*.metadata`). Each emitted `files[].path` is a POSIX path relative to the staged repo root (depth ≥ 1 permitted). (Moved here from EM-1 during refine Pass 2 — generator-side recursion is DC-1's territory; EM-1 only owns the downloader-side `mkdir -p`.)
2. Extend `ManifestGenerator` with a `(modelId: String, primaryRepo: String, components: [String])` initializer. Default `primaryRepo = modelId` and `components = [modelId]` on the existing initializer so `ShipCommand` / `UploadCommand` / `RecacheCommand` single-repo callers compile unchanged.
3. Add `--slug`, `--spec`, `--dry-run`, `--output-dir` flags to `ShipCommand`. Modify `modelId` to `String?`. Add a `validate()` that requires either `modelId` or `--spec` (mutually informative — both is an error).
4. Implement `runDryRun()`: skip `ToolCheck.validate()`, skip HF download, skip `PublishRunner.run(...)`. Generate manifest(s) into `--output-dir` (or a temp dir when omitted). Print absolute paths of generated manifests to stdout. Handles both single-component and `--spec` multi-component paths (`runDryRunSpec` / `runDryRunSingleComponent` if a split aids clarity).
5. Extend live `--spec` mode (no `--dry-run`) to iterate `spec.components`: per-component HF download into per-component staging subdirs, then a single `PublishRunner.run(...)` per component using the **shared** `(modelId, primaryRepo, components)` triple so every generated manifest carries the same slug-registry fields.
6. Add `Tests/AcervoToolTests/ShipDryRunTests.swift`. Pattern is the S5 deliverable from `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` Sortie DC-1, but written against `PublishRunner` mocks (not the deleted `CDNUploader`). Add at least one test that asserts the generator emits nested-path entries (depth ≥ 1) when the staged repo contains subdirectories.
7. Confirm `make build` + `make test` green; CIH-2's shape gate still passes.

**Exit criteria**:
- [ ] `acervo ship --help` shows the four new flags.
- [ ] `acervo ship --slug foo --dry-run --output-dir /tmp/foo-dry` generates a manifest into the named dir, exits 0, prints the path, and makes no R2 calls.
- [ ] `acervo ship --spec <path> --dry-run` generates one manifest per `spec.components` entry into `--output-dir`; all share `modelId` / `primaryRepo` / `components`.
- [ ] Generator nested-path test green: a staged repo with subdirectories emits `files[].path` entries of depth ≥ 1.
- [ ] `ShipDryRunTests.swift` green on `SwiftAcervo-macOS.xctestplan`.
- [ ] `ShipCommand` / `UploadCommand` / `RecacheCommand` single-repo callers still compile and exercise unchanged behavior.
- [ ] **F7 clause honored**: if tests for the dry-run path surfaced a real bug in `PublishRunner` or `ManifestGenerator`, sortie reported PARTIAL with location + recommended fix.
- [ ] `make build` + `make test` + `make test-plan-shape` exit 0 at sortie HEAD. (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

### Sortie DC-2: Live CDN re-upload of three Vinetas manifests

**Priority**: 6.75 — operator-tended live R2 work; high risk but low downstream depth (only blocks DC-3).

**Goal**: Operator-tended live R2 re-upload of `pixart-sigma-xl`, `flux2-klein-4b`, `flux2-klein-9b` so their CDN manifests carry the slug-registry schema fields AND the nested-path file enumeration.

**Entry criteria**:
- [ ] DC-1 `COMPLETED` with commit SHA recorded.
- [ ] Three resolved slug-specs available (inline in `REQUIREMENTS.md` §3 DC-2; serialize as `Docs/incomplete/eighth-master-01/dc2-specs/<slug>.json` at sortie start).
- [ ] Live R2 credentials present in the operator environment (`test -n "$ACERVO_R2_*"` — existence checks only; never echo secrets).

**Tasks**:
1. Write the three `--spec` JSON files to `Docs/incomplete/eighth-master-01/dc2-specs/` (one per slug). Contents per REQUIREMENTS.md §3 DC-2.
2. For each slug, run `acervo ship --spec <spec> --dry-run --output-dir <tmpdir>` first; visually inspect the generated manifest carries `modelId`, `primaryRepo`, `components`, and nested-path file entries. Operator confirms.
3. For each slug, run `acervo ship --spec <spec>` against live R2.
4. Post-upload, for each slug: fetch the CDN manifest fresh (cache-busting) via the same code path consumers use; assert it decodes with the new fields populated and the nested paths enumerated. Record the manifest digest in the commit message.
5. Document each upload in `Docs/incomplete/eighth-master-01/DC2_UPLOAD_LOG.md`: slug, timestamp, manifest digest pre/post, operator initials.
6. Parked-plan task list at `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` Sortie DC-2 is the reference; deviate only where the v0.15.x CLI surface differs.

**Exit criteria**:
- [ ] Three slug-specs exist as committed JSON files under `Docs/incomplete/eighth-master-01/dc2-specs/`.
- [ ] Each of `pixart-sigma-xl`, `flux2-klein-4b`, `flux2-klein-9b` has been re-uploaded to live R2; the CDN manifest fetched post-upload decodes with `modelId` / `primaryRepo` / `components` populated and nested `files[].path` enumerated.
- [ ] `DC2_UPLOAD_LOG.md` records timestamp + manifest digest + operator initials for each.
- [ ] `make build` + `make test` exit 0 (no code changes expected; sanity only). (F3)
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

### Sortie DC-3: Remove `withKnownIssue` wraps; restore `CDNManifestFetchTests` to live-passing

**Priority**: 1.5 — mechanical cleanup with no downstream dependents; closes the mission.

**Goal**: Remove the `withKnownIssue` wraps in `AcervoToolTests/CDNManifestFetchTests` that QM01's S1 added when live R2 manifests pre-S6 did not carry `modelId`/`primaryRepo`/`components`. After DC-2 ships, these wraps are misleading — the tests will start passing for real and `withKnownIssue` will emit "not failing as expected" diagnostics.

**Entry criteria**:
- [ ] DC-2 `COMPLETED` with `DC2_UPLOAD_LOG.md` showing all three manifests re-uploaded with new schema.

**Tasks**:
1. Locate every `withKnownIssue { ... }` in `Tests/AcervoToolTests/CDNManifestFetchTests*`. (grep is sufficient.)
2. Remove each wrap. Restore the wrapped assertions to direct execution.
3. Remove the two useless-`try` SourceKit warnings flagged in REQUIREMENTS.md §3 DC-3.
4. Run the suite against live R2 (or against a fixture mirroring live R2's post-DC-2 state) and confirm all wraps now pass.
5. Confirm no `KnownIssue` not-failing-as-expected diagnostic remains anywhere in the test output.

**Exit criteria**:
- [ ] No `withKnownIssue` remains in `Tests/AcervoToolTests/CDNManifestFetchTests*` related to the pre-S6 schema gap.
- [ ] `make build` emits no warnings about useless `try` in the affected files.
- [ ] `make test` exit 0 against live R2 (or post-DC-2 fixture) with no `KnownIssue` not-failing diagnostics. (F3)
- [ ] CIH-2's shape gate still passes.
- [ ] `SUPERVISOR_STATE.md` updated with commit SHA + `COMPLETED`. (F2)

---

## Parallelism Structure

**Critical Path**: EM-1 → EM-2 → EM-3 → CIH-1 → CIH-2 → DC-1 → DC-2 → DC-3 (length: 8 sorties)

**Parallel Execution Groups**: none

**Agent Allocation**: 1 supervising agent, 0 sub-agents.

**Rationale**: Every sortie requires `make build` + `make test` at its own HEAD (F3), and sub-agents do not perform builds. EM-1/EM-2/EM-3 all modify `Sources/SwiftAcervo/Acervo.swift` (and its immediate siblings `ModelAvailability.swift`, `AcervoDownloader`); parallelising them would force merge resolution on the supervising agent that costs more than serial execution. CIH-* is dependency-pinned to validity-oracle COMPLETED so that CIH-1's audit covers the newly-added tests rather than a stale tree. DC-* is dependency-pinned end-to-end (DC-2 consumes DC-1's CLI surface; DC-3 consumes DC-2's freshly-shipped manifests).

**Missed Opportunities**: none identified. The mission is intentionally narrow-front; widening it via sub-agents would add coordination overhead without shortening wall-clock.

---

## Process Controls (F1–F8) — Supervisor-Honored

These are non-negotiable framework controls applied by the supervisor at dispatch time. They are NOT individual sorties; every sortie inherits them.

| Control | Application |
|---------|-------------|
| **F1** Pre-dispatch working-tree audit | Before each dispatch: `git status --porcelain` clean; current branch = mission branch; HEAD descends from `development`. Halt otherwise. |
| **F2** State-write-before-completion | Every sortie above includes "Update `SUPERVISOR_STATE.md` with this sortie's commit SHA and `COMPLETED` status" in exit criteria. State is written in the same dispatch as the work — not by reconciliation. |
| **F3** Build-and-test gate at every sortie HEAD | Every sortie exit criteria includes `make build` exit 0 and `make test` exit 0 at the final HEAD. |
| **F4** No silent deferrals | A sortie that cannot complete this iteration is marked `CANCELED-WITH-HANDOFF` and names a successor mission with a stub `REQUIREMENTS.md`. |
| **F5** No out-of-band shipping during mission window | Supervisor monitors `git log development ^HEAD --oneline` periodically. New commits to `development` from other branches touching scoped files trigger halt-and-rebase. |
| **F6** Closeout requires brief + clean state | `Docs/incomplete/eighth-master-01/BRIEF.md` covering QM01 brief Sections 1-6 is required before `/organize-agent-docs` promotes the mission to `Docs/complete/`. |
| **F7** "STOP if you find a production bug" | Every test-authoring sortie's dispatch prompt MUST include verbatim: *"If the test you're writing surfaces a real production bug, your job is to STOP and report PARTIAL with the bug location and a recommended fix. Do not modify the test to make the bug invisible."* (Applies here to EM-1, EM-2, EM-3, DC-1.) |
| **F8** API-symbol verification at planning time | During `refine`, any named Foundation / standard-library symbol must be grep-verified against the SDK or Apple docs. No such symbols are named in this plan today; refinement should re-check before dispatch if any are introduced. |

---

## Open Questions

_No blocking open questions remain — all 5 resolved during refine Pass 1 (2026-05-23). See Decisions Log below._

### Decisions Log (refine Pass 1)

| # | Affects | Decision | Source |
|---|---------|----------|--------|
| OQ-1 | EM-1 (and EM-2, EM-3) | Extend `ModelAvailability` with `.partial(missing: [String])` | recommendation (accept all) |
| OQ-2 | EM-2 | Opt-in SHA-256 verification via `Acervo.availability(_:verifyHashes: Bool = false)`; default false | recommendation (accept all) |
| OQ-3 | EM-3 | Filter empty model dirs at listing time by default; expose explicit `Acervo.gcEmptyModelDirectories()` for pruning | recommendation (accept all) |
| OQ-4 | DC-3 | Run DC-3 on the eighth-master mission branch (in-mission, not a follow-up) | recommendation (accept all) |
| OQ-5 | CIH-1, CIH-2 | CIH-2 folds in mechanical findings only; non-mechanical findings carry-forward to `Docs/incomplete/QUEUE.md` | recommendation (accept all) |

Sortie bodies (EM-1, EM-2, EM-3, CIH-2, DC-3) already reflect these decisions and require no further edits as a result of Pass 1.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 3 |
| Total sorties | 8 |
| Open questions | 0 (5 resolved during refine Pass 1) |
| Dependency structure | layers (1 → 2 → 3, sequential within each layer) |
