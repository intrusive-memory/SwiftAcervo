---
type: doc
---

# SwiftAcervo — Model Integrity & Dependency-Aware Availability Requirements

**Status:** Draft, awaiting review
**Priority:** P1 — a model can be reported ready while incomplete/corrupt, causing generation to fail deep in a downstream loader
**Host:** Vinetas (FLUX.2 + PixArt image generation)
**Scope:** This is **Ticket A** of three (see §7). Tackle first.

---

## 1. Why

A model can be reported `.available` when it is not actually usable. Two real failures were observed:

1. **Missing dependency model.** FLUX.2 Klein 4B requires a separate text-encoder model (Qwen3-4B). The app reported FLUX `.available` with the text encoder **absent**; generation only discovered it at load time (downloaded it mid-generate, then failed anyway in the transformer loader).
2. **Interrupted / multi-folder download.** A diffusers-layout model (weights under `transformer/`, `text_encoder/`, `vae/` subdirs, each with its own `model.safetensors.index.json`) can satisfy the heuristic availability check on a **root marker alone** (`model_index.json`), without confirming the subdir shards exist.

The requirement: **assume a possibly-corrupted or incomplete download** and confirm fidelity to *all* required model data — **including dependency/companion models** — before a model is treated as ready.

Most of the machinery to do this **already exists** (see §4). The work is wiring + hardening, not new infrastructure.

---

## 2. Current behavior (defects)

- **D1 — Dependency list incomplete.** `SwiftVinetas/.../Engine/Flux2Engine.swift` `modelComponents(for:)` returns only `[.transformer(variant), .vae(.standard)]`. The text encoder is never enumerated, so `availability(_:)` (which aggregates via `AvailabilityAggregation.aggregate`) cannot see a missing text encoder. PixArt's `componentIds` (t5-xxl, pixart-dit, sdxl-vae) is complete by comparison.
- **D2 — Heuristic false positive.** `SwiftAcervo/Sources/SwiftAcervo/ValidityOracle.swift` `heuristicVerdict(modelDir:)` returns `.available` when a root marker (`model_index.json`/`config.json`) exists and there is **no root** `model.safetensors.index.json` — exactly the diffusers/multi-folder layout. It never descends into the component subdirs to confirm their shards.
- **D3 — Full-hash audit never invoked.** `ValidityOracle.evaluate(…verifyHashes: true)`, `IntegrityVerification.verifyAgainstManifest`, and the CLI `VerifyCommand` all perform real sha256 verification, but nothing in the app flow calls them at decisive moments. Availability defaults to `verifyHashes: false` (size+existence only).

---

## 3. Requirements (chosen approach: *gated full-hash*)

- **R1.** Launch and picker availability stays **fast** (size + existence). No multi-GB hashing on every "is it ready?" query.
- **R2.** A **full sha256 audit** runs at decisive moments only:
  - **R2.1** automatically right after a download completes (hashes already validated inline during streaming — write the marker);
  - **R2.2** lazily **before first generation** if no valid verified-marker exists for any required component;
  - **R2.3** on an explicit **Verify** action (GUI button / CLI).
- **R3.** A **verified marker** (e.g. `.acervo-verified.json` = `{ manifestChecksum, verifiedAt }`) is written on a passing full audit and lets later availability checks skip re-hashing while the local manifest checksum is unchanged.
- **R4.** Availability is **dependency-aware**: a model is `.available` only if **every** required component **and companion/dependency model** is present and intact; a missing/incomplete dependency yields `.partial(missing:)`, never `.available`.
- **R5.** The heuristic tier must **never** return `.available` when it cannot positively confirm completeness; ambiguous → `.indeterminate` (→ `.notAvailable`).
- **R6.** When generation is requested on a model that fails the audit, surface a clear **"model incomplete — re-download"** up front, not a deep loader error.

---

## 4. Design — reuse existing infrastructure (do NOT rebuild)

