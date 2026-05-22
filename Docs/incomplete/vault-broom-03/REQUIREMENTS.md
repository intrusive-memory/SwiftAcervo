---
operation_name: OPERATION VAULT BROOM
iteration: 03
state: incomplete
status: draft
predecessor: ../../complete/vault-broom-02/
audit_date: 2026-05-21
---

# REQUIREMENTS — VAULT BROOM iteration 03

## 1. What this iteration is

Iteration 03 closes the **drift gap** between what OPERATION VAULT BROOM was supposed to deliver and what actually shipped to `main`. Iteration 02's library and mutation-API work shipped cleanly (v0.10.1 / v0.11.0); its **CLI cleanup and documentation halves never executed**, and the Homebrew formula was never updated.

Concretely, the CLI today carries **two parallel CDN code paths**:

- `acervo recache` and `acervo delete` go through the native SigV4 stack (`Acervo.recache` / `Acervo.deleteFromCDN`).
- `acervo ship` and `acervo upload` still instantiate `CDNUploader` and shell out to the `aws` binary.

This is the "scattered state" symptom. Iteration 03 collapses the two paths into one, removes the `aws` dependency, and updates the docs + Homebrew formula to match.

**Iteration 03 ships NO new public APIs.** It is a consistency / cleanup mission. The library surface remains exactly as v0.14.1-dev exposes it today.

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

### Confirmed drift (this iteration's actual scope)

1. **`Sources/acervo/CDNUploader.swift` still exists** (~13.6 KB). The whole point of the v0.9.0 mission was to delete this file.
2. **`Sources/acervo/ToolCheck.swift` still requires `aws`** (lines ~104–110). Should validate only `hf`.
3. **`Sources/acervo/AcervoCLI.swift` help text still mentions `aws`** (line ~24).
4. **`Sources/acervo/ShipCommand.swift` still instantiates `CDNUploader`** (lines ~250–299+). Should call `Acervo.publishModel(...)` directly.
5. **`Sources/acervo/UploadCommand.swift` still instantiates `CDNUploader`** (lines ~123–180). Should call `Acervo.publishModel(...)` directly.
6. **`Docs/CDN_UPLOAD.md`** still contains `aws s3 sync` instructions and `aws` install steps.
7. **`Docs/BUILD_AND_TEST.md`** still mentions `aws` install (~lines 17, 277, 429).
8. **`Docs/PROJECT_STRUCTURE.md`** still documents `CDNUploader` (~lines 34, 255, 280, 281, 296).
9. **`README.md`** still tells users "The `aws` and `hf` CLIs are required at runtime" (~line 75).
10. **`../homebrew-tap/Formula/acervo.rb`** still has `depends_on "awscli"`, still mentions AWS CLI in caveats, still pins v0.8.4.

### Out of scope explicitly

- Anything in WU1 / WU2 / WU3.S2 / RecacheCommand (already shipped, audit clean).
- Any new public API. The library surface is frozen for this iteration.
- The deferred SwiftVinetas manifest re-upload (different mission — slug-registry §1.2, see root `REQUIREMENTS.md` if present).
- The `AcervoToolIntegrationTests` CI gating P1 (TRIPWIRE GAUNTLET carry-forward — different mission).

## 3. Open items

### 3.1 CLI: collapse the two CDN paths

The CLI must have exactly one path to the CDN. `Sources/acervo/CDNUploader.swift` is deleted. `ShipCommand` and `UploadCommand` call `Acervo.publishModel(...)` directly, mirroring how `DeleteCommand` and `RecacheCommand` already work. `ToolCheck` validates only `hf`. The `aws` binary is no longer a runtime dependency for any code path.

**Acceptance**:
1. `git ls-files Sources/acervo/CDNUploader.swift` returns nothing.
2. `git grep -nE "\baws\b|CDNUploader|requireAWS" Sources/acervo/` returns no production-code matches (error messages and historical comments are not production code; pragmatically, zero matches is the target).
3. `git grep -nE "putObject|deleteObject|listObjects|SigV4|S3CDNClient" Sources/acervo/` returns zero matches — the CLI is a thin wrapper, never touches S3 primitives directly.
4. `bin/acervo ship --help` and `bin/acervo upload --help` succeed and show the same flag surface they show today (this is **not** a breaking change for users — only an implementation swap).
5. `make build` and `make test` are both green at HEAD after the change. Existing `ShipCommandTests` / `UploadCommandTests` are updated (not deleted) to match the new implementation; any test asserting `aws` invocation is rewritten to assert `URLProtocol`-mocked S3 traffic instead.

### 3.2 Documentation: strip `aws` / `CDNUploader` references

The repo's user-facing docs reflect the single-path architecture. No reader walks away thinking they need to install `aws` to use SwiftAcervo.

