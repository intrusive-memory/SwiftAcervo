---
purpose: Mission queue index for SwiftAcervo
last_updated: 2026-05-23 (DRAWER DIVIDERS COMPLETE; EIGHTH-MASTER DC-2/DC-3 partial deferral)
---

# Mission queue — SwiftAcervo

This file is the single source of truth for what mission work is in flight, queued, or parked. Every mission's status here must match the `state:` frontmatter on its REQUIREMENTS.md / EXECUTION_PLAN.md / SUPERVISOR_STATE.md.

## Status legend

- **active** — Mission branch exists; sorties are dispatching or about to dispatch.
- **queued** — REQUIREMENTS exist; no execution plan refined yet OR refined but no branch cut. Next up to start.
- **parked** — Plan exists in `Docs/parked/`; revival waits on external conditions (technical or scope).
- **carry-forward** — Specific work item flagged in a brief or REQUIREMENTS but not yet promoted to its own mission. Lives in another doc's body, not its own directory.
- **closed** — Mission done; archived under `Docs/complete/`.

---

## Active

_(none right now)_

## Queued

### EIGHTH-MASTER 01 — Manifest-driven validity oracle + DC/CIH carry-overs
**Path**: `Docs/incomplete/eighth-master-01/`
**Why it's queued**: 2026-05-20 audit revealed `Acervo.availability()`'s presence-only validity check is wrong in both directions (Qwen3-Coder-Next-4bit false-positive; FLUX.2-klein-4B false-negative). Plus five sorties of carry-over work from the parked QUARTERMASTER iter02 plan that are tightly bound to the same artifact (local `manifest.json`).
**Scope**: §1 validity oracle + §2 local-manifest unification + CIH-1/CIH-2 (CI hygiene) + DC-1/DC-2/DC-3 (CLI port to PublishRunner architecture + live re-uploads + cleanup) sequenced last. EXECUTION_PLAN not yet refined.
**Blocks/blocked by**: Salvage landed via PR mission/quartermaster-salvage/01 (S1–S4 library work). S5's CLI `--slug`/`--spec`/`--dry-run`/`--output-dir` flags did NOT carry over (v0.15.0 removed `CDNUploader`; S5 must be ported, not cherry-picked) — that port is now folded into DC-1 and sequenced at the end of the mission per 2026-05-23 decision.
**Estimated effort**: TBD pending plan refinement; rough cut ~3-5 sorties for §1+§2, plus CIH-* + DC-* (DC-1 now includes the S5 CLI port).

## Parked

### QUARTERMASTER TORRENT 02 — Chunked-streaming rebuild (CSR-1..CSR-5)
**Path**: `Docs/parked/quartermaster-torrent-02/`
**Why it's parked**: Scope re-prioritized 2026-05-20 — manifest-driven validity oracle (now EIGHTH-MASTER 01) became higher-priority. Also, the parallel-range correctness fix needs design work that should benefit from whatever EIGHTH-MASTER learns about local-manifest persistence.
**Scope when revived**: Fix `HasherCoordinator` (track explicit written-range intervals instead of relying on filesystem sparse-read behavior); restore Test F to deliberate out-of-order delivery on CI; rebuild parallel-range streaming on the corrected coordinator.
**Revival conditions**: EIGHTH-MASTER 01 ships AND a fresh mission name is generated (do not revive under QUARTERMASTER banner) AND the HasherCoordinator design conversation is re-opened from scratch (do not revive CSR-2 verbatim).

## Carry-forwards (not yet promoted to own missions)

