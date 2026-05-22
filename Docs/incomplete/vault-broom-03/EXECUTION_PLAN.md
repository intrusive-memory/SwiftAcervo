---
operation_name: OPERATION VAULT BROOM
iteration: 03
state: incomplete
mission_slug: vault-broom
mission_branch: mission/vault-broom/03
starting_point_commit: <TBD — set when mission init runs against current `development` HEAD>
status: draft — ready to execute
predecessor: ../../complete/vault-broom-02/
source_requirements: REQUIREMENTS.md
---

# EXECUTION_PLAN — VAULT BROOM iteration 03

## Terminology

> **Mission** — A definable, testable scope of work with explicit acceptance criteria and a single exit brief.
>
> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one target, one return.
>
> **Work Unit** — A grouping of sorties sharing files or layer. (Iteration 03 has one work unit; this term is preserved for cross-iteration consistency.)

## What changed since iteration 02

Iteration 02 was a 12-sortie plan that shipped ~75% of its code (WU1, WU2, WU3.S2, and the RecacheCommand half of WU3.S3) but ran without functioning state-tracking — see `../../complete/vault-broom-02/SUPERSEDED.md` for the root-cause breakdown. The remaining 25% (CLI cleanup, ship/upload rewrite, docs, Homebrew) **never executed** but was also never re-scheduled, leaving the production CLI carrying two parallel CDN code paths for months.

Iteration 03 ships only those four missing pieces. It is intentionally short — **3 sorties** — and intentionally tight on process controls. Almost every line in this plan is informed by an iteration-02 failure mode. Read §"Framework controls" before any sortie dispatch.

## Mission overview

Collapse the SwiftAcervo CLI's two CDN code paths into one. Delete `CDNUploader.swift`, drop the `aws` binary dependency, rewrite `ShipCommand` and `UploadCommand` on `Acervo.publishModel`, sweep `aws`/`CDNUploader` references from docs, and prepare the Homebrew formula update on a branch pending the post-merge tag.

Ships **zero new public APIs** (REQUIREMENTS §4.5). Pure consistency and consolidation.

## Framework controls (planner contract)

These are mission-level invariants. The supervisor MUST honor each before, during, and after every sortie dispatch. Violation halts the mission.

### F1. Pre-dispatch working-tree audit (per REQUIREMENTS §4.1)

Before dispatching ANY sortie, the supervisor runs and verifies:

```bash
git status --porcelain                            # → empty or only mission-branch files
git rev-parse --abbrev-ref HEAD                   # → mission/vault-broom/03
git merge-base --is-ancestor development HEAD     # → exit 0 (HEAD descends from development)
```

If any check fails, the supervisor halts and reports — does not dispatch. This eliminates the iteration-02 working-tree contamination failure (half-applied `fix/app-group-env-resolution` rebase).

### F2. State-write-before-completion invariant (per REQUIREMENTS §4.2)

Every sortie's exit criteria include the explicit task:

- Update `SUPERVISOR_STATE.md` with this sortie's commit SHA, state `COMPLETED`, and a one-line verification summary.

The state file is updated **in the same agent dispatch** as the work, not by a separate reconciliation pass. A sortie that lands code without updating the state file is incomplete. This eliminates iteration 02's WU2.S1 "observed state wins" pattern.

### F3. Build-and-test gate at every sortie's HEAD (per REQUIREMENTS §3.1, §3.2 implicitly)

Every sortie's exit criteria include:

- `make build` exit code 0 at the final HEAD of this sortie.
- `make test` exit code 0 at the final HEAD of this sortie.

Both gates run **after** the state file is updated. If either gate fails, the sortie is FAILED, the state file is rolled back to `RUNNING`, and the supervisor retries or escalates.

### F4. No silent deferrals (per REQUIREMENTS §4.3)

A sortie that cannot complete in this iteration is marked `CANCELED-WITH-HANDOFF` in the state file and **must** name a successor mission (e.g. `Docs/incomplete/vault-broom-04/`) with a stub REQUIREMENTS.md citing the cancellation. No work disappears from the framework without a forwarding address. This eliminates iteration 02's silent deferral of WU2.S3 / WU3 / WU4.

