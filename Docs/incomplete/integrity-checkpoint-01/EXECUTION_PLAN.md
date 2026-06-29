---
type: execution-plan
state: incomplete
feature_name: OPERATION INTEGRITY CHECKPOINT
starting_point_commit: 5aae72d939e37fb9f2e853fb38ea529aaee0ddcc
mission_branch: mission/integrity-checkpoint/01
iteration: 1
---

# EXECUTION_PLAN.md — Model Integrity & Dependency-Aware Availability (Ticket A)

Derived from `Docs/REQUIREMENTS-model-integrity.md`. Mission spans two repositories:
SwiftAcervo (`/Users/stovak/Projects/SwiftAcervo`) and SwiftVinetas
(`/Users/stovak/Projects/SwiftVinetas`).

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

A model can be reported `.available` while incomplete or corrupt. Two real failures
drive this work: (1) FLUX.2 Klein's text-encoder dependency is never enumerated, so a
missing text encoder slips past availability; (2) the heuristic oracle returns
`.available` for a diffusers/multi-folder layout on a root marker alone, without
confirming the per-subdir shards. The fix is **gated full-hash**: keep launch/picker
availability fast (size + existence), run a real sha256 audit only at decisive moments,
persist a verified marker, and make availability dependency-aware. Per §4 of the
requirements, the machinery already exists — this is **wiring + hardening, not new
infrastructure**.

---

## Refinement Status

| Pass | Status | Outcome |
|------|--------|---------|
| 1. Blocking Open Questions | ✓ PASS | OQ-1 resolved (CDN-verified, see Decisions Log) |
| 2. Atomicity & Testability | ✓ PASS | 0 splits, 0 merges; criteria sharpened |
| 3. Prioritization | ✓ PASS | Priority scores + recommended dispatch order added |
| 4. Parallelism | ✓ PASS | 1 parallel pair (A2 ∥ A1); rest serial (see Parallelism Structure) |
| 5. Vague Criteria | ✓ PASS | 3 observational criteria made machine-verifiable |

**VERDICT**: ✓ Plan is ready to execute. Next step: `/mission-supervisor start Docs/EXECUTION_PLAN.md`

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| WU-A SwiftAcervo (oracle + marker + download wiring) | `/Users/stovak/Projects/SwiftAcervo` | 3 | 1 | none |
| WU-B SwiftVinetas (dependency-aware engine + fail-fast + E2E) | `/Users/stovak/Projects/SwiftVinetas` | 3 | 2 | WU-A (`Acervo.verifyIntegrity` API, verified marker) |

---

## Recommended Dispatch Order

Sortie IDs (A1–A3, B1–B3) are **stable dependency keys** referenced throughout the plan
and are intentionally not renumbered. Execution order is governed by priority + hard
dependency constraints:

1. **A2** (priority 14 — foundation) ‖ **A1** (priority 5.75) — Layer 1, run as a parallel pair (disjoint files)
2. **A3** (priority 5.5) — after A2
3. *(WU-A build/test gate green → WU-B can build against the sibling checkout)*
4. **B1** (priority 10.75) — Layer 2 entry
5. **B2** (priority 5.75) — after B1
6. **B3** (priority 4.5) — acceptance, after all

---

## Work Unit A — SwiftAcervo

### Sortie A1: Harden heuristic verdict for diffusers / multi-folder layout (C2 · D2 · R5)

**Priority**: 5.75 — file-I/O risk (2); blocks only B3 (depth 1); not a shared-type foundation. Run in parallel with A2 (disjoint file).

**Entry criteria**:
- [ ] Layer-1 sortie — no prerequisites. Edits `Sources/SwiftAcervo/ValidityOracle.swift` only (disjoint from A2).

**Tasks**:
1. In `Sources/SwiftAcervo/ValidityOracle.swift` `heuristicVerdict(modelDir:)` (lines 246–281), detect the diffusers layout: `model_index.json` present **and** no root `model.safetensors.index.json`.
2. For that layout, enumerate component subdirs (`transformer/`, `text_encoder/`, `vae/`, etc.) that carry their own `model.safetensors.index.json`; reuse `parseWeightMapShards(at:)` (lines 293–308) to list each subdir's shards and require every shard file exists on disk.
3. Return `.indeterminate` whenever completeness cannot be positively confirmed (a subdir index is missing/empty, or any enumerated shard is absent) — never `.available` (R5). `.indeterminate` maps to `.notAvailable` downstream.
4. Preserve existing behavior for non-diffusers models (single `config.json`, or a root `model.safetensors.index.json`).
5. Add/extend `Tests/SwiftAcervoTests/EM2ValidityOracleTests.swift` and `AvailabilityThreeStateTests.swift`: a diffusers fixture missing a `transformer/` shard resolves to `.partial` (via availability) / heuristic `.indeterminate`.

