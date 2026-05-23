---
purpose: Mission queue index for SwiftAcervo
last_updated: 2026-05-23
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
| PR #35 follow-up — cache-bypass on `publishModel` post-upload readback | `Docs/PR35_CODE_REVIEW.md` (primary finding) | Yes; small (~1 sortie). Could be a sortie tacked onto VAULT BROOM 03 or its own follow-up mission |
| SwiftAcervo telemetry/instrumentation | `Docs/REQUIREMENTS-instrumentation.md` (status: draft) | Yes; P3 priority. Becomes its own mission when prioritized |
| Bit-rot detection (file matches size, SHA differs) | EIGHTH-MASTER 01 §1.4 (out of scope) | Follow-up after EIGHTH-MASTER ships |
| Auto-remediation of `.partial` model state | EIGHTH-MASTER 01 §1.4 (out of scope) | Consumer-side; tracked from consumer libraries (Vinetas, SwiftBruja) |

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