### F5. No out-of-band shipping (per REQUIREMENTS §4.4)

The supervisor monitors `git log development ^HEAD --oneline` periodically (at minimum before each sortie dispatch). New commits to `development` from outside this mission that touch `Sources/acervo/`, `Docs/CDN_UPLOAD.md`, `Docs/BUILD_AND_TEST.md`, `Docs/PROJECT_STRUCTURE.md`, `Docs/API_REFERENCE.md`, `README.md`, or `../homebrew-tap/Formula/acervo.rb` trigger a halt-and-rebase. The mission resumes after rebase. This eliminates iteration 02's drift-via-feature-PRs pattern.

### F6. Mission closeout requires brief + clean state file (per REQUIREMENTS §4.3)

Mission cannot be declared COMPLETE until:
- Every sortie below is `COMPLETED` or `CANCELED-WITH-HANDOFF` (no `RUNNING`, no `PENDING`, no missing entries).
- `Docs/incomplete/vault-broom-03/BRIEF.md` exists and includes Sections 1 (Hard Discoveries), 2 (Process Discoveries), 3 (Open Decisions), 4 (Sortie Accuracy), 5 (Harvest Summary), 6 (Files) — mirroring `Docs/complete/tripwire-gauntlet-02-brief.md`'s structure.
- Only then does `/organize-agent-docs` promote `Docs/incomplete/vault-broom-03/` → `Docs/complete/vault-broom-03/`.

## Work units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|---|---|---|---|---|
| WU1: CLI consolidation + docs + Homebrew | `Sources/acervo/` + `Docs/` + `../homebrew-tap/` | 3 | 1 | none |

Three sorties, sequential. No parallelism opportunity worth exploiting — S2 documents the post-S1 state, S3 packages the post-S1+S2 release.

---

## Sortie 1: Atomic CLI cleanup + ship/upload rewrite

**Priority**: 100 (only critical-path sortie that gates the rest)

**Why this is one sortie, not two**:
Iteration 02's plan split this into WU3.S1 (delete `CDNUploader` + `fatalError` ship/upload) and WU3.S3 (rewrite ship/upload on `publishModel`). That split required an intermediate broken-runtime commit. Iteration 03 folds them: one sortie deletes the old code and replaces the call sites atomically. The tree never has a half-state.

**Entry criteria**:
- [ ] F1 (pre-dispatch working-tree audit) passes.
- [ ] First sortie — no prerequisite sortie.

**Tasks**:

1. **Read the audit's drift list** (`REQUIREMENTS.md` §2) and the existing CLI source to confirm:
   - `Sources/acervo/CDNUploader.swift` exists at the size the audit reported (~13.6 KB).
   - `Sources/acervo/ShipCommand.swift` references `CDNUploader` at the line ranges the audit reported.
   - `Sources/acervo/UploadCommand.swift` references `CDNUploader` similarly.
   - `Sources/acervo/ToolCheck.swift` has a `requireAWS()`-shaped check.
   - `Sources/acervo/AcervoCLI.swift` help text mentions `aws`.

   If any of these don't match the audit, **halt and report** — the audit may be stale or the codebase has drifted further. Do not proceed.

2. **Study `DeleteCommand.swift` and `RecacheCommand.swift`** as the reference implementation. They show the exact pattern for: resolving `AcervoCDNCredentials` from env vars, building a progress reporter, calling the `Acervo.*` static API, handling errors. The ship/upload rewrites should mirror this style — same env-var conventions, same progress reporter wiring, same error surface.

3. **Rewrite `ShipCommand.run()`** to call `Acervo.publishModel(...)` directly with `keepOrphans: true` (per iteration 02 decision log: `ship == recache − orphan prune`). Preserve every existing CLI flag exactly — this is an implementation swap, not a UX change. Any user invoking `acervo ship` today must get the same flag surface tomorrow.