| Item | Lives in | Promotion candidate? |
|---|---|---|
| SwiftVinetas D2 cleanup — dead aggregation loop in `../Vinetas/Sources/SwiftVinetas/Engine/Flux2Engine.swift:426-433` | Mission-branch REQUIREMENTS.md §1.3 | Cross-package (in `../Vinetas/` repo); track from Vinetas side |
| PR #35 follow-up — cache-bypass on `publishModel` post-upload readback. **Primary finding** (preserved here since `Docs/PR35_CODE_REVIEW.md` was deleted in the 0.16.0 doc cleanup): the post-upload manifest readback in `publishModel` should bypass CDN edge cache (e.g., via a cache-busting query string OR by reading directly from the bucket origin) to defeat readback-from-stale-edge. | (text-only carry-forward) | Yes; small (~1 sortie). Could be a sortie tacked onto a future mission |
| SwiftAcervo telemetry/instrumentation | `Docs/REQUIREMENTS-instrumentation.md` (status: draft) | Yes; P3 priority. Becomes its own mission when prioritized |
| Bit-rot detection (file matches size, SHA differs) | EIGHTH-MASTER 01 §1.4 (out of scope) | Follow-up after EIGHTH-MASTER ships |
| Auto-remediation of `.partial` model state | EIGHTH-MASTER 01 §1.4 (out of scope) | Consumer-side; tracked from consumer libraries (Vinetas, SwiftBruja) |
| Populate SwiftAcervo-Performance.xctestplan with real perf measurements — CIH-2 created the plan as scaffolding (all 63 correctness suites in `skippedTests`; no perf tests exist yet). A future mission must add a `StreamingPerformanceTests` class (or equivalent), register it in the plan's `selectedTests`, and remove it from `skippedTests`. Origin: `StreamingPerformanceTests` was anticipated by the parked QUARTERMASTER-02 / CSR-* chunked-streaming rebuild mission; see revival conditions in the Parked section. | `Docs/incomplete/eighth-master-01/` (CIH-2 deliverable) | Yes; activate when the CSR-* mission is revived (new mission name required per parked plan revival conditions) |
| Add `StreamingPerformanceTests` source class before referencing it in SwiftAcervo-Performance.xctestplan — CIH-2's perf plan scaffolding could not use `selectedTests: ["StreamingPerformanceTests"]` because the class does not exist in source (it was expected from the parked CSR mission). The plan instead skips all 63 correctness suites. Once the class is added, update the plan's `selectedTests` and clear `skippedTests`. | `Docs/incomplete/eighth-master-01/` (CIH-2 PARTIAL finding) | Yes; prerequisite for the CSR-* revival mission |
| **DC-2 deferred — Vinetas live R2 re-upload** of `pixart-sigma-xl`, `flux2-klein-4b`, `flux2-klein-9b` so their CDN manifests carry the slug-registry schema fields and nested-path file enumeration. DC-2a was attempted 2026-05-23 against pixart-sigma-xl (first-upload — manifest was 404 on CDN, not a re-upload); cancelled after ~2h12m at ~2.6 MB/s effective throughput with ~12 GB transferred and ~15-20 GB still to go. Single-threaded sequential upload via `acervo ship` is too slow for these multi-GB diffuser repos on residential upstream. DC-2b and DC-2c never started. Specs at `Docs/incomplete/eighth-master-01/dc2-specs/pixart-sigma-xl.json` (and the two others to be authored when revived). Staging dir at `/private/tmp/acervo-staging/PixArt-alpha_PixArt-Sigma-XL-2-1024-MS/` preserved for now. | `Docs/incomplete/eighth-master-01/DC2_UPLOAD_LOG.md` (cancellation log) | Yes; revive when `acervo ship` gains parallel multipart, OR a faster upload tool is in place (rclone parallel, `aws s3 cp` with no write timeout), OR a faster connection is available. |
| **DC-3 (a) deferred — remove `withKnownIssue` wraps in `Tests/AcervoToolTests/CDNManifestFetchTests*` + the 2 useless-`try` warnings inside those wraps.** Original DC-3 scope had three parts: (a) wrap removal, (b) useless-try cleanup, (c) the 6 var→let warnings from DC-1. The DRAWER DIVIDERS-01 merge ships (c) only — (a) requires DC-2 to have shipped new-schema manifests to live R2 (otherwise the wrapped tests would hard-fail). (b) is tied to (a) — the `try`s are only "useless" once the wrap is removed. Both defer with DC-2. | EIGHTH-MASTER 01 plan, Sortie DC-3 | Yes; runs together as a single small sortie immediately after DC-2 successfully ships. |

## Closed

(see [`../complete/`](../complete/))

| Operation | Iteration | Closed | Verdict | Path |
|---|---|---|---|---|
| FILING SERGEANT | 01 | 2026-04 | Complete | `Docs/complete/filing-sergeant-01/` |
| SHARED PANTRY | 01 | 2026-? | Complete | `Docs/complete/shared-pantry-01/` |
| WHISPERING WIRETAPS | 01 | 2026-? | Complete | `Docs/complete/whispering-wiretaps-01/` |
| TICKET STUB | 01 | 2026-? | Complete | `Docs/complete/ticket-stub-01/` |
| DESERT BLUEPRINT | 01 | 2026-04 | Complete (KEEP) | `Docs/complete/desert_blueprint_01_*` (loose files) |
| SWIFT ASCENDANT | 01 | 2026-04 | Complete | `Docs/complete/swift_ascendant_01_*` (loose files) |
| TRIPWIRE GAUNTLET | 02 | 2026-04-23 | KEEP (after P1 triage) | `Docs/complete/tripwire-gauntlet-02-brief.md` |
| VAULT BROOM | 02 | 2026-05-21 (archived) | Superseded by VAULT BROOM 03 | `Docs/complete/vault-broom-02/` |
| VAULT BROOM | 03 | 2026-05-23 | KEEP (clean 2-sortie execution) | `Docs/complete/vault-broom-03/` |
| SwiftAcervo v1 (original implementation) | — | (shipped) | n/a | `Docs/complete/swift-acervo-v1-implementation/` |
| QUARTERMASTER TORRENT | 01 | 2026-05-21 | PARTIAL_SALVAGE | `Docs/complete/quartermaster-torrent-01/` |

## How to update this file

When a mission state changes:
1. Update the mission's own frontmatter (`state:` field).
2. Move the entry between sections of this QUEUE.md (Queued → Active → Closed; or Active → Parked).
3. Update `last_updated:` at the top.
4. If a mission closes, add a row to the Closed table with verdict + path.
5. If a new carry-forward becomes a mission of its own, promote it from the Carry-forwards section.

This file is meant to be a one-screen scan of "what's the project doing." If it grows past two screens, archive Closed entries older than 6 months to a separate `CLOSED_HISTORY.md`.
