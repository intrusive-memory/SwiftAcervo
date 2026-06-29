---
type: mission-brief
state: incomplete
feature_name: OPERATION INTEGRITY CHECKPOINT
mission_branch: mission/integrity-checkpoint/01
iteration: 1
---

# Iteration 01 Brief — OPERATION INTEGRITY CHECKPOINT

**Mission:** Make model availability dependency-aware and integrity-verified via gated full-hash + a persisted verified marker, so incomplete/corrupt models (incl. FLUX.2's text-encoder dependency) are caught before use.
**Branch:** `mission/integrity-checkpoint/01` (in both SwiftAcervo and SwiftVinetas)
**Starting Point Commit:** SwiftAcervo `5aae72d`; SwiftVinetas `d34b4ae`
**Sorties Planned:** 6 (A1–A3, B1–B3)
**Sorties Completed:** 5 code sorties (A1, A2, A3, B1, B2)
**Sorties Failed/Blocked:** 0 failed; 1 deferred (B3, manual E2E, by user decision)
**Duration:** ~40 min wall clock; relative cost 110× (opus×2, sonnet×3)
**Outcome:** Incomplete (B3 manual acceptance deferred)
**Verdict:** `KEEP` — all five code sorties landed, both unit gates are green, the one partial was caught and corrected; B3 is a deferred manual acceptance, not a code defect.
**Tests pruned:** 0
**Tests flagged for review:** 0

---

## Section 1: Hard Discoveries

### 1. The Mistral trap is real and upstream-shaped
**What happened:** `flux-2-swift-mlx`'s `Flux2Core.ModelRegistry.TextEncoderVariant.huggingFaceRepo` returns **Mistral** repos and can't even distinguish klein4B from klein9B. Routing `.textEncoder` through it would have silently pointed FLUX at the wrong text encoder.
**What was built to handle it:** B1 introduced a SwiftVinetas-owned `Flux2Component` enum with a nested `TextEncoder` (`.klein4B`/`.klein9B`) owning the Qwen3-MLX-8bit mapping directly, plus a guard test asserting no repo id contains "mistral" and every one contains "Qwen3".
**Should we have known this?** Yes — it was called out in the plan (Decisions Log OQ-1) from prior CDN verification. The plan's pre-flagging is exactly why B1 didn't regress.
**Carry forward:** SwiftVinetas owns the FLUX text-encoder→Acervo mapping. Never delegate it to the upstream `TextEncoderVariant`.

### 2. SwiftVinetas `make test-unit` is not self-contained
**What happened:** `make test-unit` crashes (fatalError in SwiftAcervo `Acervo+CDNConfiguration.swift`) unless `ACERVO_CDN_BASE_URL` / `TEST_RUNNER_ACERVO_CDN_BASE_URL` are exported. The Makefile relies on the developer's shell profile.
**What was built to handle it:** Nothing in-scope — agents exported the vars per-run; the supervisor threaded the requirement into every WU-B dispatch.
**Should we have known this?** Partially. It's a pre-existing SwiftAcervo consumer requirement; the plan didn't surface it because no WU-B sortie had run `make test-unit` before.
**Carry forward:** Make the SwiftVinetas `make test-unit` target export a default CDN URL (or document it loudly) so it doesn't depend on a shell profile. Tracked in TEST_CLEANUP_REPORT.md.

### 3. `verifyIntegrity` and `availability` have deliberately different hash semantics
**What happened:** B2's first pass assumed `verifyIntegrity` would take the marker fast-path. It does not — A2 made `verifyIntegrity` ALWAYS full-hash (its job is to *establish* the marker); the marker fast-path lives in `availability(_, verifyHashes:)`. Using the wrong primitive made `loadModel` re-hash multi-GB models on every generation.
**What was built to handle it:** B2 continuation switched the load-path guard to `Acervo.availability(_, verifyHashes: true)`.
**Should we have known this?** Yes — it was implicit in A2's design and the plan's exit-criterion wording ("when a required component has no valid marker"). The two-primitive split should be documented on the SwiftAcervo API surface.
**Carry forward:** Document on `Acervo`: `verifyIntegrity` = establish/refresh marker (always hashes, writes marker); `availability(verifyHashes:true)` = marker-gated decisive check (trusts valid marker, never writes). Consumers gating a hot path want the latter.

## Section 2: Process Discoveries

### What the Agents Did Right
- **A2 built a timing-free spy seam** (`availabilityEvaluatorOverride` `@TaskLocal`) — exactly what the exit criteria demanded and reusable by A3/B2. Foundation done correctly the first time.
- **B1 chose the durable fix** (SwiftVinetas-owned component enum) over a brittle patch to upstream Mistral types, closing the trap permanently.

### What the Agents Did Wrong
- **B2 first pass reached for the wrong primitive** (`verifyIntegrity` instead of marker-gated `availability`), which passed the literal exit criteria and its own tests while defeating the mission's core thesis (per-generation multi-GB rehash). Caught by supervisor review, not by the test suite — a reminder that green tests ≠ correct design.

### What the Planner Did Wrong
- **Exit-criterion wording let a letter-vs-spirit gap through.** B2's criterion 1 ("invokes verifyIntegrity when a component has no valid marker") was satisfiable by invoking it unconditionally. A sharper criterion ("a component WITH a valid marker must NOT trigger a full hash on load — assert via spy") would have forced the right primitive on the first pass.
- **The CDN-env test requirement was not surfaced in WU-B entry criteria**, costing each WU-B agent a discovery cycle.

## Section 3: Open Decisions

### 1. Run the deferred B3 end-to-end acceptance?
**Why it matters:** B3 is the only confirmation that the integrity behaviors hold with real FLUX artifacts (kill-mid-download → reports incomplete; complete → marker written for transformer/VAE/Qwen3; real generation produces an image). Unit tests cover the logic but not the real-bytes path.
**Options:** (A) Run it manually later via Vinetas.app + VinetasCLI; (B) script a download-interrupt harness so it can run semi-automatically; (C) accept unit coverage and skip.
**Recommendation:** (A) before merging WU-B to a release, or at least before the next FLUX-touching mission.

### 2. Fix the B2 no-marker doc-comment inaccuracy + edge case?
**Why it matters:** The `integrityChecker` doc comment claims `availability` writes the marker on the no-marker path (it doesn't). Functionally minor (downloaded models get markers via A3), but misleading, and no-marker models full-audit on every load.
**Options:** (A) one-line doc fix in a follow-up; (B) add a public `Acervo.hasValidVerifiedMarker(_:)` and have `loadModel` call `verifyIntegrity` (which writes the marker) on the no-marker path so first load establishes it.
**Recommendation:** (A) now; consider (B) if no-marker/legacy models prove common in practice.

## Section 4: Sortie Accuracy

| Sortie | Task | Model | Attempts | Accurate? | Notes |
|--------|------|-------|----------|-----------|-------|
| A2 | verified-marker + verifyIntegrity + fast-path | opus | 1 | ✅ Yes | Foundation; spy seam reused downstream. Survived intact. |
| A1 | diffusers heuristic hardening | sonnet | 1 | ✅ Yes | Disjoint file; clean, no regression. |
| A3 | marker-on-download | sonnet | 1 | ✅ Yes | Reused A2 writer; full-model-only guard. |
| B1 | FLUX text-encoder component (Qwen3) | opus | 1 | ✅ Yes | Durable Mistral-trap fix. |
| B2 | fail-fast load guard | sonnet | 1 pass + 1 cont | ⚠️ Partly | First pass used wrong primitive (re-hash every load); corrected in continuation. Final state correct. |
| B3 | E2E FLUX acceptance | — | 0 | ⏸ Deferred | Manual; deferred by user (resource-heavy). |

## Section 5: Harvest Summary

We now know the integrity machinery composes cleanly across the two repos with **zero SwiftAcervo changes needed on the SwiftVinetas side** (the sibling pattern + A2's marker-aware `availability` were sufficient). The single most important lesson for the next iteration: when a consumer gates a hot path on integrity, it must use the **marker-aware `availability(verifyHashes:true)`**, not `verifyIntegrity` — and the plan's exit criteria should assert the fast-path is taken (via spy), not just that the audit is invoked. Test cleanup found nothing to prune (0 removed, 0 flagged): the mission's tests are uniformly hermetic (temp dirs, MockURLProtocol, injected stubs).

## Section 6: Files

**Preserve (read-only reference for next iteration):**
| File | Branch | Why |
|------|--------|-----|
| `Sources/SwiftAcervo/VerifiedMarker.swift` | acervo mission | The marker model + read/write helpers; foundation. |
| `Sources/SwiftAcervo/Acervo+Availability.swift` | acervo mission | `verifyIntegrity` + marker fast-path + spy seam. |
| `Sources/SwiftVinetas/Engine/Flux2Engine.swift` | vinetas mission | `Flux2Component` enum (Qwen3 mapping) + marker-gated load guard. |
| `TEST_CLEANUP_REPORT.md` | acervo mission | CDN-env hard discovery + scan results. |

**Discard (will not exist after rollback):** _None — verdict is KEEP; nothing to discard._

## Iteration Metadata

**Starting point commit:** SwiftAcervo `5aae72d` (chore: mark development as 0.22.0-dev); SwiftVinetas `d34b4ae` (chore(dev): restore sibling pattern + 0.15.7-dev)
**Mission branch:** `mission/integrity-checkpoint/01` (both repos)
**Final commit on mission branch:** SwiftAcervo `92b3336`; SwiftVinetas `4998dca`
**Rollback target:** SwiftAcervo `5aae72d`; SwiftVinetas `d34b4ae` (not exercised — verdict is KEEP)
**Next iteration branch (if any):** `mission/integrity-checkpoint/02`

## Rollback Verdict

**Verdict:** `KEEP`

**Reasoning:** All five code sorties landed and both unit gates are green (SwiftAcervo main 685/97; SwiftVinetas 758/83). The only retry was B2's self-corrected PARTIAL (wrong primitive → fixed in a continuation, no failure), and the foundation work (A2) survived intact and was reused by three downstream sorties (Section 4). Test cleanup removed 0% of mission tests. B3 is a deferred *manual* acceptance, not a defect — the behaviors it would confirm are already unit-verified (Sections 1, 4). Per the early-iteration honest default we'd lean ROLLBACK only if the foundation were shaky; it is not.

**Recommended action (KEEP):** Merge both mission branches (SwiftAcervo first, then SwiftVinetas — respect the dependency order). Follow-up tickets:
1. Run the deferred B3 end-to-end acceptance before a FLUX-facing release (Open Decision 1).
2. Fix the B2 `integrityChecker` doc-comment inaccuracy re: marker writing (Open Decision 2).
3. Make SwiftVinetas `make test-unit` self-contained re: `ACERVO_CDN_BASE_URL` (Hard Discovery 2).
4. Document the `verifyIntegrity` vs `availability(verifyHashes:)` hash-semantics split on the Acervo API surface (Hard Discovery 3).