4. **Rewrite `UploadCommand.run()`** to call `Acervo.publishModel(...)` directly. Preserve flags identically. If `UploadCommand` and `ShipCommand` end up nearly identical, consider whether one can be expressed as a thin wrapper around the other; if the diff is small, do the consolidation. If non-trivial, leave them separate and note in the commit message.

5. **Delete `Sources/acervo/CDNUploader.swift`**. Verify with `git ls-files Sources/acervo/CDNUploader.swift` returning empty.

6. **Shrink `Sources/acervo/ToolCheck.swift`** to validate only `hf`. Remove any `requireAWS()` / `aws`-binary check. Audit `Sources/acervo/ProcessRunner.swift` for `aws`-specific helpers and remove them. Keep `ProcessRunner` itself — it's used by `hf` invocation.

7. **Update `Sources/acervo/AcervoCLI.swift`**: remove `aws` mentions from help text, command discussion, or any subcommand registration that referenced removed types.

8. **Update test files**:
   - `Tests/AcervoToolTests/ShipCommandTests.swift` — any test asserting `aws` invocation is rewritten to assert `URLProtocol`-mocked S3 traffic (mirror `RecacheCommandTests` patterns). Tests for argument parsing and validation stay as-is.
   - `Tests/AcervoToolTests/UploadCommandTests.swift` — same treatment.
   - `Tests/AcervoToolTests/ToolCheckTests.swift` — adjust the env tests for `hf`-only validation.
   - Run `make test` after each test file is updated to catch regressions early.

9. **Update `SUPERVISOR_STATE.md`** (per F2): mark Sortie 1 `COMPLETED` with the commit SHA and a one-line verification summary.

**Exit criteria**:

- [ ] `git ls-files Sources/acervo/CDNUploader.swift` returns nothing.
- [ ] `git grep -nE "\baws\b|CDNUploader|requireAWS" Sources/acervo/` returns no production-code matches.
- [ ] `git grep -nE "putObject|deleteObject|listObjects|SigV4|S3CDNClient" Sources/acervo/` returns zero matches (CLI is a thin wrapper).
- [ ] `make build` exit code 0.
- [ ] `make test` exit code 0. Specifically, `ShipCommandTests`, `UploadCommandTests`, `ToolCheckTests`, `DeleteCommandTests`, `RecacheCommandTests` all green.
- [ ] `make install-acervo && bin/acervo --help` succeeds; subcommand list shows `delete`, `recache`, `download`, `manifest`, `ship`, `upload`, `verify`.
- [ ] `bin/acervo ship --help` and `bin/acervo upload --help` succeed and show flag surfaces matching what the pre-sortie binary showed (manual flag-diff check — record in commit message).
- [ ] `SUPERVISOR_STATE.md` shows Sortie 1 `COMPLETED` with commit SHA.

**Anticipated risks**:

- **Test fixtures may assume `aws` is on PATH.** If `ShipCommandTests` or `UploadCommandTests` shell out to `aws` in a setup or teardown, those fixtures need to be replaced with `URLProtocol` mocks. The `S3CDNClientTests` and `PublishModelTests` already do this — copy their setup pattern.
- **`URLProtocol`-based tests racing across suites via PATH or env vars.** Iteration 02's TRIPWIRE GAUNTLET brief documented this exact failure (Sortie 10 PATH-race). If `ShipCommandTests` mutates `R2_*` env vars and `UploadCommandTests` does the same, both must nest under `ProcessEnvironmentSuite` (per the existing repo convention). Do not invent a new isolation pattern.
- **`ShipCommand` may have additional CLI behavior beyond CDN upload** (e.g. pre-flight checks, manifest generation, file staging). Inspect carefully before assuming `Acervo.publishModel` is a drop-in. If `ShipCommand` has logic that doesn't belong in `publishModel`, keep that logic in the command body — just replace the CDN-upload portion.

---

## Sortie 2: Documentation sweep

**Priority**: 50

