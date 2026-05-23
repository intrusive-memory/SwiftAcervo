---
operation_name: OPERATION VAULT BROOM
iteration: 03
state: completed
status: executed
closes_drift_from: ../../complete/vault-broom-02/
audit_date: 2026-05-21
spec_refined: 2026-05-22
---

# REQUIREMENTS — VAULT BROOM iteration 03

## 1. What this iteration is

Iteration 03 closes the **drift gap** between what OPERATION VAULT BROOM was supposed to deliver and what actually shipped to `main`. Iteration 02's library and mutation-API work shipped cleanly (v0.10.1 / v0.11.0); its **CLI cleanup and documentation halves never executed**.

Concretely, the CLI today carries **two parallel CDN code paths**:

- `acervo recache` and `acervo delete` go through the native SigV4 stack (`Acervo.recache` / `Acervo.deleteFromCDN`).
- `acervo ship` and `acervo upload` still instantiate `CDNUploader` and shell out to the `aws` binary.

This is the "scattered state" symptom. Iteration 03 collapses the two paths into one, removes the `aws` runtime dependency, and updates the docs to match.

**Iteration 03 ships NO new public library APIs.** The library surface remains exactly as v0.14.1-dev exposes it today. The CLI has two visible behavior changes:

- `aws` is no longer a runtime dependency for any code path.
- `ship` and `upload` now prune CDN-side orphan files by default (matching `recache`'s manifest-truth model); a new `--keep-orphans` flag preserves the previous additive behavior.

These are CLI-surface changes, not library-surface changes.

**Homebrew is out of scope.** The tap auto-bumps via `.github/workflows/release.yml`'s `repository-dispatch` on the next release; once iteration 03 ships, the formula will distribute the new binary without further work. Any `depends_on "awscli"` cleanup in the formula is a separate tap-side concern, handled after release.

**No release in this iteration.** The version-bump decision is deferred — iteration 03 lands on `development` and a release is cut later as a separate operation.

## 2. Source-of-truth audit (2026-05-21)

Ground truth from a fresh code audit, not from the iteration-02 supervisor state file (which is known unreliable — see `../../complete/vault-broom-02/SUPERSEDED.md`):

### Verified shipped and correct (do not re-implement)

- `Sources/SwiftAcervo/AcervoCDNCredentials.swift`
- `Sources/SwiftAcervo/SigV4Signer.swift` (+ canonical AWS test vectors)
- `Sources/SwiftAcervo/S3CDNClient.swift` (list/head/delete + multipart put)
- `Sources/SwiftAcervo/AcervoError.swift` — all 4 new cases present
- `Sources/SwiftAcervo/AcervoPublishProgress.swift`
- `Sources/SwiftAcervo/AcervoDeleteProgress.swift`
- `Sources/SwiftAcervo/Acervo+CDNMutation.swift` — `publishModel` / `deleteFromCDN` / `recache` with the 11-step frozen order, manifest-LAST, orphan prune
- `Sources/SwiftAcervo/ManifestGenerator.swift` (lifted from CLI, public)
- `Sources/acervo/DeleteCommand.swift` (uses `Acervo.deleteFromCDN`)
- `Sources/acervo/RecacheCommand.swift` (uses `Acervo.recache`)
- `Sources/acervo/TTYConfirm.swift`
- Library test files: `SigV4SignerTests`, `S3CDNClientTests`, `PublishModelTests`, `DeleteFromCDNTests`, `RecacheTests`
- Test mock infrastructure: `StubURLProtocol` (in `Tests/AcervoToolTests/`), `MockURLProtocol.session()` (in `Tests/SwiftAcervoTests/`). S1 wires the rewritten CLI tests against these — no new mock infra required.

### Confirmed drift (this iteration's actual scope)

1. **`Sources/acervo/CDNUploader.swift` still exists** (~13.6 KB / 371 lines). The whole point of the v0.9.0 mission was to delete this file.
2. **`Sources/acervo/ToolCheck.swift` still requires `aws`** (lines ~104–110). Should validate only `hf`.
3. **`Sources/acervo/AcervoCLI.swift` help text still mentions `aws`** (line ~24).
4. **`Sources/acervo/ShipCommand.swift` still instantiates `CDNUploader`** (lines 250–308). Should call `Acervo.publishModel(...)` directly. CHECK 0/1 (HF-side) remain in the CLI.
5. **`Sources/acervo/UploadCommand.swift` still instantiates `CDNUploader`** (lines 123–183). Should call `Acervo.publishModel(...)` directly.
6. **`Docs/CDN_UPLOAD.md`** still contains `aws s3 sync` instructions and `aws` install steps.
7. **`Docs/BUILD_AND_TEST.md`** still mentions `aws` install (~lines 17, 277, 429).
8. **`Docs/PROJECT_STRUCTURE.md`** still documents `CDNUploader` (~lines 34, 255, 280, 281, 296).
9. **`README.md`** still tells users "The `aws` and `hf` CLIs are required at runtime" (~line 75).

### Out of scope explicitly

- Anything in WU1 / WU2 / WU3.S2 / RecacheCommand (already shipped, audit clean).
- Any new public library API. The library surface is frozen for this iteration.
- Homebrew formula edits. The tap auto-bumps from `release.yml`; any `depends_on "awscli"` removal is a separate tap-side change after the next release.
- PR35 cache-bypass on `publishModel` post-upload readback. Tracked in `Docs/incomplete/QUEUE.md` carry-forwards; not adopted here to keep the cleanup mission scoped. Revisit after VB3 ships.
- The deferred SwiftVinetas manifest re-upload (different mission — slug-registry §1.2).
- The `AcervoToolIntegrationTests` CI gating P1 (TRIPWIRE GAUNTLET carry-forward — different mission).

## 3. Open items

### 3.1 CLI: collapse the two CDN paths

The CLI must have exactly one path to the CDN. `Sources/acervo/CDNUploader.swift` is deleted. `ShipCommand` and `UploadCommand` call `Acervo.publishModel(...)` directly, mirroring how `DeleteCommand` and `RecacheCommand` already work. `ToolCheck` validates only `hf`. The `aws` binary is no longer a runtime dependency for any code path.

#### 3.1.1 Scope split for `ship` and `upload`

`ShipCommand` is a 6-CHECK pipeline today. The rewrite keeps the HuggingFace-side checks in the CLI and delegates the CDN-side checks to `Acervo.publishModel`:

| Stage | Owner before | Owner after |
|---|---|---|
| Subprocess `hf download` | CLI | CLI (unchanged) |
| CHECK 0 (HF tree completeness) | CLI (`DownloadCommand.runCompletenessCheck`) | CLI (unchanged) |
| CHECK 1 (HF LFS SHA-256 verify) | CLI | CLI (unchanged) |
| Manifest gen (CHECK 2 zero-byte, CHECK 3 post-write checksum) | CLI (`ManifestGenerator`) | `Acervo.publishModel` step 1 |
| CHECK 4 (re-hash staged files vs manifest) | CLI (`CDNUploader.verifyBeforeUpload`) | `Acervo.publishModel` step 4 |
| Upload + manifest-LAST + orphan-prune | CLI (`CDNUploader.sync` / `uploadManifest`) | `Acervo.publishModel` steps 5–11 |
| CHECK 5 (CDN manifest readback) | CLI (`CDNUploader.verifyManifestOnCDN`) | `Acervo.publishModel` step 8 |
| CHECK 6 (config.json spot-check) | CLI (`CDNUploader.spotCheckFileOnCDN`) | `Acervo.publishModel` step 9 |

`UploadCommand`'s rewrite is the same minus the HF download/verify phase — it starts from a pre-staged directory and delegates everything CDN-side to `publishModel`.

The CLI maps `AcervoPublishProgress` enum cases back to the existing `CHECK N passed` stdout prints to preserve operator-visible output:

- `.generatingManifest` → "manifest written to ..." (preserves existing line)
- `.verifyingManifest` → "CHECK 4 passed: all staged files match the manifest."
- `.uploadingFile(name:bytesSent:bytesTotal:)` → per-file progress reporter (replaces today's `aws s3 sync` stderr parsing)
- `.uploadingManifest` → "manifest.json uploaded to CDN."
- `.verifyingPublic(stage: "manifest")` → "CHECK 5 passed: CDN manifest verified."
- `.verifyingPublic(stage: "sample-file")` → "CHECK 6 passed: config.json spot-check succeeded."

#### 3.1.2 New CLI flag: `--keep-orphans`

`Acervo.publishModel` defaults to `keepOrphans: false`, deleting CDN-side files not present in the new manifest (step 11). `CDNUploader.sync` today never deleted anything (`aws s3 sync` without `--delete`). To preserve a one-line escape hatch for operators who relied on the additive behavior, `ship` and `upload` gain a `--keep-orphans` flag that maps directly to `Acervo.publishModel(keepOrphans: true)`. Default (no flag) prunes — this matches the manifest-truth model that `recache` already follows.

This is a CLI-surface addition, not a library API addition. The library API is `publishModel`'s existing `keepOrphans:` parameter, which already ships in v0.14.1-dev.

#### 3.1.3 `--dry-run` semantics

Today `--dry-run` passes `--dryrun` to `aws s3 sync`. After the rewrite it must short-circuit before any `S3CDNClient.putObject` call, print a "would upload N files (X bytes total)" summary, and return exit 0 without mutating the CDN. `Acervo.publishModel` does not currently support dry-run natively; the CLI implements it as a pre-flight loop over the generated manifest. **If implementing this in the CLI requires adding a `dryRun:` parameter to `publishModel`, the supervisor halts and escalates** — that would violate §4.5 "no new public library API" and needs explicit approval.

**Acceptance**:

1. `git ls-files Sources/acervo/CDNUploader.swift` returns nothing.
2. `git grep -nE "\baws\b|CDNUploader|requireAWS" Sources/acervo/` returns **zero** matches — no carve-out for "historical" references. Error strings, help text, and code comments are rewritten or deleted.
3. `git grep -nE "putObject|deleteObject|listObjects|SigV4|S3CDNClient" Sources/acervo/` returns zero matches — the CLI is a thin wrapper, never touches S3 primitives directly.
4. `bin/acervo ship --help` and `bin/acervo upload --help` succeed and show the same flag surface they show today **plus** `--keep-orphans`. Pre-existing flags (`--bucket`, `--prefix`, `--endpoint`, `--dry-run`, `--force`, `--no-verify`, `--token`, `--source`, `--output`) retain their current names and semantics.
5. **Behavioral parity on a host without `aws`**: on a system where `which aws` returns empty, `acervo ship mlx-community/Qwen3-0.6B-4bit` and `acervo upload mlx-community/Qwen3-0.6B-4bit <staged-dir>` both complete successfully against `MockURLProtocol.session()` in tests, and against a live R2 bucket in manual smoke. This is the user-visible win for this mission.
6. `make build` and `make test` are both green at HEAD after the change.
7. CLI test files updated, not deleted: `Tests/AcervoToolTests/ShipCommandTests.swift`, `Tests/AcervoToolTests/UploadCommandTests.swift`. Any assertion that previously checked for `aws` subprocess invocation is rewritten to assert `MockURLProtocol`-mediated S3 traffic. `Tests/AcervoToolTests/CDNUploaderTests.swift` is **deleted** alongside `CDNUploader.swift`.
8. `--dry-run` exits 0 without making any S3 PUT calls (verified via `MockURLProtocol` request counter).
9. New test: `ship` and `upload` with `--keep-orphans` invoke `publishModel(keepOrphans: true)`; without the flag invoke with `keepOrphans: false`. (One test per command, two assertions each.)

### 3.2 Documentation: strip `aws` / `CDNUploader` references

The repo's user-facing docs reflect the single-path architecture. No reader walks away thinking they need to install `aws` to use SwiftAcervo.

**Acceptance**:

1. `grep -nE "aws s3|awscli|aws binary|install aws|aws cli" Docs/*.md README.md` returns no install-or-invoke instructions. Historical references in `CHANGELOG.md` and under `Docs/complete/` are out of scope and may remain.
2. `Docs/CDN_UPLOAD.md` describes the `Acervo.publishModel` / `acervo ship` / `acervo recache` flow with no fallback aws-binary section. Adds a brief subsection on the new orphan-prune default and `--keep-orphans` escape hatch.
3. `Docs/PROJECT_STRUCTURE.md` no longer references `CDNUploader`.
4. `Docs/BUILD_AND_TEST.md` no longer instructs users to install `aws`.
5. `README.md` runtime-requirements paragraph names only `hf` (and any other live deps), not `aws`.
6. `Docs/API_REFERENCE.md` audit is part of S2 (deferred during requirements drafting). Expected post-state: documents `Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache`, `AcervoCDNCredentials`, `SigV4Signer`, `S3CDNClient`, `AcervoPublishProgress`, `AcervoDeleteProgress`, and the 4 v0.10/v0.11 error cases (`publishVerificationFailed`, `publishOrphanPruneFailed`, `deleteVerificationFailed`, `recacheVerificationFailed`). S2 audits and patches any gaps it finds.
7. `CHANGELOG.md` gains an `Unreleased` entry covering: dropped `aws` runtime dep on `ship`/`upload`; orphan-prune now default with `--keep-orphans` escape hatch; `CDNUploader` removed (internal); CLI test rewrite. Upgrade-note paragraph called out for operators scripting around the previous additive-only behavior. Version number is assigned when the release is cut, not in this mission.

## 4. Process requirements (iteration-03 learnings)

These are non-negotiable framework controls for this mission. They exist because iteration 02 violated them.

### 4.1 Pre-dispatch working-tree audit

Before any sortie dispatch, the supervisor must verify:

- `git status --porcelain` shows changes consistent with the mission branch only (no half-applied rebases from other branches).
- Current branch is the iteration-03 mission branch (e.g. `mission/vault-broom/03`).
- HEAD's parent chain is reachable from `development`.
- **Root contains no abandoned mission planning artifacts from prior cycles.** `REQUIREMENTS.md` and `EXECUTION_PLAN.md` at the repo root must either carry frontmatter matching this iteration (`iteration: 03`) or be absent. (This catches the failure mode observed at 2026-05-22 branch-cut, where stale planning docs from a prior iteration were sitting in root.)

If any check fails, the supervisor halts and reports — does not dispatch.

### 4.2 State-write-before-completion invariant

Every sortie's exit criteria explicitly include:

- "`Docs/incomplete/vault-broom-03/SUPERVISOR_STATE.md` updated with this sortie's commit SHA and `COMPLETED` status."

A sortie is not COMPLETED until the state file reflects it. The mission cannot proceed to the next sortie until the state file is current. This eliminates iteration 02's "observed state wins" reconciliation pattern.

### 4.3 Mission closeout invariant

The mission cannot be marked COMPLETE until:

- Every sortie in the plan is marked COMPLETED in the state file (no `DEFERRED`, no `NOT_STARTED`, no missing entries).
- A brief is filed at `Docs/incomplete/vault-broom-03/BRIEF.md` summarizing what shipped and any carry-forward items.
- Only then does `/organize-agent-docs` move the directory to `Docs/complete/`.

If a sortie genuinely cannot complete in this iteration, the supervisor must explicitly file a follow-up requirement in a new mission (e.g. `Docs/incomplete/vault-broom-04/`) and mark the iteration-03 sortie `CANCELED-WITH-HANDOFF` referencing the successor. No silent deferrals.

### 4.4 No new public library API

Iteration 03 ships zero new public library types, methods, or symbols in `Sources/SwiftAcervo/`. The CLI's `--keep-orphans` flag is a CLI-surface change, not a library-surface change. Any diff that introduces a new public symbol in the library target fails review. The only library-shaped change permitted is removing the implicit dependency on `aws` being on PATH — a contract narrowing, not a widening.

## 5. Sortie surface

Two sorties. See `EXECUTION_PLAN.md` for the detailed plan.

| Sortie | Scope | Files touched | Exit gate |
|---|---|---|---|
| S1 | Atomic CLI cleanup + ship/upload rewrite + `--keep-orphans` flag | `Sources/acervo/` (delete CDNUploader.swift; edit ShipCommand, UploadCommand, ToolCheck, AcervoCLI), `Tests/AcervoToolTests/` (delete CDNUploaderTests; rewrite Ship/UploadCommandTests against MockURLProtocol) | `make build` + `make test` green; greps in §3.1 clean; `--keep-orphans` visible in `--help`; behavioral-parity check on aws-less host passes |
| S2 | Documentation sweep + API_REFERENCE audit + CHANGELOG entry | `Docs/CDN_UPLOAD.md`, `Docs/BUILD_AND_TEST.md`, `Docs/PROJECT_STRUCTURE.md`, `Docs/API_REFERENCE.md`, `README.md`, `CHANGELOG.md` | greps in §3.2 clean; 0.15.0 CHANGELOG entry present with operator upgrade note |

S2 depends only on S1's existence (it documents the post-S1 state). S2 cannot start until S1 is marked COMPLETED in the state file.

## 6. Verdict targets

This mission's exit brief should answer:

1. **Did the audit's drift list close completely?** Every item in §2's "Confirmed drift" is either resolved or filed as `CANCELED-WITH-HANDOFF` with a named successor mission.
2. **Did the process requirements hold?** §4.1 (working-tree + stale-root audit), §4.2 (state-write-before-completion), §4.3 (no silent deferrals), §4.4 (no new public library API) — each verified per-sortie and at closeout.
3. **What carries forward?** Any new drift discovered during execution. Standing carry-forwards (not addressed by this mission, still tracked in `QUEUE.md`): PR35 cache-bypass on `publishModel` readback; Homebrew formula `awscli`-dep cleanup after the next release; version-bump decision for whatever release ships VB3.
