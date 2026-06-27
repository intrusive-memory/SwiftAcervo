---
type: doc
title: "Handoff: wire safetensors re-sharding into the acervo command structure"
date: 2026-06-27
---

# Handoff: wire safetensors re-sharding into the `acervo` command structure

**Date:** 2026-06-27
**Repo:** `/Users/stovak/Projects/SwiftAcervo` (branch `development`, v0.21.0-dev)
**Next session focus:** Promote the validated standalone re-sharding prototype into the main `acervo` CLI so every CDN-published model is split into edge-cacheable shards automatically.

---

## TL;DR

A standalone Swift prototype that losslessly re-shards safetensors into ≤256 MiB CDN-edge-cacheable files **already exists and is proven on real models**. The job now is to lift it into `SwiftAcervo` as a reusable type and hook it into the `acervo ship` publish pipeline (re-shard the staging dir *after* download, *before* manifest generation).

---

## Decisions already made (do not re-litigate)

- **Shard cap: 256 MiB** — safe margin under Cloudflare's common 512 MB max-cacheable-object limit. Make it a configurable flag, default 256.
- **Integrity only, not signatures** — per-file SHA-256 + `manifestChecksum`, which Acervo's `ManifestGenerator` already produces. No new crypto.
- **Pure Foundation + CryptoKit** — re-sharding is a lossless byte copy; it never interprets dtypes (int4/fp16/bf16 pass through). **Do NOT pull in mlx-swift or any dependency.** This preserves Acervo's zero-dep rule.
- **Conversion/quantization stays in Python.** The `convert_pixart_weights.py` script the user pointed at does convert+int4-quantize and writes ONE file with no cap — it is NOT a sharder and is the wrong thing to port. Re-sharding is strictly simpler and separate.

---

## The prototype (reference implementation — read this first)

`/private/tmp/claude-501/-Users-stovak-Projects-SwiftAcervo/384b63fb-3260-404b-b60e-ed1f0c1d1df5/scratchpad/reshard.swift`

Compile/run:
```
swiftc -O reshard.swift -o reshard
./reshard <model-dir> <out-dir> [--cap-mib 256]
./reshard --selftest
```

Four pure functions to lift into the library verbatim (they carry the whole algorithm):
- `parseSafetensors(path:)` — reads the 8-byte LE header length + JSON header into `[TensorRef]` + `__metadata__`.
- `planShards(_:capBytes:)` — first-fit bucketing of tensors (sorted by name) under the cap; warns + isolates any single tensor > cap.
- `writeShard(_:metadata:to:sourceHandles:)` — rebuilds header with recomputed contiguous `data_offsets`, space-pads header to 8-byte alignment, streams raw bytes (4 MiB chunks, low memory).
- `verify(original:outDir:shardNames:)` — re-reads every output shard and SHA-256-compares each tensor against its source bytes to prove losslessness.

Also emits HF-standard `model.safetensors.index.json` (`weight_map` + `metadata.total_size`) and copies sibling files unchanged.

### Proven results (real models, on disk under `~/Library/Group Containers/group.intrusive-memory.models/SharedModels/` and `pixart-swift-mlx/converted/`)
- **PixArt DiT**: 329 MB single file / 1175 tensors → 2 shards (256.0 + 72.7 MiB), byte-identical.
- **T5-XXL**: already 5 shards up to **700 MB each** (the real bug — those never edge-cache) / 558 tensors / 2.8 GB → 12 shards all ≤256 MiB, byte-identical, tokenizer files copied. ~7s, streamed.

---

## Integration target — `acervo` CLI