**Entry criteria**:
- [ ] F1 (pre-dispatch working-tree audit) passes.
- [ ] Sortie 1 is `COMPLETED` per `SUPERVISOR_STATE.md`.

**Tasks**:

1. **`Docs/CDN_UPLOAD.md`** — Rewrite to describe the single-path flow:
   - The library-level API (`Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache`) is the surface.
   - The `acervo` CLI is a thin wrapper around that API.
   - Remove ALL `aws s3 sync` / `awscli install` / `aws configure` instructions.
   - Add (if not present) an "IAM key scoping" subsection: maintainer/CI keys get RW+delete; runtime keys (if any) get GET/HEAD only; mutation keys never ship in app bundles. (This was on iteration 02's WU4.S1 task list.)
   - Add (if not present) a "Concurrent publishes are not supported" warning. (Same.)
   - Show an example of `Acervo.publishModel(...)` being called programmatically from a CI script.

2. **`Docs/BUILD_AND_TEST.md`** — Remove `aws` install instructions (~lines 17, 277, 429 per audit). The only CLI dependency users need to install is `hf`.

3. **`Docs/PROJECT_STRUCTURE.md`** — Remove references to `CDNUploader` (~lines 34, 255, 280, 281, 296). Update the `Sources/acervo/` directory map to show the current file set after Sortie 1's deletions.

4. **`Docs/API_REFERENCE.md`** — Verify the following are documented (the audit suggests they may already be; verify and add anything missing):
   - `AcervoCDNCredentials` struct + initializer + default field values.
   - `SigV4Signer` struct + `PayloadHash` enum + `sign(_:payloadHash:date:)` method.
   - `S3CDNClient` actor + initializer + the four (or five, with put) public methods + the public result types.
   - `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:)`.
   - `Acervo.deleteFromCDN(modelId:credentials:progress:)`.
   - `Acervo.recache(modelId:stagingDirectory:credentials:fetchSource:keepOrphans:progress:)`.
   - `AcervoPublishProgress` enum with all cases.
   - `AcervoDeleteProgress` enum with all cases.
   - The four new `AcervoError` cases: `cdnAuthorizationFailed`, `cdnOperationFailed`, `publishVerificationFailed`, `fetchSourceFailed`.

5. **`README.md`** — Update the runtime-requirements paragraph (~line 75): name only `hf` (and any other live deps). Add (if missing) a one-paragraph mention of the new mutation API surface with a link to `Docs/CDN_UPLOAD.md`.

6. **Cross-cutting audit** — Run:
   ```bash
   grep -nE "aws s3|awscli|aws binary|install aws|aws cli|CDNUploader" Docs/*.md README.md
   ```
   Should return no install-or-invoke instructions. Historical/contextual mentions in `CHANGELOG.md` are out of scope and should be preserved.

7. **`CLAUDE.md` / `AGENTS.md`** — Quick Reference sections mention the mutation API. The audit suggests `CLAUDE.md` is already updated (was recently regenerated). Verify `AGENTS.md` is current; update if it lags.

8. **Update `SUPERVISOR_STATE.md`** (per F2): mark Sortie 2 `COMPLETED`.

**Exit criteria**:

- [ ] `grep -nE "aws s3|awscli|aws binary|install aws|aws cli" Docs/*.md README.md` returns no install-or-invoke instructions (CHANGELOG and archived docs out of scope).
- [ ] `grep -n "CDNUploader" Docs/*.md README.md` returns zero matches.
- [ ] `grep -nE "publishModel|deleteFromCDN|recache\(" Docs/API_REFERENCE.md` returns matches for all three.
- [ ] `make build` exit code 0 (no source changes in this sortie, but verify the tree didn't drift mid-sortie).
- [ ] `make test` exit code 0.
- [ ] `SUPERVISOR_STATE.md` shows Sortie 2 `COMPLETED` with commit SHA.

**Anticipated risks**:

- **`API_REFERENCE.md` may already document these APIs** from out-of-band updates. That's fine — verify accuracy and move on; don't duplicate.
- **`CHANGELOG.md` mentions of `aws`** are historical and stay. Do not edit CHANGELOG entries for past versions.
- **Subagent parallelism temptation** — iteration 02's plan suggested 4 sub-agents could update 8 doc files in parallel. **Do not do this.** Sub-agents racing on docs that cross-reference each other produce inconsistent terminology and broken links. One agent, sequential doc edits, full visibility into cross-doc impact.

---

## Sortie 3: Homebrew formula — strip `awscli` dependency

**Priority**: 10 — last sortie; independent of SwiftAcervo release cycle per REQUIREMENTS §3.3.

**Important — version/sha bump is automatic**: `.github/workflows/release.yml:74-85` fires a `repository-dispatch` event to `intrusive-memory/homebrew-tap` on every SwiftAcervo release, and the tap's CI updates `url`/`sha256`/`version` mechanically. This sortie does **NOT** touch those fields. Its scope is purely structural: remove the `awscli` dependency and the AWS line from the `caveats` block.

**Entry criteria**:
- [ ] F1 (pre-dispatch working-tree audit) passes.
- [ ] Sortie 2 is `COMPLETED` per `SUPERVISOR_STATE.md`.
- [ ] `../homebrew-tap/` exists and is a clean git repo. If not, this sortie is `CANCELED-WITH-HANDOFF` per F4 — file `Docs/incomplete/vault-broom-04/REQUIREMENTS.md` as a stub.

**Tasks**:

1. **Read `../homebrew-tap/Formula/acervo.rb`**. Verify (per audit):
   - `depends_on "awscli"` present (~line 11).
   - `caveats` block mentions AWS CLI (~lines 18–24).
   - Do **not** verify `url`/`sha256`/`version` values — those are CI-managed and may have changed since the audit.

2. **Remove `depends_on "awscli"`**. Leave `depends_on "hf"` (or whatever names the HF CLI) and any other live deps untouched.

3. **Update `caveats`**: drop the AWS CLI line. The block should now reference only the live deps that are NOT auto-installed by `depends_on` (e.g. instructions about `HF_TOKEN`, etc.).

4. **Audit sibling formulae** in `../homebrew-tap/Formula/`:
   ```bash
   ls ../homebrew-tap/Formula/
   grep -l "awscli" ../homebrew-tap/Formula/*.rb
   ```
   If any other formula in the tap still depends on `awscli` for unrelated reasons, **do not modify those files** — just record them in the brief.

5. **Commit and push the formula change** per the tap's own contribution conventions. Direct commit-to-main if that's how the tap operates; PR if the tap requires it. Read the tap's `README.md` or `CONTRIBUTING.md` first to determine which.

6. **Update `SUPERVISOR_STATE.md`** (per F2): mark Sortie 3 `COMPLETED`.

**Exit criteria**:

- [ ] `../homebrew-tap/Formula/acervo.rb` no longer contains `depends_on "awscli"`.
- [ ] `caveats` block no longer references AWS CLI.
- [ ] `url`, `sha256`, `version` are **unchanged from their pre-sortie values** (these are CI-managed; this sortie must not touch them).
- [ ] Formula change is committed AND pushed (or PR'd) per tap conventions.
- [ ] `git -C ../homebrew-tap log --oneline -1` references awscli removal (not a version bump).
- [ ] Sortie report (in `SUPERVISOR_STATE.md` and the brief) lists any sibling-formula `awscli` matches found.
- [ ] `SUPERVISOR_STATE.md` shows Sortie 3 `COMPLETED` with commit SHA.

**Anticipated risks**:

- **`../homebrew-tap/` may not be present on the executing machine.** This is normal — the tap is a sibling repo, not a submodule. F4 ("no silent deferrals") means: if not present, mark `CANCELED-WITH-HANDOFF`, file `Docs/incomplete/vault-broom-04/REQUIREMENTS.md` as a stub referencing this sortie, document in the brief.
- **The tap may have uncommitted work** from another effort. Halt and ask the user before touching it. Do not stash, do not reset.
- **Accidentally touching `url`/`sha256`/`version`** — guard explicitly. The CI auto-bump will overwrite anything this sortie sets, but in the meantime a manually-set wrong sha256 makes the tap install briefly broken. Exit criterion #3 enforces this.

---

## Critical path

```
[F1 audit] → S1 → [F1] → S2 → [F1] → S3 → [F6 closeout: BRIEF.md + state file clean]
```

Three sorties, fully serial. No parallelism. Total expected duration: ~1 working day for a focused agent, assuming no rebase storms from F5 violations.

## Risks at the mission level

| Risk | Likelihood | Mitigation |
|---|---|---|
| Audit (REQUIREMENTS §2) is stale by the time Sortie 1 runs | Low | F1 + Sortie 1 Task 1 (re-verify drift before editing). If drift changed, halt and re-audit. |
| `aws`-binary fallback was load-bearing for some user workflow we don't know about | Low | The library's `Acervo.publishModel` uses native SigV4, same protocol surface as `aws s3 cp`. Any user invoking `acervo ship` today gets the same upload outcome via the new path. If a user has a script that runs `aws` directly *outside* `acervo`, this mission doesn't affect them. |
| Out-of-band PR lands on `development` during the mission window touching scoped files | Medium | F5 (halt-and-rebase). Iteration 02 lost the mission to this exact pattern. |
| `Tests/AcervoToolTests/` has hidden coupling to `CDNUploader` we don't see in the audit | Medium | Sortie 1 Task 8 runs `make test` after each test file update. Failures point to the coupling immediately. |
| Homebrew tap not available locally | Medium | F4: `CANCELED-WITH-HANDOFF`, file iteration-04 stub. Not a mission failure. |
| Supervisor state file goes stale mid-mission (iteration 02's primary failure) | Low (by design) | F2 invariant: sortie isn't COMPLETED until state file is updated. Enforced as exit criterion, not as separate reconciliation step. |
| New public API sneaks in via `ShipCommand` consolidation | Low | F6 + REQUIREMENTS §4.5: review diff for new public symbols at closeout. |

## Open questions

**None.** Every decision point from iteration 02 that contributed to drift has been pinned:

- `fatalError` vs `@available(*, unavailable)` for old commands → moot; iteration 03 atomically rewrites instead of stubbing.
- Lift `ManifestGenerator` to library → already done in iteration 02 (audit-verified).
- `cdnAuthorizationFailed` declaration site → already done in iteration 02 (audit-verified).
- `confirmOnTTY` implementation → already done in iteration 02 (audit-verified).
- Homebrew tag-gate → explicit stop-point per Sortie 3 Task 4, not a blocker.

If the executing agent surfaces an open question, the supervisor halts dispatch, records the question in `SUPERVISOR_STATE.md`, and prompts the user. No agent guesses.

## Summary

| Metric | Value |
|---|---|
| Work units | 1 |
| Sorties | 3 |
| Critical path length | 3 |
| Maximum parallelism | 1 (sequential by design) |
| New public APIs | 0 (REQUIREMENTS §4.5) |
| Files deleted | 1 (`Sources/acervo/CDNUploader.swift`) |
| Files modified (Sources) | ~5 (`ShipCommand`, `UploadCommand`, `ToolCheck`, `ProcessRunner`, `AcervoCLI`) |
| Files modified (Docs) | ~6 (`CDN_UPLOAD`, `BUILD_AND_TEST`, `PROJECT_STRUCTURE`, `API_REFERENCE`, `README`, possibly `AGENTS`) |
| Files modified (external) | 1 (`../homebrew-tap/Formula/acervo.rb`, deferred-by-design) |
| Framework controls | 6 (F1–F6) |
| Predecessor brief consulted | `../../complete/tripwire-gauntlet-02-brief.md` for process-discovery patterns |
| Predecessor learnings consulted | `../../complete/vault-broom-02/SUPERSEDED.md` for failure-mode patterns |
