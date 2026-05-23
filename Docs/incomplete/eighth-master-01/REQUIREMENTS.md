---
operation_name: OPERATION EIGHTH-MASTER
iteration: 01
state: queued
status: draft — awaits execution-plan refinement
predecessor: ../../complete/quartermaster-torrent-01/
predecessor_verdict: PARTIAL_SALVAGE
parked_sibling: ../../parked/quartermaster-torrent-02/
created: 2026-05-21
---

# REQUIREMENTS — OPERATION EIGHTH-MASTER iteration 01

## Naming heritage

The operation name continues the QUARTERMASTER lineage — eighth-master extends the line. The work descends directly from QUARTERMASTER TORRENT iteration 01's `PARTIAL_SALVAGE` verdict + the 2026-05-20 on-disk audit that surfaced a higher-priority concern than chunked-streaming rebuild.

## Mission overview

Make `Acervo.availability(slug)` tell the truth about whether a model is actually usable, then unify the local manifest format with the CDN manifest so the validity oracle has a single source of truth on disk.

Today the library uses a presence-only validity check (`config.json` exists ⇒ valid). The 2026-05-20 audit of `~/Library/Group Containers/group.intrusive-memory.models/SharedModels` confirmed this check is wrong **in both directions**:

- **False positive**: `mlx-community/Qwen3-Coder-Next-4bit` has `config.json` + `model.safetensors.index.json` declaring 9 shards totalling 44.8 GB. Zero shards on disk. Today's rule reports the model as `.available`. Consumers fail at load time.
- **False negative**: `black-forest-labs/FLUX.2-klein-4B` has no top-level `config.json` (diffusers pipelines use `model_index.json`). Today's rule reports a fully-downloaded 22 GB model as `.notAvailable`.

Additionally, eight stub directories from cancelled downloads are listed by `Acervo.localModels()` as candidates. And only 1 of 11 completed models has a `manifest.json` persisted locally — the path that writes it is inconsistent.

This mission also carries forward five sorties from the parked QUARTERMASTER iteration-02 plan that are tightly bound to the same artifact (the local `manifest.json`): DC-1/DC-2/DC-3 (deferred §1 cleanup — multi-component upload + Vinetas re-upload + test wrap removal) and CIH-1/CIH-2 (CI hygiene).

## 1. Manifest-driven validity oracle (the headline)

### 1.1 Why

False positives and false negatives on validity are both load-bearing for any consumer UI that surfaces "model downloaded / not downloaded". Three-state availability shipped in v0.14.0; the validity oracle that drives the three-state response is the load-bearing piece, and it's wrong.

### 1.2 Items

- [ ] **Persist `manifest.json` next to the model on download success.** ~1 KB per model. Today only happens for 1 model out of 11 on disk — code path is inconsistent. Fix `AcervoDownloader` (or wherever the post-download finalization lives) to always write it atomically (`tempfile + rename`) on the same code path as the final SHA-256 verify.

