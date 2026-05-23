---
operation_name: OPERATION VAULT BROOM
iteration: 03
state: incomplete
mission_slug: vault-broom
mission_branch: mission/vault-broom/03
starting_point_commit: 04895964df6ca325a41642c2ffc2e3a50f8d1f9b
status: refined — ready to execute
source_requirements: REQUIREMENTS.md
predecessor: Docs/complete/vault-broom-02/
state_file: Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md
---

# EXECUTION_PLAN — VAULT BROOM iteration 03

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase). Iteration 03 has one work unit; the term is preserved for cross-iteration consistency.

## Mission overview

Collapse the SwiftAcervo CLI's two parallel CDN code paths into one. The library surface is frozen for this iteration — REQUIREMENTS §4.4 prohibits adding any new public symbol in `Sources/SwiftAcervo/`. CLI-surface changes are permitted: drop the `aws` runtime dependency, add a `--keep-orphans` escape hatch, and make orphan pruning the default for `ship` and `upload` (matching `recache`'s manifest-truth model already shipped in v0.10.1 / v0.11.0).

Two sorties, sequential. S2 documents the post-S1 state and cannot start until S1 is `COMPLETED`.

## Framework controls (mission-level invariants)

These come straight from REQUIREMENTS §4. The supervisor MUST honor each before, during, and after every sortie dispatch. Violation halts the mission.

### F1. Pre-dispatch working-tree audit (REQUIREMENTS §4.1)

Before dispatching ANY sortie, run and verify:

```bash
git status --porcelain                          # → only files on mission/vault-broom/03
git rev-parse --abbrev-ref HEAD                 # → mission/vault-broom/03
git merge-base --is-ancestor development HEAD   # → exit 0
```

Additionally, the repo root must not carry abandoned mission planning artifacts from prior cycles. `REQUIREMENTS.md` and `EXECUTION_PLAN.md` at the root must either carry frontmatter `iteration: 03` or be absent. If any check fails, halt and report — do not dispatch.

### F2. State-write-before-completion (REQUIREMENTS §4.2)

Every sortie's exit criteria explicitly include:

- Update `Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md` with this sortie's commit SHA, state `COMPLETED`, and a one-line verification summary, **in the same agent dispatch as the work**.

A sortie that lands code without updating the state file is incomplete. No separate reconciliation pass.

### F3. Build-and-test gate at every sortie's HEAD

Every sortie exits with:

- `make build` exit code 0 at the final HEAD.
- `make test` exit code 0 at the final HEAD.

Gates run **after** the state file is updated. Failures roll the sortie back to `RUNNING` and trigger retry or escalation.

### F4. No silent deferrals (REQUIREMENTS §4.3)

A sortie that genuinely cannot complete is marked `CANCELED-WITH-HANDOFF` in the state file and **must** name a successor mission directory (e.g. `Docs/incomplete/vault-broom-04/`) with a stub `REQUIREMENTS.md` citing the cancellation. No work disappears without a forwarding address.

### F5. No new public library API (REQUIREMENTS §4.4)