| Need | Reuse |
|---|---|
| Streaming sha256 | `IntegrityVerification.sha256(of:)` |
| Per-file post-download verify (size + sha, deletes on fail) | `IntegrityVerification.verifyAgainstManifest(...)` |
| Fast size/existence | `IntegrityVerification.fileMatchesManifestEntry` / `allManifestFilesPresentBySize` |
| 3-tier oracle w/ optional hashing | `ValidityOracle.evaluate(modelId:in:verifyHashes:)` |
| Public availability surface | `Acervo.availability(_:verifyHashes:)`, `isModelAvailable` |
| Authoritative file list (path, sha256, sizeBytes, manifestChecksum) | `CDNManifest` / `CDNManifestFile` |
| Full-hash audit logic (local + CDN modes) | `Sources/CLI/VerifyCommand.swift` |
| Multi-component aggregation | `AvailabilityAggregation.aggregate` (SwiftVinetas) |

**Changes:**

- **C1 (SwiftVinetas, D1):** add `.textEncoder(variant)` to `Flux2Engine.modelComponents(for:)`; confirm the text-encoder `variant.repoId` resolves to the Qwen3-4B model and that it is Acervo-provisioned with a manifest. Add a PixArt regression test asserting all three components are listed.
- **C2 (SwiftAcervo, D2/R5):** harden `heuristicVerdict` — for `model_index.json` (diffusers) models, recurse into component subdirs and require every shard each subdir's `model.safetensors.index.json` enumerates; otherwise return `.indeterminate`. Reuse `parseWeightMapShards(at:)`.
- **C3 (SwiftAcervo, R2/R3):** add `Acervo.verifyIntegrity(_ modelId:) async -> ModelAvailability` (calls `evaluate(verifyHashes: true)`; writes the verified marker on success). Make `availability`/`isModelAvailable` honor the marker as a fast-path.
- **C4 (wiring, R2.1/R2.2/R6):** write the marker on download completion in `AcervoDownloader`; in the engine `loadModels` path, run `verifyIntegrity` when a component lacks a valid marker and fail fast with a clear message on `.partial`.

---

## 5. Open risk (resolve before/within implementation)

Is the FLUX.2 Klein **text encoder (Qwen3-4B)** an Acervo-managed component (own CDN manifest), or downloaded ad-hoc by `Flux2Pipeline.loadModels`? If ad-hoc, C1/C4 must bring it under Acervo component management (or the audit must explicitly cover a non-Acervo-managed dependency). This decides whether Ticket A is SwiftAcervo-only or also touches the FLUX pipeline. **Confirm first.**

---

## 6. Verification

- **SwiftAcervo unit** (`Tests/SwiftAcervoTests/EM2ValidityOracleTests.swift`, `AvailabilityThreeStateTests.swift`): diffusers model missing a `transformer/` shard → `.partial`; verified-marker fast-path trusts a matching `manifestChecksum` and re-audits on mismatch; `verifyIntegrity` surfaces a hash mismatch as `.partial`.
- **SwiftVinetas unit:** `Flux2Engine.availability` returns `.partial` when the text-encoder repo is absent.
- **End-to-end:** clear Vinetas models → download FLUX via app → kill mid-download → relaunch shows *incomplete* (not "available"); complete download → marker written → VinetasCLI FLUX.2 generation yields a recognizable image (`make build-mac` + `vinetas-cli` skill).
- `make test` green in both repos before release.

---

## 7. Related tickets (separate)

- **B (SwiftAcervo):** download concurrency under-utilizes the connection pool — `maxConcurrentDownloads = 4` vs `httpMaximumConnectionsPerHost = 6`; no explicit HTTP/2 config; sha re-seed on resume. Measure with `SwiftAcervo-Performance` / `StreamingPerformanceTests`.
- **C (flux-2-swift-mlx):** `Sources/Flux2Core/Loading/WeightLoader.swift` errors `No safetensors files found in: <repo root>` despite valid shards + index under `transformer/`. Blocks all FLUX.2 generation; likely interacts with the safetensors reshard layout.
