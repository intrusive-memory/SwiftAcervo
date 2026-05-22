---
mission: OPERATION QUARTERMASTER TORRENT
iteration: 2
state: parked
parked_on: 2026-05-20
parked_reason: Mission scope re-prioritized — chunked-streaming-rebuild deferred pending availability-correctness work.
revive_after: OPERATION EIGHTH-MASTER iteration 01 ships
revive_branch: TBD (new mission, name TBD via mission-supervisor name-feature)
---

# OPERATION QUARTERMASTER TORRENT — iteration 2 (PARKED)

This directory holds the **parked** iteration-02 execution plan. It is preserved verbatim for historical reference and as a starting point for the future mission that revives this work, but it is **not the active plan for any in-flight mission**.

## What's parked

The chunked-streaming-rebuild work units from the original iteration-02 plan:

- **CSR-1**: Surgery — Remove broken parallel-range code and dependent tests
- **CSR-2**: New `HasherCoordinator` with explicit written-range intervals + unit tests
- **CSR-3**: Rewire parallel-range streaming using new `HasherCoordinator`
- **CSR-4**: Deterministic out-of-order parallel-range correctness test (on CI plan)
- **CSR-5**: Wall-clock throughput test (Performance plan only)

These five sorties were designed to fix the `HasherCoordinator` sparse-file zero-fill bug that iteration 01's chunked-streaming/S1 introduced and chunked-streaming/S2 papered over. See `Docs/complete/quartermaster-torrent-01/BRIEF.md` §1.1 + §3 for the technical context.

## What was extracted into the next mission

The DC-1..DC-3 (deferred §1 cleanup) and CIH-1..CIH-2 (CI hygiene) sorties from this plan were tightly bound to REQUIREMENTS.md §3 (manifest-driven validity oracle) — specifically:

- **DC-1** (extend `acervo ship --spec` live mode) — the CLI gap that prevents shipping multi-component manifests.
- **DC-2** (live CDN re-upload of three Vinetas manifests) — ships the manifest format the validity oracle reads. Includes the **resolved** specs for `pixart-sigma-xl`, `flux2-klein-4b`, `flux2-klein-9b` after the 2026-05-20 HF audit (see this plan's Open Questions Q10 + Q-NU-1 + Q-NU-2).
- **DC-3** (remove `withKnownIssue` wraps) — test cleanup after DC-2 ships.
- **CIH-1** (audit test-plan placement) — independent CI hygiene.
- **CIH-2** (CI workflow + Makefile + shape gate) — independent CI hygiene.

These five carry-overs moved into [`Docs/incomplete/eighth-master-01/REQUIREMENTS.md`](../../incomplete/eighth-master-01/REQUIREMENTS.md), which is the active queued mission. They are no longer associated with QUARTERMASTER iteration 02.

## Revival conditions

This plan should be revived only after:

1. OPERATION EIGHTH-MASTER iteration 01 ships (so the local `manifest.json` write path and validity oracle are in place — these are load-bearing for any future chunked-streaming work).
2. The HasherCoordinator design conversation is re-opened from scratch — **do not revive CSR-2 verbatim**. The brief's open decisions §1 (track explicit written-range intervals vs. SEEK_HOLE vs. per-range temp files) should be reconsidered with whatever has been learned in the interim.
3. A new mission name is generated (via `/name-feature` or equivalent) — this work should not continue under the QUARTERMASTER TORRENT banner.

## Files

- [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md) — The 13-sortie iteration-02 plan as it existed at parking time. The plan's own header carries the "PARKED 2026-05-20" banner with the same rationale captured here.