Zero new public types, methods, or symbols in `Sources/SwiftAcervo/`. The `--keep-orphans` CLI flag is a CLI-surface change (maps to `publishModel`'s existing `keepOrphans:` parameter). Any diff that introduces a new public symbol in the library target fails review. The only library-shaped change permitted is removing the implicit `aws`-on-PATH dependency — a contract narrowing.

### F6. Mission closeout requires brief + clean state file

Mission cannot be declared COMPLETE until:
- Every sortie below is `COMPLETED` or `CANCELED-WITH-HANDOFF` (no `RUNNING`, no `PENDING`, no missing entries).
- `Docs/incomplete/vault-broom-03/BRIEF.md` exists with the standard sections (Hard Discoveries, Process Discoveries, Open Decisions, Sortie Accuracy, Harvest Summary, Files).
- Only then does `/organize-agent-docs` promote `Docs/incomplete/vault-broom-03/` → `Docs/complete/vault-broom-03/`.

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| WU1: CLI consolidation + docs | `Sources/acervo/` + `Tests/AcervoToolTests/` + `Docs/` + `README.md` + `CHANGELOG.md` | 2 | 1 | none |

---

## Sortie 1: Atomic CLI consolidation + ship/upload rewrite + `--keep-orphans` flag

**Priority**: 9.5 — Blocks S2 (dep_depth=1); establishes the post-CDNUploader state S2 documents (foundation=1); highest-risk sortie (test rewrite + new CLI flag + library-call-site swap, risk=3); high complexity (3).

**Why one sortie, not two**: iteration 02's plan split delete-old vs. rewrite-call-sites and required an intermediate broken-runtime commit. Iteration 03 folds them: one sortie deletes `CDNUploader.swift` and replaces every call site atomically. The tree never has a half-state.

**Dispatch budget**: Refine Pass 2 estimates this sortie at ~59 turns (R=10, C·2=6, M·2=16, B=4, L≈600 → 8, V=10, +5 overhead). Dispatch with `--max-turns=75` rather than the default 50. Splitting is explicitly forbidden by the rationale above — the elevated budget is the correct compensation.

**Entry criteria**:
- [ ] F1 (pre-dispatch working-tree audit) passes.
- [ ] First sortie — no prerequisite sortie.

**Tasks**:

1. **Re-verify the audit's drift list** (REQUIREMENTS §2) against current HEAD:
   - `Sources/acervo/CDNUploader.swift` exists at ~13.6 KB / 371 lines.
   - `Sources/acervo/ShipCommand.swift` references `CDNUploader` around lines 250–308.
   - `Sources/acervo/UploadCommand.swift` references `CDNUploader` around lines 123–183.
   - `Sources/acervo/ToolCheck.swift` enforces `aws` around lines 104–110.
   - `Sources/acervo/AcervoCLI.swift` mentions `aws` around line 24.

   If any of these don't match, **halt and report** — the audit may be stale.

2. **Study `DeleteCommand.swift` and `RecacheCommand.swift`** as the reference pattern: credential resolution via `CredentialResolver`, progress reporter wiring, `Acervo.*` static-API invocation, error surface. Ship/upload rewrites mirror this style — same env-var conventions, same progress wiring.

3. **Rewrite `ShipCommand.run()`** to call `Acervo.publishModel(...)` directly. Keep CHECK 0 (HF tree completeness) and CHECK 1 (HF LFS SHA-256 verify) in the CLI; delegate manifest generation (CHECK 2/3), staged-file rehash (CHECK 4), upload + manifest-LAST + orphan-prune (steps 5–11), CDN manifest readback (CHECK 5), and config.json spot-check (CHECK 6) to `publishModel`. Map `AcervoPublishProgress` cases back to existing stdout per REQUIREMENTS §3.1.1:
   - `.generatingManifest` → "manifest written to ..."
   - `.verifyingManifest` → "CHECK 4 passed: all staged files match the manifest."
   - `.uploadingFile(name:bytesSent:bytesTotal:)` → per-file progress reporter (replaces `aws s3 sync` stderr parsing).
   - `.uploadingManifest` → "manifest.json uploaded to CDN."
   - `.verifyingPublic(stage: "manifest")` → "CHECK 5 passed: CDN manifest verified."
   - `.verifyingPublic(stage: "sample-file")` → "CHECK 6 passed: config.json spot-check succeeded."

4. **Rewrite `UploadCommand.run()`** to call `Acervo.publishModel(...)` directly, starting from a pre-staged directory (no HF download/verify). Preserve every existing flag identically: `--bucket`, `--prefix`, `--endpoint`, `--dry-run`, `--force`, `--no-verify`, `--token`, `--source`, `--output`. If `UploadCommand` and `ShipCommand` end up nearly identical after the swap, prefer the consolidation only if the diff is small; otherwise keep them separate and note in the commit message.

5. **Add `--keep-orphans` flag** to both `ShipCommand` and `UploadCommand`. Default (no flag) calls `publishModel(keepOrphans: false)` and prunes CDN-side orphans. With flag, calls `publishModel(keepOrphans: true)`. This is the one new CLI-surface flag.

6. **Implement `--dry-run` short-circuit**: After CHECK 0/1 and manifest generation succeed, if `--dry-run` is set, print `would upload N files (X bytes total)` summary, then return exit 0 without making any `S3CDNClient.putObject` call. **If implementing this requires adding a `dryRun:` parameter to `Acervo.publishModel`, the sortie halts and escalates** — that would violate F5. Implement dry-run entirely in the CLI as a pre-flight loop over the generated manifest.

7. **Delete `Sources/acervo/CDNUploader.swift`**. Verify with `git ls-files Sources/acervo/CDNUploader.swift` returning empty.

8. **Shrink `Sources/acervo/ToolCheck.swift`** to validate only `hf`. Remove any `requireAWS()` / `aws`-binary check. Audit `Sources/acervo/ProcessRunner.swift` for `aws`-specific helpers and remove them. Keep `ProcessRunner` itself — `hf` invocation still needs it.

9. **Update `Sources/acervo/AcervoCLI.swift`**: remove `aws` mentions from help text and command discussion.

10. **Rewrite test files** (do not delete `ShipCommandTests.swift` / `UploadCommandTests.swift`; replace bodies):
    - `Tests/AcervoToolTests/ShipCommandTests.swift` — any assertion that previously checked for `aws` subprocess invocation is rewritten to assert `MockURLProtocol`-mediated S3 traffic. Tests for argument parsing and validation stay as-is.
    - `Tests/AcervoToolTests/UploadCommandTests.swift` — same treatment.
    - `Tests/AcervoToolTests/ToolCheckTests.swift` — adjust env tests for `hf`-only validation.
    - **Delete `Tests/AcervoToolTests/CDNUploaderTests.swift`** alongside `CDNUploader.swift`.
    - **New tests** (one per command, two assertions each per REQUIREMENTS §3.1 acceptance #9):
      - `ship`/`upload` with `--keep-orphans` invoke `publishModel(keepOrphans: true)`.
      - `ship`/`upload` without `--keep-orphans` invoke `publishModel(keepOrphans: false)`.
    - **New test** (per REQUIREMENTS §3.1 acceptance #8): `--dry-run` exits 0 without making any S3 PUT calls (verified via `MockURLProtocol` request counter equals zero for PUT verbs).
    - **Env-var isolation**: any test that mutates `R2_*` env vars must nest under `ProcessEnvironmentSuite` (existing repo convention, see `Tests/AcervoToolTests/ProcessEnvironmentSuite.swift`). Do not invent a new isolation pattern.

11. **Update `Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md`** (per F2): mark Sortie 1 `COMPLETED` with the commit SHA and a one-line verification summary.

**Exit criteria** (all machine-verifiable):

- [ ] `git ls-files Sources/acervo/CDNUploader.swift` returns nothing.
- [ ] `git grep -nE "\baws\b|CDNUploader|requireAWS" Sources/acervo/` returns **zero** matches (no carve-out for "historical" references; rewrite or delete error strings, help text, and comments).
- [ ] `git grep -nE "putObject|deleteObject|listObjects|SigV4|S3CDNClient" Sources/acervo/` returns zero matches (CLI is a thin wrapper).
- [ ] `git ls-files Tests/AcervoToolTests/CDNUploaderTests.swift` returns nothing.
- [ ] `make build` exit code 0.
- [ ] `make test` exit code 0. Specifically green: `ShipCommandTests`, `UploadCommandTests`, `ToolCheckTests`, `DeleteCommandTests`, `RecacheCommandTests`.
- [ ] `make install-acervo && bin/acervo --help` succeeds.
- [ ] `bin/acervo ship --help` and `bin/acervo upload --help` succeed and show all pre-existing flags **plus** `--keep-orphans`. Record the flag diff in the commit message for the manual review trail.
- [ ] On a host where `which aws` is empty, `acervo ship` and `acervo upload` complete successfully against `MockURLProtocol.session()` in tests (this is the user-visible win — REQUIREMENTS §3.1 acceptance #5).
- [ ] `--dry-run` on `ship` and `upload` exits 0 with `MockURLProtocol` recording zero PUT requests.
- [ ] `Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md` shows Sortie 1 `COMPLETED` with commit SHA.

**Anticipated risks**:

- **Test fixtures may assume `aws` is on PATH.** If `ShipCommandTests`/`UploadCommandTests` shell out to `aws` in setup/teardown, replace with `MockURLProtocol`. `S3CDNClientTests` and `PublishModelTests` already use this pattern — copy it.
- **`URLProtocol`-based tests racing across suites.** Iteration 02 TRIPWIRE GAUNTLET hit this exact failure (Sortie 10 PATH-race). Use `ProcessEnvironmentSuite` for any test mutating `R2_*` env vars.
- **`ShipCommand` may carry CLI-only behavior beyond CDN upload** (pre-flight checks, file staging). Don't blindly replace — keep CLI-only logic in the command body and replace only the CDN-upload portion.
- **`--dry-run` may secretly need a library-side hook.** If preflight-in-CLI proves impossible (e.g. publishModel does the manifest read itself), STOP and escalate. Do not add `dryRun:` to publishModel — that's the §4.4 / F5 violation REQUIREMENTS §3.1.3 explicitly calls out.

---

## Sortie 2: Documentation sweep + API_REFERENCE audit + CHANGELOG entry

**Priority**: 1.75 — No downstream dependents (dep_depth=0); doc-only changes (foundation=0, risk=1, complexity=1.5). Runs strictly after S1 because every doc edit describes the post-S1 state.

**Dispatch budget**: Default 50 turns (estimate ~40).

**Entry criteria**:
- [ ] F1 (pre-dispatch working-tree audit) passes.
- [ ] Sortie 1 is `COMPLETED` per `Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md`.

**Tasks**:

1. **`Docs/CDN_UPLOAD.md`** — Rewrite to describe the single-path flow:
   - The library API (`Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache`) is the surface.
   - The `acervo` CLI is a thin wrapper around that API.
   - Remove ALL `aws s3 sync` / `awscli install` / `aws configure` instructions.
   - Add a subsection on the orphan-prune default and `--keep-orphans` escape hatch.
   - Show an example of `Acervo.publishModel(...)` called programmatically from a CI script.

2. **`Docs/BUILD_AND_TEST.md`** — Remove `aws` install instructions (~lines 17, 277, 429 per audit). Only CLI dep users need is `hf`.

3. **`Docs/PROJECT_STRUCTURE.md`** — Remove references to `CDNUploader` (~lines 34, 255, 280, 281, 296). Update the `Sources/acervo/` directory map to reflect the post-S1 file set.

4. **`Docs/API_REFERENCE.md`** — Audit and patch any gaps. Expected post-state documents:
   - `AcervoCDNCredentials` struct + initializer + default field values.
   - `SigV4Signer` struct + `PayloadHash` enum + `sign(_:payloadHash:date:)` method.
   - `S3CDNClient` actor + initializer + public methods + public result types.
   - `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:)`.
   - `Acervo.deleteFromCDN(modelId:credentials:progress:)`.
   - `Acervo.recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:)`.
   - `AcervoPublishProgress` enum (all cases).
   - `AcervoDeleteProgress` enum (all cases).
   - The four v0.10/v0.11 `AcervoError` cases: `publishVerificationFailed`, `publishOrphanPruneFailed`, `deleteVerificationFailed`, `recacheVerificationFailed`.

5. **`README.md`** — Update the runtime-requirements paragraph (~line 75) to name only `hf` (and any other live deps), not `aws`.

6. **`CHANGELOG.md`** — Add an `Unreleased` entry covering:
   - Dropped `aws` runtime dependency on `ship`/`upload`.
   - Orphan-prune is now the default for `ship`/`upload`; `--keep-orphans` preserves additive behavior.
   - `CDNUploader` removed (internal).
   - CLI test rewrite against `MockURLProtocol`.
   - **Operator upgrade note** called out: anyone scripting around the previous additive-only behavior must add `--keep-orphans` to preserve it.
   - **Do NOT assign a version number** in this mission — REQUIREMENTS §1: "No release in this iteration."

7. **Cross-cutting grep audit**:
   ```bash
   grep -nE "aws s3|awscli|aws binary|install aws|aws cli" Docs/*.md README.md
   grep -n "CDNUploader" Docs/*.md README.md
   ```
   Both should return no install-or-invoke instructions / no `CDNUploader` mentions. Historical references in `CHANGELOG.md` and under `Docs/complete/` are out of scope per REQUIREMENTS §3.2 acceptance #1.

8. **`CLAUDE.md` / `AGENTS.md`** sanity check — run `grep -nE "publishModel|deleteFromCDN|recache" CLAUDE.md AGENTS.md`. Each file must show at least one match for each of the three symbols. If `AGENTS.md` is missing any, add a one-line mention in its Quick Reference / API overview section. Do not rewrite either file beyond the minimum needed to satisfy the grep.

9. **Update `Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md`** (per F2): mark Sortie 2 `COMPLETED`.

**Exit criteria** (all machine-verifiable):

- [ ] `grep -nE "aws s3|awscli|aws binary|install aws|aws cli" Docs/*.md README.md` returns no install-or-invoke instructions (CHANGELOG/archived docs out of scope).
- [ ] `grep -n "CDNUploader" Docs/*.md README.md` returns zero matches.
- [ ] `grep -nE "publishModel|deleteFromCDN|recache\(" Docs/API_REFERENCE.md` returns matches for all three.
- [ ] `grep -nE "publishModel|deleteFromCDN|recache" CLAUDE.md AGENTS.md` returns at least one match per symbol in each file.
- [ ] `grep -n "keep-orphans" Docs/CDN_UPLOAD.md` returns at least one match (the new subsection).
- [ ] `grep -n "Unreleased" CHANGELOG.md` returns a match introduced by this sortie.
- [ ] `grep -n "keep-orphans" CHANGELOG.md` returns at least one match in the new `Unreleased` block (operator upgrade note).
- [ ] `make build` exit code 0 (verify no mid-sortie drift).
- [ ] `make test` exit code 0.
- [ ] `Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md` shows Sortie 2 `COMPLETED` with commit SHA.

**Anticipated risks**:

- **`API_REFERENCE.md` may already document these APIs** from out-of-band updates. Verify accuracy and move on; do not duplicate sections.
- **`CHANGELOG.md` historical `aws` mentions** stay untouched. Only the new `Unreleased` block is added/modified.
- **Subagent parallelism temptation** — iteration 02 suggested fanning 4 sub-agents across 8 doc files. **Do not.** Cross-referencing docs racing in parallel produces inconsistent terminology and broken links. One agent, sequential edits.

---

## Critical path

```
[F1 audit] → S1 → [F1 audit] → S2 → [F6 closeout: BRIEF.md + state file clean]
```

Two sorties, fully serial. S2 documents the post-S1 state, so parallelism is not available.

## Parallelism Structure

**Critical Path**: S1 → S2 (length: 2 sorties)

**Parallel Execution Groups**:
- **Group 1**: S1 (Supervising Agent) — has build/test steps; cannot be delegated to a sub-agent per the parallelism rules.
- **Group 2** (sequential, depends on Group 1): S2 (Supervising Agent) — also runs `make build` / `make test` as a drift check (F3).

**Agent Constraints**:
- **Supervising agent**: handles BOTH sorties. Every sortie in this mission has build steps.
- **Sub-agents (up to 4)**: **explicitly NOT used.** S2's risks section forbids fan-out across doc files (iteration 02's documented failure mode: cross-referencing docs racing in parallel produces inconsistent terminology and broken links). Maximum parallelism for this mission is **1**.

**Missed opportunities**: None. Serial execution is a deliberate design constraint, not an oversight.

## Mission-level risks

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| Audit (REQUIREMENTS §2) is stale by the time S1 runs | Low | F1 + S1 Task 1 (re-verify drift before editing). If drift changed, halt and re-audit. |
| `aws`-binary fallback was load-bearing for some user workflow | Low | `Acervo.publishModel` uses native SigV4 — same protocol surface as `aws s3 cp`. Any user invoking `acervo ship` today gets the same outcome via the new path. Users invoking `aws` directly outside `acervo` are unaffected. |
| `--dry-run` cannot be implemented CLI-only and requires a `dryRun:` library param | Low–Medium | S1 Task 6 halts and escalates rather than violating F5. REQUIREMENTS §3.1.3 explicitly anticipates this. |
| Out-of-band PR lands on `development` mid-mission touching scoped files | Medium | Monitor `git log development ^HEAD --oneline` before each dispatch; halt and rebase if scope-relevant files changed. |
| `Tests/AcervoToolTests/` has hidden coupling to `CDNUploader` not visible in audit | Medium | S1 Task 10 runs `make test` after each test file update; failures point directly to the coupling. |
| Supervisor state file goes stale mid-mission (iteration 02's primary failure mode) | Low (by design) | F2 invariant: sortie isn't `COMPLETED` until the state file is updated. Enforced as exit criterion, not a separate reconciliation pass. |
| New public library symbol sneaks in via S1 consolidation | Low | F5 + REQUIREMENTS §4.4: review diff for new public symbols in `Sources/SwiftAcervo/` at closeout. |

## Open Questions

<!-- Consumed by Pass 1 of refine (`refine-blockers`). Each entry MUST be resolved before refinement can proceed past Pass 1. -->

_No blocking open questions identified during breakdown._

The requirements document (`spec_refined: 2026-05-22`) has already pinned every decision iteration 02 left ambiguous:

- Whether to split CLI cleanup from ship/upload rewrite → folded into one atomic S1 (REQUIREMENTS §5 / drift list §2).
- Orphan-prune default vs. additive behavior → prune by default with `--keep-orphans` escape hatch (REQUIREMENTS §3.1.2).
- `--dry-run` semantics → CLI-only pre-flight loop; halt-and-escalate if it requires a library API change (REQUIREMENTS §3.1.3).
- Homebrew formula update → explicitly out of scope (REQUIREMENTS §1, repeated §2 "Out of scope explicitly").
- Version-bump decision → explicitly deferred (REQUIREMENTS §1: "No release in this iteration").
- `API_REFERENCE.md` patch scope → audit-and-patch with explicit expected-state checklist (REQUIREMENTS §3.2 acceptance #6).
- Test file disposition → rewrite Ship/UploadCommandTests, delete CDNUploaderTests (REQUIREMENTS §3.1 acceptance #7).

If S1 or S2 surfaces a new decision point, the supervisor halts dispatch, records it in `SUPERVISOR_STATE.md`, and prompts the user. No agent guesses.

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 2 |
| Open questions | 0 (resolved by REQUIREMENTS.md spec_refined: 2026-05-22) |
| Dependency structure | Sequential (S1 → S2) |
| Maximum parallelism | 1 (supervising agent only; no sub-agents) |
| Refine status | Passed all 5 passes; ready to execute |
| S1 dispatch budget | 75 turns (oversized by heuristic; splitting forbidden by design) |
| S2 dispatch budget | 50 turns (default) |
| New public library APIs | 0 (REQUIREMENTS §4.4 / F5) |
| Files deleted (Sources) | 1 (`Sources/acervo/CDNUploader.swift`) |
| Files deleted (Tests) | 1 (`Tests/AcervoToolTests/CDNUploaderTests.swift`) |
| Files modified (Sources) | ~5 (`ShipCommand`, `UploadCommand`, `ToolCheck`, `ProcessRunner`, `AcervoCLI`) |
| Files modified (Tests) | ~3 (`ShipCommandTests`, `UploadCommandTests`, `ToolCheckTests`) |
| Files modified (Docs) | ~6 (`CDN_UPLOAD`, `BUILD_AND_TEST`, `PROJECT_STRUCTURE`, `API_REFERENCE`, `README`, `CHANGELOG`) |
| Framework controls | 6 (F1–F6) |