**Exit criteria**:
- [ ] `heuristicVerdict` returns `.indeterminate` (not `.available`) for a diffusers fixture whose `transformer/` shard is absent.
- [ ] A non-diffusers fixture (single `config.json`, no shard index) still returns `.available` (no regression).
- [ ] New/updated tests in `EM2ValidityOracleTests.swift` + `AvailabilityThreeStateTests.swift` covering the missing-subdir-shard case pass.
- [ ] `make test` (SwiftAcervo, `SwiftAcervo-macOS` test plan) is green.

### Sortie A2: Verified-marker integrity model + `Acervo.verifyIntegrity` + availability fast-path (C3 · R2 · R3)

**Priority**: 14 — **foundation** (defines the verified-marker model + `verifyIntegrity` API reused by A3, B2, B3); highest dependency depth (3); new-feature risk (2). Dispatch first.

**Entry criteria**:
- [ ] Layer-1 sortie — independent of A1. Edits `Sources/SwiftAcervo/Acervo+Availability.swift` and adds a new marker-model file (disjoint from A1's `ValidityOracle.swift`).

**Tasks**:
1. Define a `Codable, Sendable` verified-marker model serialized to `.acervo-verified.json` = `{ manifestChecksum, verifiedAt }`, with read/write helpers that place it in the model's local directory.
2. Add `public static func verifyIntegrity(_ modelId: String) async -> ModelAvailability` to the Acervo public surface (`Sources/SwiftAcervo/Acervo+Availability.swift`); it calls `ValidityOracle.evaluate(modelId:in:verifyHashes: true)` and, on a passing full-hash audit, writes the marker stamped with the current local `manifestChecksum`.
3. Make `availability(_:verifyHashes:)` (lines 235–244) and `isModelAvailable(_:)` (lines 61–63) honor a valid marker as a fast-path: trust the model when the stored `manifestChecksum` matches the local manifest; re-audit when it does not match (or no marker exists).
4. Add tests: matching-checksum marker skips re-hashing; mismatched-checksum marker forces re-audit; `verifyIntegrity` surfaces a deliberately corrupted file as `.partial`.

**Exit criteria**:
- [ ] `Acervo.verifyIntegrity(_:)` exists, returns `ModelAvailability`, and writes `.acervo-verified.json` (with `manifestChecksum` + `verifiedAt`) on a passing full-hash audit.
- [ ] Test: a marker whose `manifestChecksum` matches the local manifest causes availability to skip re-hashing (assert via a hash-invocation spy/counter or an injected oracle that records whether the full-hash path was entered — not by timing).
- [ ] Test: a mismatched marker triggers a re-audit (same spy/counter shows the full-hash path was entered).
- [ ] Test: `verifyIntegrity` on a model with a hash-mismatched file returns `.partial`.
- [ ] `make test` (SwiftAcervo) is green.

### Sortie A3: Write verified marker on download completion (C4 · R2.1)

**Priority**: 5.5 — depends on A2's marker writer (depth 1); file-I/O risk (2); not a foundation.

**Entry criteria**:
- [ ] A2 exit criteria met (verified-marker writer + `manifestChecksum` plumbing exist).

**Tasks**:
1. In `Sources/SwiftAcervo/AcervoDownloader.swift`, after the inline streaming sha256 + `verifyAgainstManifest` succeeds for a completed model, write the verified marker (R2.1) — bytes were already hash-validated during streaming, so no re-hash is needed.
2. Stamp the marker with the just-downloaded local `manifestChecksum`.
3. Add a test: after a simulated successful download, `.acervo-verified.json` is present with the expected `manifestChecksum`.

**Exit criteria**:
- [ ] After a successful download in a test, `.acervo-verified.json` exists with a `manifestChecksum` matching the downloaded manifest.
- [ ] A subsequent `availability` call on the freshly-downloaded model takes the marker fast-path — asserted via the A2 hash-invocation spy/counter showing the full-hash path was **not** entered.
- [ ] `make test` (SwiftAcervo) is green.

---

## Work Unit B — SwiftVinetas

### Sortie B1: Dependency-aware FLUX components — enumerate the text encoder (C1 · D1 · R4)

**Priority**: 10.75 — establishes the `.textEncoder` component (foundation for B2/B3); dependency depth 2; mapping/regression risk (2).

**OQ-1 resolution (applied)**: The Klein text encoders are Acervo-managed and **already present + complete on the CDN** (verified — see Decisions Log). Mapping is concrete:
- `klein4B` → `lmstudio-community/Qwen3-4B-MLX-8bit`  (CDN slug `lmstudio-community_Qwen3-4B-MLX-8bit`)
- `klein9B` → `lmstudio-community/Qwen3-8B-MLX-8bit`  (CDN slug `lmstudio-community_Qwen3-8B-MLX-8bit`)

No CDN provisioning is required. No bespoke non-Acervo audit path — reuse `AvailabilityAggregation` + `verifyIntegrity` uniformly (R4 / §4 reuse-over-rebuild).

**⚠ Mistral trap (do not regress)**: the upstream `flux-2-swift-mlx` `Flux2Core.ModelRegistry.TextEncoderVariant.huggingFaceRepo` returns **Mistral** repos (`mistralai/Mistral-Small-3.2-24B...`, `lmstudio-community/Mistral-Small-...`). That is the wrong source for the Klein text encoder. Map `.textEncoder` to the Qwen3-MLX-8bit ids above; **never** route through `TextEncoderVariant.huggingFaceRepo`.

**Entry criteria**:
- [ ] WU-A build/test gate green and available locally as a sibling checkout, so SwiftVinetas can build against the new Acervo surface (`Acervo.verifyIntegrity`, verified marker).

**Tasks**:
1. In `Sources/SwiftVinetas/Engine/Flux2Engine.swift` `modelComponents(for:)` (currently returns `[.transformer(variant), .vae(.standard)]`, ~lines 564–578), add `.textEncoder(variant)` for `klein4B` and `klein9B`.
2. Resolve the text-encoder component to its Acervo repo id per the mapping above. `acervoRepoId(for:)` already has `case .textEncoder(let variant): return variant.repoId` — ensure `variant.repoId` returns the Qwen3-MLX-8bit slug (`lmstudio-community/Qwen3-4B-MLX-8bit` for klein4B, `…/Qwen3-8B-MLX-8bit` for klein9B), **not** the upstream Mistral `huggingFaceRepo`. If `.textEncoder`'s variant currently binds to the Mistral `TextEncoderVariant`, introduce/point it at the Qwen3 mapping so SwiftVinetas owns the correct repo id.
3. Add a PixArt regression test asserting `PixArtEngine.componentIds` lists all three (`t5-xxl-encoder-int4`, `pixart-sigma-xl-dit-int4`, `sdxl-vae-decoder-fp16`).
4. Add a `Flux2Engine` test asserting `availability(_:)` returns `.partial(missing:)` (via `AvailabilityAggregation.aggregate`) when the text-encoder repo is absent.

**Exit criteria**:
- [ ] `Flux2Engine.modelComponents(for:)` includes `.textEncoder` for both `klein4B` and `klein9B`.
- [ ] `Flux2Engine.acervoRepoId(for: .textEncoder(klein4B))` == `"lmstudio-community/Qwen3-4B-MLX-8bit"` and for klein9B == `"lmstudio-community/Qwen3-8B-MLX-8bit"` (assert in a unit test; guards against the Mistral regression).
- [ ] SwiftVinetas test: `Flux2Engine.availability` returns `.partial` when the text-encoder repo is absent.
- [ ] PixArt regression test asserts all three `componentIds` are listed.
- [ ] `make test-unit` (SwiftVinetas, `-only-testing:SwiftVinetasTests`) is green.

### Sortie B2: Fail-fast generation guard via `verifyIntegrity` in the load path (C4 · R2.2 · R6)

**Priority**: 5.75 — depends on A2 + B1 (depth 1); user-facing-error risk (2); not a foundation.

**Entry criteria**:
- [ ] A2 complete (`Acervo.verifyIntegrity` available as a sibling dependency).
- [ ] B1 complete (text encoder is an enumerated component).

**Tasks**:
1. In the engine `loadModels` path, before any deep loader call, run `Acervo.verifyIntegrity` for each required component that lacks a valid verified marker (R2.2).
2. On a `.partial` result, fail fast with a clear, user-facing "model incomplete — re-download" error surfaced to the caller (R6) — not a deep loader error.
3. Add a test: `loadModels` against a `.partial` component throws/returns the incomplete-model error before reaching the loader.

**Exit criteria**:
- [ ] `loadModels` invokes `verifyIntegrity` when a required component has no valid marker.
- [ ] Test: a `.partial` component yields the "incomplete — re-download" error up front (assert the specific error type/case and message substring), not a transformer/loader error.
- [ ] `make test-unit` (SwiftVinetas) is green.

### Sortie B3: End-to-end FLUX integrity acceptance (§6)

**Priority**: 4.5 — terminal acceptance sortie (depth 0); high integration/E2E risk (3); high complexity (3). Supervising agent only (manual + full-build steps).

**Entry criteria**:
- [ ] A1, A2, A3, B1, B2 complete.

**Tasks**:
1. Clear Vinetas models, download FLUX via the app, kill the process mid-download, relaunch, and confirm the model reports *incomplete* (not "available").
2. Complete the download and confirm `.acervo-verified.json` is written for FLUX and its dependencies (including the Qwen3 text encoder).
3. Run VinetasCLI FLUX.2 generation via the `vinetas-cli` skill and confirm a recognizable, non-empty image is produced.
4. Run the full `make test` in both SwiftAcervo and SwiftVinetas.

**Exit criteria**:
- [ ] A model killed mid-download reports incomplete on relaunch: capture the post-relaunch availability state to a log artifact and assert it is `.partial`/`.notAvailable` (not `.available`) — log file path recorded in the sortie progress notes.
- [ ] A completed download writes `.acervo-verified.json` for the FLUX transformer, VAE, **and** the Qwen3 text-encoder dependency (assert each file exists).
- [ ] VinetasCLI FLUX.2 generation produces a PNG file with size > 0 bytes at a recorded output path.
- [ ] `make test` is green in both SwiftAcervo and SwiftVinetas.

---

## Parallelism Structure

**Critical Path**: A2 → (WU-A gate) → B1 → B2 → B3 (length: 4 sorties). A3 must also complete before B3 but is off the critical path.

**Parallel Execution Groups**:
- **Group 1** (Layer 1, can run in parallel):
  - A2 (Agent 1 — foundation) — **SUPERVISING AGENT ONLY** (build/test gate)
  - A1 (Agent 2) — disjoint file (`ValidityOracle.swift`); implementation parallelizable
- **Group 2** (Layer 1, sequential — depends on A2):
  - A3 — **SUPERVISING AGENT ONLY** (build/test gate)
- **Group 3** (Layer 2, strict chain — depends on the WU-A gate being green):
  - B1 → B2 → B3, each **SUPERVISING AGENT ONLY** (build/test gate)

**Agent Constraints**:
- **Supervising agent**: runs every sortie that ends in a `make test` / `make test-unit` gate (all six do).
- **Sub-agents (up to 4)**: may draft the *non-build* implementation/tests for the A1 ∥ A2 pair; the supervisor owns all builds and consolidated test runs.

**Parallelism metrics**:
- Maximum parallelism: **2** (A1 ∥ A2 implementation).
- Everything else is serialized by build gates and the WU-A → WU-B sibling-dependency layer boundary.

**Missed opportunities**: none material. WU-B is an intrinsic chain (B2⊃B1, B3⊃all), and WU-B cannot start until WU-A builds, so cross-work-unit parallelism is not available.

---

## Open Questions

_All blocking open questions resolved during refinement. See Decisions Log._

---

## Decisions Log

### OQ-1 — FLUX.2 Klein text encoder (Qwen3) Acervo management → **RESOLVED (accept recommendation)**

**Decision**: Bring the Qwen3 text encoders under Acervo component management (they already are) and map `.textEncoder` → the Qwen3-MLX-8bit Acervo ids. Reuse the existing `AvailabilityAggregation` + `verifyIntegrity` machinery; no bespoke non-Acervo audit path.

**Evidence (CDN-verified 2026-06-28, R2 bucket `intrusive-memory-audio`, prefix `models/`)**:
- `models/lmstudio-community_Qwen3-4B-MLX-8bit/` — present and complete: `config.json`, `manifest.json`, `model.safetensors` + `model.safetensors.index.json`, tokenizer set.
- `models/lmstudio-community_Qwen3-8B-MLX-8bit/` — present and complete: sharded `model-0000{1,2}-of-00002.safetensors` + index + `manifest.json` + `config.json` + tokenizer set.

**Consequences applied to the plan**:
- The OQ's conditional "if not on CDN, add provisioning to B1" does **not** fire — no provisioning task added.
- B1 carries an explicit Mistral-trap warning + a machine-verifiable `acervoRepoId` assertion (the upstream `TextEncoderVariant.huggingFaceRepo` returns Mistral repos — confirmed in `flux-2-swift-mlx/Sources/Flux2Core/Configuration/ModelRegistry.swift` lines 252–264).
- B1's former "OQ-1 resolved" entry-criterion is removed (now resolved).

**Source**: User decision ("qwen3 SHOULD be managed via acervo") + direct CDN verification.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 2 |
| Total sorties | 6 |
| Open questions | 0 (OQ-1 resolved) |
| Critical path | 4 sorties (A2 → B1 → B2 → B3) |
| Max parallelism | 2 (A1 ∥ A2) |
| Dependency structure | 2 layers (WU-A → WU-B) |
| Verdict | ✓ Ready to execute |
