---
purpose: Status check on QUARTERMASTER TORRENT 01 PARTIAL_SALVAGE
generated: 2026-05-23
sources:
  - Docs/complete/quartermaster-torrent-01/BRIEF.md
  - git log on mission/quartermaster-torrent/01 vs development
---

# QUARTERMASTER TORRENT 01 — salvage status

## TL;DR

**The PARTIAL_SALVAGE prescribed by the BRIEF was never executed.** All five sound slug-registry sorties and the surgery-able chunked-streaming/S1 work remain stranded on `mission/quartermaster-torrent/01`. None of those commits have been cherry-picked into `development`. No `mission/quartermaster-torrent/02` branch exists.

The mission was archived (commit `91c110e`, "docs(missions): close out QUARTERMASTER 01") and frontmatter stamped `state: incomplete` — but the code-side salvage step was skipped.

## What the BRIEF said to do

Verdict was **PARTIAL_SALVAGE**. The recommended action (BRIEF §8) was:

1. Cut `mission/quartermaster-torrent/02` from `beeb091`.
2. Cherry-pick the five slug-registry merge commits in order:
   `6c814a8`, `81614a0`, `7d0f8d5`, `305bbf2`, `bc7e89d`
   (or the underlying feature commits: `e836747`, `f99325b`, `20742c5`, `40f9bf4`, `dfb2c41`).
3. Cherry-pick chunked-streaming/S1 (`ea6d23f`) and surgically revert the buggy parallel-range code (keep delegate rewrite, HTTP/3 per-request, redirect-rejection tests; drop `PartFileWriter`, `HasherCoordinator`, `runParallelRangeStream`, etc.).
4. Cherry-pick chunked-streaming/S2 (`460f580`) and delete `StreamingPerformanceTests.swift` + perf-plan file; keep `StreamingChunkingTests.swift` + `make test-perf` scaffolding.
5. Carry the BRIEF forward.

## What actually happened

```
$ git log v0.14.1..development --oneline
1a14d29  refactor(cli): collapse ship/upload onto Acervo.publishModel; drop aws runtime dep (#51)  ← VAULT BROOM 03
91c110e  docs(missions): close out QUARTERMASTER 01; queue EIGHTH-MASTER 01; tidy strays
d9d85d7  docs(mission): archive misnamed VAULT BROOM 02 artifacts; plan iteration 03
beeb091  docs: add EXECUTION_PLAN.md with R2-optimized chunked-streaming design
0efab63  docs: archive 0.14.0 requirements; promote TODO to active REQUIREMENTS
254f086  Mark development as 0.14.1-dev
```

Zero salvage commits landed. The "close out" commit (`91c110e`) was docs-only.

The slug-registry commits that the BRIEF marked as "complete, correct, ready to ship" still live exclusively on `mission/quartermaster-torrent/01`:

| Commit | What it adds | Status |
|---|---|---|
| `e836747` | Manifest schema: `primaryRepo` + `components` fields; slug-keyed `ManifestCache` actor | Stranded |
| `f99325b` + `eac8687` | `Acervo.availability(slug:url:)` + `AvailabilityAggregator` helper + 6 tests | Stranded |
| `20742c5` | `acervo ship --slug / --spec / --dry-run / --output-dir` CLI flags | Stranded |
| `40f9bf4` | `Acervo.ensureAvailable(slug:url:files:progress:)` w/ multi-component aggregation | Stranded |
| `dfb2c41` | `Acervo.deleteModel(slug:url:)` slug-keyed delete | Stranded |
| `ea6d23f` (partial) | Delegate-driven download + HTTP/3 per-request capability (salvageable half) | Stranded |

## Why this matters for EIGHTH-MASTER 01

The QUEUE.md entry says EIGHTH-MASTER 01 "soft-depends on QUARTERMASTER 01's PARTIAL_SALVAGE merge landing first (the slug-registry work it preserves is load-bearing for §1's manifest-cache fallback path)."

That dependency is still unsatisfied. Before EIGHTH-MASTER 01 can refine its EXECUTION_PLAN, one of three things has to happen:

1. **Execute the QUARTERMASTER salvage now** — cut `mission/quartermaster-torrent/02` per the BRIEF, cherry-pick, land via PR. ~1 sortie of mostly-mechanical work, plus surgery on the chunked-streaming commit. The slug-keyed API surface lands in development before EIGHTH-MASTER starts.
2. **Absorb the salvage into EIGHTH-MASTER 01's scope** — fold the cherry-picks + surgery into EIGHTH-MASTER's first sortie. Risk: bigger blast radius for a single mission; harder to review.
3. **Re-evaluate whether EIGHTH-MASTER actually needs the slug-keyed API** — re-read EIGHTH-MASTER 01 §1 against current code. If the manifest oracle can stand alone without the slug registry, demote the dependency to "nice to have" and execute salvage independently later.

## Recommendation

Execute option 1 before refining EIGHTH-MASTER 01. The mechanical salvage is cheap, the surgery on `ea6d23f` is well-specified, and landing it as its own PR keeps the review surface small. EIGHTH-MASTER 01 can then refine its plan against a development branch that already has the slug-keyed API.

If you want the salvage and EIGHTH-MASTER to land together for momentum reasons, option 2 is acceptable but should be flagged in EIGHTH-MASTER's REQUIREMENTS.md so the supervisor knows sortie 1 carries cherry-picks, not greenfield work.