**Acceptance**:
1. `grep -nE "aws s3|awscli|aws binary|install aws|aws cli" Docs/*.md README.md` returns no install-or-invoke instructions (historical references in CHANGELOG.md or archived docs are not in scope).
2. `Docs/CDN_UPLOAD.md` describes the `Acervo.publishModel` / `acervo ship` / `acervo recache` flow with no fallback aws-binary section.
3. `Docs/PROJECT_STRUCTURE.md` no longer references `CDNUploader`.
4. `Docs/BUILD_AND_TEST.md` no longer instructs users to install `aws`.
5. `README.md` runtime-requirements paragraph names only `hf` (and any other live deps), not `aws`.
6. `Docs/API_REFERENCE.md` documents `Acervo.publishModel`, `Acervo.deleteFromCDN`, `Acervo.recache`, `AcervoCDNCredentials`, `SigV4Signer`, `S3CDNClient`, `AcervoPublishProgress`, `AcervoDeleteProgress`, and the 4 new error cases. (Verify; if already present from out-of-band docs work, no-op.)

### 3.3 Homebrew formula update

`../homebrew-tap/Formula/acervo.rb` is updated to reflect the single-path architecture. **Scope is limited to structural changes** — the `url`/`sha256`/`version` bump is handled automatically on release by `.github/workflows/release.yml:74-85`, which fires a `repository-dispatch` event to `intrusive-memory/homebrew-tap`. This sortie does not touch those fields.

**Acceptance**:
1. `../homebrew-tap/Formula/acervo.rb` no longer contains `depends_on "awscli"`.
2. The `caveats` block no longer references AWS CLI.
3. `url`, `sha256`, `version` are **NOT modified by this sortie** — they remain whatever the tap currently pins; CI overwrites them on the next SwiftAcervo release.
4. The change is committed and pushed to the tap (or sent as a PR), per the tap's own contribution conventions. No "wait for tag" stop-point — the change is independent of the SwiftAcervo release cycle.

## 4. Process requirements (iteration-03 learnings)

These are non-negotiable framework controls for this mission. They exist because iteration 02 violated all of them.

### 4.1 Pre-dispatch working-tree audit

Before any sortie dispatch, the supervisor must verify:
- `git status --porcelain` shows changes consistent with the mission branch only (no half-applied rebases from other branches).
- Current branch is the iteration-03 mission branch (e.g. `mission/vault-broom/03`).
- HEAD's parent chain is reachable from `development`.

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

### 4.4 No out-of-band shipping during mission window

While iteration 03 is in flight, no PRs touching `Sources/acervo/`, `Docs/CDN_UPLOAD.md`, `Docs/BUILD_AND_TEST.md`, `Docs/PROJECT_STRUCTURE.md`, `README.md`, or `../homebrew-tap/Formula/acervo.rb` should land on `development` or `main` from branches other than `mission/vault-broom/03`. This is the iteration-02 failure mode that produced v0.10.1/v0.11.0 outside the supervisor framework. If hotfix work in those paths becomes urgent, the supervisor halts iteration 03, the hotfix lands, and iteration 03 rebases on the new HEAD before resuming.

### 4.5 No new public API

Iteration 03 ships zero new public types, methods, or CLI flags. Any diff that introduces a new public symbol fails review. The only API-shaped change permitted is **removing** the implicit dependency on `aws` being on PATH — a contract narrowing, not a widening.

## 5. Sortie surface

Three sorties. See `EXECUTION_PLAN.md` for the detailed plan.

| Sortie | Scope | Files touched | Exit gate |
|---|---|---|---|
| S1 | Atomic CLI cleanup + ship/upload rewrite | `Sources/acervo/` (delete CDNUploader.swift, edit ShipCommand/UploadCommand/ToolCheck/AcervoCLI), `Tests/AcervoToolTests/` | `make build` + `make test` green; greps in §3.1 clean |
| S2 | Documentation sweep | `Docs/CDN_UPLOAD.md`, `Docs/BUILD_AND_TEST.md`, `Docs/PROJECT_STRUCTURE.md`, `Docs/API_REFERENCE.md`, `README.md` | greps in §3.2 clean |
| S3 | Homebrew formula — drop `awscli` dep | `../homebrew-tap/Formula/acervo.rb` | Pushed/PR'd per tap conventions; `url`/`sha256`/`version` untouched (CI-managed) |

S2 depends only on S1's existence (it documents the post-S1 state). S3 is fully independent of S1/S2 and the SwiftAcervo release cycle — it's a structural edit to a sibling repo's formula, and the version/sha bump is handled automatically by `.github/workflows/release.yml` on the next SwiftAcervo release.

## 6. Verdict targets

This mission's exit brief should answer:

1. **Did the audit's drift list close completely?** Every item in §2's "Confirmed drift" is either resolved or filed as `CANCELED-WITH-HANDOFF` with a named successor mission.
2. **Did the process requirements hold?** §4.1 (working-tree audit), §4.2 (state-write-before-completion), §4.3 (no silent deferrals), §4.4 (no out-of-band shipping), §4.5 (no new public API) — each verified per-sortie and at closeout.
3. **What carries forward?** Any new drift discovered during execution, plus the Homebrew tag-gate handoff (always present per §3.3).
