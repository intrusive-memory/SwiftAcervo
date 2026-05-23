---
operation_name: OPERATION VAULT BROOM
iteration: 02
state: superseded
superseded_by: ../../incomplete/vault-broom-03/
archived_on: 2026-05-21
---

# Why these files are here (and were renamed)

These two files were previously located at `Docs/incomplete/tripwire_gauntlet_02_*` under a **misnamed prefix**. They have nothing to do with OPERATION TRIPWIRE GAUNTLET (a separate, completed testing mission filed at `Docs/complete/tripwire-gauntlet-02-brief.md`). Their actual content is OPERATION VAULT BROOM iteration 02 — the CDN delete/recache mission that originally targeted v0.9.0.

## What iteration 02 actually accomplished

Per the 2026-05-21 reality audit of the v0.14.1-dev codebase, iteration 02's *code* was largely delivered — but **outside the supervisor framework**:

- **WU1** (SigV4 + S3CDNClient + multipart): fully shipped, in-supervisor (`14fdfe7 → 4406de2 → dfbfaf0`).
- **WU2** (publishModel + deleteFromCDN + recache + error/progress types): library code fully shipped. WU2.S1/S2 landed in-supervisor (`02a37c5` + the WU2.S2 reconciled commits). WU2.S3 (`deleteFromCDN` + `recache`) was deferred at end of iteration 02; the code subsequently shipped as v0.10.1 (`6c66b5a`) and v0.11.0 (`7676cc3`) via plain feature PRs, **without** any supervisor-state update to reflect closeout.
- **WU3.S2** (DeleteCommand + TTYConfirm): shipped via v0.11.0.
- **WU3.S3 RecacheCommand half**: shipped via v0.11.0.
- **WU3.S1** (delete `CDNUploader.swift` + drop `aws` shell-out + shrink `ToolCheck`): **NEVER EXECUTED**.
- **WU3.S3 ship/upload halves** (rewrite `ShipCommand`/`UploadCommand` on `publishModel`): **NEVER EXECUTED**.
- **WU4.S1** (docs cleanup): **NEVER EXECUTED**.
- **WU4.S2** (version bump): made moot by direct version progression to 0.10.x / 0.11.x / 0.14.x.
- **WU4.S3** (Homebrew formula): **NEVER EXECUTED**. `../homebrew-tap/Formula/acervo.rb` still has `depends_on "awscli"` and pins v0.8.4.

## What went wrong (root-cause notes for iteration 03)

1. **State drift**: WU2.S1's agent finished + committed but the supervisor state file was never written. The mission resumed via "observed state wins" reconciliation — meaning the framework's crash-safety guarantee was already broken at that point.
2. **Working-tree contamination**: a half-applied `fix/app-group-env-resolution` rebase was discovered in the working tree mid-mission, using macOS-only Security APIs that broke iOS compilation. Supervisor discarded those changes per user option-A. Working-tree state was never audited *before* dispatch.
3. **Out-of-band shipping**: After WU2.S2 landed, the user directed "ship what's done + reorg, defer WU2.S3/WU3/WU4 to next iteration." That next iteration **was never formally started**. The deferred work was picked up via direct feature PRs (`feature/cdn-delete-recache` → v0.10.1 → v0.11.0). The supervisor state file froze and no one closed it out.
4. **Filename corruption**: somebody renamed these files with a `tripwire_gauntlet_02_*` prefix when archiving, conflating two unrelated missions.
5. **Parallel CDN code paths shipped to users**: because WU3.S1 and the ship/upload halves of WU3.S3 never ran, the CLI today runs two CDN stacks side-by-side — `recache`/`delete` go through native SigV4; `ship`/`upload` still shell out to `aws` via `CDNUploader`. This has been live since v0.11.0 without complaint, but it's tech debt + inconsistent UX.

## Superseded by iteration 03

`Docs/incomplete/vault-broom-03/` carries the iteration-03 plan, which addresses **only the actual drift** (WU3.S1 cleanup, WU3.S3 ship/upload rewrites, WU4.S1 docs, WU4.S3 Homebrew). No code already shipped in v0.10.x/v0.11.x is re-implemented.

The originals (`EXECUTION_PLAN.md` + `SUPERVISOR_STATE.md` in this directory) are preserved verbatim for historical reference and as planning input for iteration 03's learnings.