CLI lives in `Sources/CLI/`. Relevant files:
- `Sources/CLI/AcervoCLI.swift` — `AsyncParsableCommand` root; subcommand list at line ~60.
- `Sources/CLI/ShipCommand.swift` — the `ship` flow. Options use `@Argument/@Option/@Flag` (swift-argument-parser). `run()` at line ~206 → `runLiveSingleComponent(...)` at ~261; multi-component via `--spec`. Staging dir defaults to `$STAGING_DIR/<slug>` or `/tmp/acervo-staging/<slug>`.
- `Sources/CLI/PublishRunner.swift` — orchestrates manifest-gen + CDN upload per component.
- `Sources/SwiftAcervo/ManifestGenerator.swift` — scans the staging dir, computes per-file SHA-256, writes `manifest.json`. Already skips `manifest.json`, `.DS_Store`, `.cache`, etc.

### Where to insert re-sharding
In the ship pipeline, after HF download populates the staging directory and **before** `ManifestGenerator` scans it. Sequence becomes:
```
download → RE-SHARD staging dir in place (≤cap) → ManifestGenerator.generate → PublishRunner upload
```
Because re-sharding changes file boundaries, the manifest must be generated *after* it (it already is — just make resharding a prior step on the same dir).

### Suggested shape
1. New `Sources/SwiftAcervo/SafetensorsResharder.swift` — port the four functions as a `SafetensorsResharder` (or `enum` with statics). Public API e.g. `static func reshard(directory: URL, maxShardBytes: Int) throws -> ResardReport`.
2. Add `--max-shard-mib <Int>` `@Option` to `ShipCommand` (default 256). Thread it into the publish path.
3. Call the resharder on the staging dir before `ManifestGenerator`. Gate: only when safetensors present; no-op when already under cap.
4. Add a unit test mirroring `--selftest` (synthetic multi-tensor safetensors → reshard small cap → assert byte-identical + index correctness). Use `make test` (XcodeBuildMCP / xcodebuild — NEVER `swift build`/`swift test`).

---

## Caveats to carry forward

1. **Tensor-granularity floor** — a single tensor > cap can't be split; it gets its own oversized shard + warning. Surface this in CLI output, don't silently exceed.
2. **Don't copy stale `manifest.json`** — the prototype copies all siblings incl. `manifest.json`; the real pipeline must regenerate it (ManifestGenerator already skips it on scan, so just don't carry the old one into the output set).
3. **Re-publish, not in-place patch** — new shard boundaries → new SHA-256s → consumers must pull the new manifest. Fine because the manifest is authoritative.
4. **`ValidityOracle` already parses `weight_map`** — output is compatible with existing on-disk validation. Confirm the index `total_size` semantics match what any consumer expects (prototype uses sum of tensor byte lengths, HF convention).

---

## Open questions for the user (ask before/while implementing)
- Should re-sharding be **always-on** in `ship`, or opt-in via the flag? (Recommendation: always-on with default 256, flag to override/disable.)
- Apply to **multi-component `--spec`** flows too (each component's staging dir)? (Likely yes.)
- Cap unit: confirm MiB (binary) vs MB (decimal) for the CDN limit framing.

---

## Suggested skills for the next session
- **`/toggle-sibling-libraries`** — if Package.swift needs dev-mode sibling deps while iterating locally.
- **`xcodebuildmcp`** — for building/testing the library (`make build` / `make test`); never `swift build`/`swift test`.
- **`/code-review`** (medium/high) — review the resharder + ShipCommand diff before PR.
- **`/create-pull-request`** — finalize the PR (base branch `development` per project convention).
- **`ship-swift-library`** — only when ready to cut a release after merge.

## Key references
- Library/CLI/UI usage docs: `Docs/USAGE-library.md`, `Docs/USAGE-cli.md`, `Docs/USAGE-ui-components.md`
- CDN contract: `Sources/SwiftAcervo/CDNManifest.swift`, `Docs/CDN_ARCHITECTURE.md`
- On-disk layout: `Docs/SHARED_MODELS_DIRECTORY.md`
- Project memory: `~/.claude/projects/-Users-stovak-Projects-SwiftAcervo/memory/MEMORY.md` (HF-is-source-of-truth; ship quirks; use `make test`)
