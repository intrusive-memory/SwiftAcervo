---
created: 2026-05-23
source_plan: ../acervo-swift-decomposition-plan.md
---

# REQUIREMENTS — Acervo.swift decomposition

## 1. Background

`Sources/SwiftAcervo/Acervo.swift` has grown to ~2780 lines (110 KB). It now mixes 22 distinct functional concerns under a single `public enum Acervo` namespace. Reading any one concern requires scrolling past every other; reviewing a diff against this file is slow; and adding focused unit tests for a single concern (e.g. the `HydrationCoalescer` actor or the slug-keyed `ComponentStateBox` aggregator) requires touching a file every other concern also lives in.

A read-only architectural-planning pass (out-of-mission, written 2026-05-23, see `Docs/incomplete/acervo-swift-decomposition-plan.md`) inventoried the file, proposed a decomposition into 14 sibling `Acervo+<Concern>.swift` files (mechanical cut-and-paste, zero public-API breakage), and recommended ~5 batched sorties.

This mission **refines** that plan into one sortie per extracted file (functional-unit granularity) and adds explicit test-file reorganization so the test layout mirrors the new source layout where it makes sense.

## 2. Why this mission, why now

- **Maintainability**: 2780-line file is a code-review and grep-ability tax on every contributor.
- **Testability**: Several internal helpers (`HydrationCoalescer`, `ComponentStateBox`, slug parsing helpers) deserve focused unit tests but cannot earn them without first being given a home that is not a 2780-line file.
- **Pattern already in use**: `Acervo+CDNMutation.swift` and `ValidityOracle.swift` already follow the `Acervo+<Concern>.swift` / sibling-type extraction pattern. This mission generalizes that to every concern.
- **Risk profile is low**: every extraction is mechanical cut-and-paste of an `extension Acervo { ... }` block within the same module. Swift makes such moves source-compatible with zero ABI change.

## 3. Items (high-level)

- [ ] **Inventory honored**: every section of `Acervo.swift` enumerated in §1 of the source plan moves to its proposed home; the residual `Acervo.swift` is the enum shell + offline-mode env helpers only (~55 lines).
- [ ] **One sortie per extracted file** (14 sorties + 1 closure sortie).
- [ ] **Test reorganization per sortie where it makes sense**: each sortie that extracts a source file also considers whether the companion test file(s) should be renamed, split, or have new focused tests added to mirror the new source boundary. Where the existing test file already aligns with the new source file (1-to-1), no test changes are required and the sortie says so explicitly.
- [ ] **Zero public-API breakage**: every `Acervo.foo(...)` call site (in `AcervoManager`, in consumers, in tests) continues to compile and pass without edits beyond the extraction itself.
- [ ] **`make build` + `make test` + `make test-plan-shape` green at every sortie HEAD** (F3 inheritance).
- [ ] **EM-3 already lands** before this mission starts (the mission requires the `Acervo.localModels()` filter + `gcEmptyModelDirectories()` from EM-3 to be in the tree; OPERATION EIGHTH-MASTER has shipped these as of commit `6275e54` on the `mission/eighth-master/01` branch).

## 4. Acceptance

1. `Sources/SwiftAcervo/Acervo.swift` is ≤ 100 lines at the final sortie HEAD (residual enum shell + offline-mode helpers + cross-file shared helpers if any survive).
2. Every public `Acervo.*` method/property listed in `Docs/API_REFERENCE.md` continues to resolve to the same fully-qualified name. No symbol renamed.
3. `AcervoManager.swift` does not need a single line edit as a result of this mission (every `Acervo.foo(...)` call site continues to resolve).
4. Every new file is under 400 lines.
5. Every new file has a 1-paragraph header comment naming the concern, the file's owner-of-record, and the test file(s) that exercise it.
6. The test tree's filename layout mirrors the source tree's filename layout 1-to-1 where it makes sense (sortie author judgment; explicitly justified per sortie).
7. `make build` + `make test` + `make test-plan-shape` exit 0 at every sortie HEAD AND at the final mission HEAD.

## 5. Out of scope

- **No method signature changes.** No `private` → `internal` or vice versa unless cross-file visibility forces it.
- **No new types.** No new structs/enums/actors except `HydrationCoalescer` moving into `Acervo+Hydration.swift` (already exists; only its location changes).
- **No `AcervoManager` actor changes.** The actor's surface is downstream-consumed and stable; out of scope.
- **No `AcervoDownloader` / `S3CDNClient` / `ManifestGenerator` further sub-division.** Those siblings are already extracted; this mission does not redivide them.
- **No genuine refactors.** Specifically: `ComponentStateBox` extraction from F6, `SingleFlight<Key,Value>` generalization of `HydrationCoalescer`, and the "shared slug-keyed helper" between F6 and F7 are explicitly deferred to a follow-up mission. This mission is mechanical-extraction-only.
- **No documentation rewrites.** Update `Docs/PROJECT_STRUCTURE.md` once at the end if the file list materially changes; no per-extraction doc churn.

## 6. References

- Source plan: `Docs/incomplete/acervo-swift-decomposition-plan.md`
- Existing template files: `Sources/SwiftAcervo/Acervo+CDNMutation.swift`, `Sources/SwiftAcervo/ValidityOracle.swift`
- API reference: `Docs/API_REFERENCE.md`
- Project structure: `Docs/PROJECT_STRUCTURE.md`
