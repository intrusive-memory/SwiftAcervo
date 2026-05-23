---
mission: OPERATION QUARTERMASTER TORRENT
iteration: 1
state: closed
verdict: PARTIAL_SALVAGE
closed_on: 2026-05-21
---

# OPERATION QUARTERMASTER TORRENT — iteration 1 (closed)

This directory archives iteration 1 of OPERATION QUARTERMASTER TORRENT. The mission completed all 7 planned sorties but ended with a `PARTIAL_SALVAGE` verdict because the parallel-range download path shipped a real correctness bug that an inverted test masked instead of catching.

## Files

- [`BRIEF.md`](BRIEF.md) — Authoritative closeout. Sections cover hard discoveries (including the `HasherCoordinator` sparse-file zero-fill bug), what the agents did right and wrong, planner mistakes, sortie accuracy, salvage inventory, and the recommended PARTIAL_SALVAGE actions.
- [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) — The original 7-sortie plan as it stood when the mission started. Preserved verbatim; see BRIEF.md §6 + §8 for what should ship to `development` vs. what should be reverted.
- [`SUPERVISOR_STATE.md`](SUPERVISOR_STATE.md) — Tombstone summary of final sortie state. Brief is authoritative for the narrative; this is a quick-lookup table.

## Status at a glance

- **Mission branch**: `mission/quartermaster-torrent/01` (not merged; needs PARTIAL_SALVAGE surgery before merge)
- **Final commit**: `460f580`
- **slug-registry work unit (5 sorties)**: complete, correct, ready to ship
- **chunked-streaming work unit (2 sorties)**: single-request delegate path ready to ship; parallel-range path bug-bearing and should be reverted before merge

## Merge path (to land iteration 1's value on `development`)

The brief specifies the surgery in §6 and §8. Summary:

1. Branch from `development`:
   ```
   git checkout -b quartermaster-salvage development
   ```
2. Cherry-pick the 5 slug-registry merge commits in order:
   ```
   git cherry-pick 6c814a8 81614a0 7d0f8d5 305bbf2 bc7e89d
   ```
3. Cherry-pick chunked-streaming/S1 (`f6e4959`), then on the resulting commit revert:
   - `PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, `runRangeSubTask`
   - The `parallelRangeThreshold`/`parallelRangeCount` constants' usage (keep the named constants but they'll have no callers)
   - Keep: `streamFlushSize`, the delegate rewrite, HTTP/3 per-request capability, redirect-rejection and resume CI tests
4. Cherry-pick chunked-streaming/S2 (`460f580`), then revert:
   - `Tests/SwiftAcervoTests/StreamingPerformanceTests.swift` (delete the file)
   - The perf-plan `.xctestplan` file
   - Keep: `Tests/SwiftAcervoTests/StreamingChunkingTests.swift` (Tests B/C/D/E), `Docs/BUILD_AND_TEST.md` additions, `make test-perf` Makefile target (will be a no-op until rehydrated by a future chunked-streaming mission)
5. Also cherry-pick the doc updates that aren't in any sortie commit:
   - `1145398` (`docs: codify "HF is source of truth" + manifest-driven validity`) — pure CLAUDE.md update, safe to bring forward
   - `a12ed10` (`docs(mission): archive OPERATION QUARTERMASTER TORRENT iteration 01`) — partial: the brief itself ships in this commit; this archive directory supersedes its destination
6. Run `make build && make test`; expect green on the macOS plan.
7. Push the salvage branch and open a PR to `development`.

## What lives elsewhere

| Topic | Location | Why |
|---|---|---|
| Chunked-streaming-rebuild plan (CSR-1..CSR-5) | `Docs/parked/quartermaster-torrent-02/` | Parked indefinitely. Revive when re-tackling the parallel-range fix; do not revive verbatim — the hashing design will have aged. |
| Validity oracle work (§3) | `Docs/incomplete/eighth-master-01/REQUIREMENTS.md` | The next active mission. Headline: manifest-driven `Acervo.availability()` so `Qwen3-Coder-Next-4bit` doesn't falsely report available and `FLUX.2-klein-4B` doesn't falsely report unavailable. |
| Carry-overs from this mission's deferred items (DC-1..DC-3 + CIH-1..CIH-2) | `Docs/incomplete/eighth-master-01/REQUIREMENTS.md` | Bound to §3 (the local `manifest.json` they ship is the artifact §3's oracle reads). |