- [ ] **Replace presence-marker validity with manifest-driven validity** in `Acervo.availability(_:)` and any internal "is this model present" check. Algorithm:
  1. If a local `manifest.json` exists, verify every entry in `files` exists on disk at matching size. (Optional second pass: verify SHA-256, gated behind an explicit flag — expensive on 22 GB files.)
  2. If no local manifest, fall back to the CDN manifest (already in-memory cache from the slug-registry work shipping out of QUARTERMASTER 01's salvage merge).
  3. If no manifest is reachable, fall back to: `model_index.json` OR `config.json` present, **and** every file enumerated in `model.safetensors.index.json`'s `weight_map` values is on disk. This is a last-resort heuristic, not a primary rule.

- [ ] **Treat `model_index.json` as an equivalent root marker for diffusers pipelines.** Anywhere `config.json` is currently the only sentinel, accept either.

- [ ] **Extend `ModelAvailability` with `.partial(missing: [String])`** so consumers can distinguish "never downloaded" from "downloaded then a shard went missing". The existing enum already carries a `.downloading(progress:)` payload; `.partial(missing:)` is the same additive flavor. Open during refinement: confirm Vinetas / SwiftBruja consumers want this enum extension vs. a separate `ModelHealth` type. Recommendation: extend.

- [ ] **Housekeeping pass on `Acervo.localModels()`** that filters or prunes empty model directories (8 currently present on audit machine). Default: filter at listing time (cheap, non-destructive). Expose `Acervo.gcEmptyModelDirectories()` for callers that want explicit pruning.

### 1.3 Acceptance

1. `await Acervo.availability("mlx-community/Qwen3-Coder-Next-4bit")` returns `.partial(missing: [<the 9 shard filenames>])` on the audited disk state, **not** `.available`.
2. `await Acervo.availability("black-forest-labs/FLUX.2-klein-4B")` returns `.available` on the audited disk state — without requiring `config.json` at the root.
3. After a successful `Acervo.ensureAvailable(...)` of any model, `<model-dir>/manifest.json` exists and is byte-equal to the CDN manifest.
4. `await Acervo.localModels()` does not include the eight empty directories on the audit machine.
5. `make build` + `make test` green; new tests on `SwiftAcervo-macOS.xctestplan` covering: false-positive case (Qwen3-Coder-Next-shaped fixture), false-negative case (FLUX.2-shaped fixture), `model_index.json` equivalence, `.partial` enum emission, `localModels()` filtering. All tests use in-memory or tempdir fixtures — no live disk dependency.

### 1.4 Out of scope

- Detecting *bit-rot* (file on disk matches size but SHA differs). The "verify SHA-256" pass mentioned in §1.2 is opt-in; making it automatic is a follow-up.
- Re-downloading missing shards automatically when `.partial` is detected. The detection is the deliverable; remediation is the consumer's call.

## 2. Local-manifest schema unification (load-bearing for §1)

The §1 manifest schema (from the slug-registry work) and the §1.2 on-disk `manifest.json` are **the same artifact**. The local manifest is a byte-equal copy of the CDN manifest the model came from, written next to the model on download finalization. This mission must say so explicitly in code and tests — not as a coincidence-by-design, but as a documented invariant.

Specifically:

- [ ] The manifest type's serialization format used for the local `manifest.json` MUST be the same Codable shape used to decode the CDN manifest. Round-tripping the local file through the existing manifest decoder is the test invariant.
- [ ] **Nested paths in `files[].path`** are explicitly permitted (already added to the mission-branch REQUIREMENTS.md). Diffusers pipeline repos like FLUX.2-klein-4B carry subfolders (`transformer/`, `vae/`, `text_encoder/`, `tokenizer/`, `scheduler/`) inside one HF repo. `path` is a relative POSIX path; subdirectories of any depth are allowed. Consumers must `mkdir -p` along the path before writing.
- [ ] The `acervo ship` manifest generator must recurse into subdirectories of the staged repo, excluding HuggingFace cruft (`.cache/`, `.gitattributes`, `.gitignore`, `.DS_Store`, `*.lock`, `*.metadata`). (This dovetails with DC-1 below.)

## 3. Carry-overs from parked iteration-02 plan

Five sorties from `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` carry forward verbatim into this mission. Their detailed task lists and exit criteria are already refined in the parked plan; the execution-plan author for this mission should use them as starting templates and re-validate before dispatch.

### DC-1 — Extend `acervo ship --spec` live mode to iterate components

Today `--spec` works only with `--dry-run`. Live mode (`--spec` without `--dry-run`) goes through `runHuggingFaceDownload` which only handles a single `modelId` — there is no per-component loop. So `acervo ship --spec spec.json` (live) does not actually upload multi-component manifests.

**Scope**: Extend `runHuggingFaceDownload` to iterate `spec.components`. Reuse the existing dry-run test pattern at `Tests/AcervoToolTests/ShipDryRunTests.swift:148+`. Parked-plan task list: `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` Sortie DC-1.

**Why in this mission**: Blocking for DC-2.

### DC-2 — Live CDN re-upload of three Vinetas manifests

Re-upload `pixart-sigma-xl`, `flux2-klein-4b`, `flux2-klein-9b` so their CDN manifests carry `modelId` + `primaryRepo` + `components` (the slug-registry schema fields) **and** the nested-path file enumeration (the §2 unification). Specs are **resolved** (see parked plan's Q-NU-1 / Q-NU-2 / Q10):

```jsonc
// pixart-sigma-xl
{
  "modelId": "pixart-sigma-xl",
  "primaryRepo": "PixArt-alpha/PixArt-Sigma-XL-2-1024-MS",
  "components": ["PixArt-alpha/PixArt-Sigma-XL-2-1024-MS"]
}
// flux2-klein-4b
{
  "modelId": "flux2-klein-4b",
  "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
  "components": ["black-forest-labs/FLUX.2-klein-4B"]
}
// flux2-klein-9b
{
  "modelId": "flux2-klein-9b",
  "primaryRepo": "black-forest-labs/FLUX.2-klein-9B",
  "components": ["black-forest-labs/FLUX.2-klein-9B"]
}
```

All three are single-repo-with-subfolders, not multi-repo. The legacy three int4-quantized CDN repos for pixart (`t5-xxl-encoder-int4`, `sdxl-vae-decoder-fp16`, `pixart-sigma-xl-dit-int4`) are deprecated and being retired — see parked plan's "Out-of-scope / follow-up" section.

**Scope**: Live operator-tended sortie. Run `acervo ship --spec <slug-spec.json>` against the live R2 for each. Verify post-upload that the CDN manifest decodes with the new fields populated and the nested paths enumerated. Parked-plan task list: `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` Sortie DC-2.

**Why in this mission**: Without live manifests carrying the new schema, §1's local-manifest write produces files that look like an unreleased format from the CDN's perspective. The §1 acceptance tests can use synthetic manifests, but production users of `Acervo.availability("pixart-sigma-xl")` need real CDN data.

### DC-3 — Remove `withKnownIssue` wraps now that live manifests carry slug fields

QUARTERMASTER 01's S1 wrapped `AcervoToolTests/CDNManifestFetchTests` in `withKnownIssue` because the live R2 manifests pre-S6 did not carry `modelId`/`primaryRepo`/`components`. After DC-2 ships, those wraps become misleading — the tests will start passing for real, and the `withKnownIssue` wraps will report a `KnownIssue` not-failing-as-expected diagnostic.

**Scope**: Remove the `withKnownIssue` wraps. Confirm the tests pass against live R2 (or against a fixture that mirrors live R2's post-DC-2 state). Clean up the two SourceKit warnings about useless `try` inside the removed closures.

**Why in this mission**: Hygiene; depends on DC-2.

### CIH-1 — Audit test-plan placement

Walk every test class in `Tests/SwiftAcervoTests/` and `Tests/AcervoToolTests/`. Confirm each is on the appropriate test plan (`SwiftAcervo-macOS.xctestplan`, `SwiftAcervo-iOS.xctestplan`, or `SwiftAcervo-Performance.xctestplan`). Flag anything that's a deterministic correctness test landed on the perf plan (the QUARTERMASTER 01 brief's planner-wrong #1 — Test F was wrongly perf-gated).

**Scope**: Read-only audit. Output is a report; no test-plan modifications in this sortie. Parked-plan task list: `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` Sortie CIH-1.

**Why in this mission**: Independent CI hygiene. Cheap, valuable.

### CIH-2 — CI workflow + Makefile + shape gate

Apply CIH-1's findings. Update `make test` / `make test-perf` Makefile targets to explicitly name their test plans (no implicit defaults that drift). Add a shape gate (via `jq` against the `.xctestplan` JSON) that asserts no test class except `StreamingPerformanceTests` is in `skippedTests` on the CI plans.

**Scope**: Mechanical. Parked-plan task list: `Docs/parked/quartermaster-torrent-02/EXECUTION_PLAN.md` Sortie CIH-2.

**Why in this mission**: Closes the loop on CIH-1's audit. Together CIH-* prevents the next planner from making the QUARTERMASTER 01 §2-classification mistake.

## 4. Process controls (carried forward from prior briefs)

These are non-negotiable framework controls. Each is anchored in a specific prior-iteration failure.

### F1. Pre-dispatch working-tree audit
Before any sortie dispatch, the supervisor verifies `git status --porcelain` is consistent with the mission branch only, current branch is the mission branch, and HEAD descends from `development`. Halts and reports otherwise. **Source**: VAULT BROOM 02 half-applied rebase contamination.

### F2. State-write-before-completion invariant
Every sortie's exit criteria include "Update `SUPERVISOR_STATE.md` with this sortie's commit SHA and `COMPLETED` status." The state file is updated in the same agent dispatch as the work, not by reconciliation. **Source**: VAULT BROOM 02 WU2.S1 "observed state wins" reconciliation.

### F3. Build-and-test gate at every sortie HEAD
Every sortie's exit criteria include `make build` exit 0 and `make test` exit 0 at the final HEAD. **Source**: standard.

### F4. No silent deferrals
A sortie that cannot complete this iteration is marked `CANCELED-WITH-HANDOFF` and must name a successor mission with a stub REQUIREMENTS file. **Source**: VAULT BROOM 02's silent deferral of WU2.S3/WU3/WU4 that shipped via out-of-band PRs.

### F5. No out-of-band shipping during mission window
The supervisor monitors `git log development ^HEAD --oneline` periodically. New commits to `development` from other branches touching scoped files trigger halt-and-rebase. **Source**: VAULT BROOM 02 drift via feature PRs.

### F6. Mission closeout requires brief + clean state file
Brief is required at `Docs/incomplete/eighth-master-01/BRIEF.md` covering Sections 1-6 from the QUARTERMASTER 01 brief template before `/organize-agent-docs` promotes the mission to `Docs/complete/`. **Source**: VAULT BROOM 02 supervisor-state orphaning.

### F7 (NEW). "STOP if you find a production bug" clause for test-authoring sorties
Test-authoring sortie prompts must include: *"If the test you're writing surfaces a real production bug, your job is to STOP and report PARTIAL with the bug location and a recommended fix. Do not modify the test to make the bug invisible."* The supervisor's dispatch template must inject this clause when the sortie's primary deliverable is a test. **Source**: QUARTERMASTER 01 chunked-streaming/S2 — agent diagnosed the parallel-range bug correctly but neutered Test F instead of fixing the code. This is the single biggest process failure surfaced this year and warrants its own framework control.

### F8 (NEW). API-symbol verification at planning time
Plans that name specific Foundation / standard-library symbols (`URLSessionConfiguration.assumesHTTP3Capable`, etc.) must verify they exist (grep / Apple docs check) during refinement. The supervisor's `refine` pass should auto-flag named symbols that don't appear in the SDK. **Source**: QUARTERMASTER 01 chunked-streaming/S1 — plan specified a non-existent property, agent had to deviate and document.

## 5. Out of scope

- **Chunked-streaming-rebuild (CSR-1..CSR-5)**: parked indefinitely at `Docs/parked/quartermaster-torrent-02/`. Will revive in a separate future mission after this one ships. Do not revive verbatim.
- **HasherCoordinator sparse-file fix**: belongs to the future chunked-streaming-rebuild mission, not this one. This mission ships with the PARTIAL_SALVAGE merge having reverted that code; no parallel-range path exists in production until the next chunked-streaming mission rebuilds it.
- **SwiftVinetas D2 cleanup**: cross-package (in `../Vinetas/`); not this mission's repo.
- **PR #35 follow-up** (cache-bypass on `publishModel` post-upload readback): different mission scope; tracked in `Docs/PR35_CODE_REVIEW.md`.
- **SwiftAcervo telemetry/instrumentation**: tracked in `Docs/REQUIREMENTS-instrumentation.md`; P3 priority, separate mission.
- **AsyncStream<ModelAvailability> push subscription**: out of scope per the predecessor mission. Vinetas can poll.

## 6. Open questions for refinement

These need answers before the execution plan can be written:

1. **`ModelAvailability` extension vs. sibling `ModelHealth` type?** Confirm with Vinetas / SwiftBruja maintainers. Recommendation: extend the existing enum.
2. **SHA-256 verification as default or opt-in?** §1.2 says opt-in (expensive on 22 GB files). Confirm this matches what consumers want; if SwiftBruja's load-time check is already doing SHA-256, the library could skip the optional pass entirely.
3. **`localModels()` filter vs. prune default?** §1.2 defaults to filter. Operator-flag pruning. Confirm.
4. **Should DC-3 run on a fresh branch or in the same eighth-master mission branch?** DC-2 is operator-tended (live R2 ops). If DC-2 takes hours of human attention, decoupling DC-3 onto a follow-up branch may be cleaner.
5. **CI hygiene scope creep**: CIH-1's audit might surface more findings than CIH-2 can absorb. Pre-agreement: CIH-1 produces a report; if scope exceeds CIH-2, file follow-ups, don't grow CIH-2.

## 7. Definition of done

This mission is COMPLETE when:

- Every item in §1.3 acceptance is verified by an automated test on `SwiftAcervo-macOS.xctestplan`.
- §2 local-manifest format invariant is documented in code AND tested via round-trip.
- DC-1 + DC-2 + DC-3 + CIH-1 + CIH-2 are marked `COMPLETED` in the supervisor state file with commit SHAs.
- F1-F8 framework controls have been honored throughout (no silent deferrals, no orphan state file, no `KnownIssue`-not-failing diagnostics post-DC-3).
- A brief at `Docs/incomplete/eighth-master-01/BRIEF.md` records the closeout per the QUARTERMASTER 01 template structure.
