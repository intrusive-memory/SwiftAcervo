# REQUIREMENTS: Manifest-as-Bundle Components

**Status**: Discovery + behavioral audit needed before final design.
**Target version**: next minor (component-API surface change, additive where possible).
**Owner**: Tom Stovall

---

## 1. Background

SwiftAcervo's component-keyed contract — `registerComponent`, `ensureComponentReady`, `withComponentAccess`, `deleteComponent`, `isComponentReady` — was hardened in the SwiftVinetas "manifest-destiny" mission against a homogeneous shape: **one logical component = one CDN manifest = one HF/CDN repo**.

That worked for every PixArt-side component because intrusive-memory had already published them that way:

- `intrusive-memory/pixart-sigma-xl-dit-int4-mlx` (DiT)
- `intrusive-memory/t5-xxl-int4-mlx` (text encoder)
- `intrusive-memory/sdxl-vae-fp16-mlx` (VAE)

Three independent HF lineages, three independent CDN manifests, three independent components. The 1:1 mapping fell out of how the weights were authored, not from the contract being intrinsically right.

When SwiftVinetas tried to bring its **Flux2Engine** under the same contract, the assumption broke. The upstream model `black-forest-labs/FLUX.2-klein-4B` is a **bundled** repo — transformer + text_encoder + tokenizer + vae + scheduler all in subfolders of one HF/CDN repo, mirrored as **one** `manifest.json` covering all files. The natural "components" of Flux2 (transformer, VAE, text encoder) are subsets of that single manifest, not separate manifests.

The result was a runtime failure at first generation:
```
directoryCreationFailed("/Users/.../SharedModels/black-forest-labs_FLUX.2-klein-4B")
```
because the new component-keyed code path expected per-component CDN repos and on-disk directories, not "many components share one manifest and one directory."

This requirements doc captures the work to **make manifest-as-bundle a first-class shape** alongside the existing per-component-manifest shape.

---

## 2. What already exists

### 2.1 The architecture is *partially* there

`ComponentDescriptor` (`Sources/SwiftAcervo/ComponentDescriptor.swift:70`) already accepts an explicit `files: [ComponentFile]` list at registration time. Two descriptors with **different `id`s but the same `repoId`** are legal — the registry deduplicates by `id`, not by `repoId`. So in principle, multiple Flux2 components (`flux2-klein-4b-transformer`, `flux2-klein-4b-vae`, etc.) can all reference `black-forest-labs/FLUX.2-klein-4B` and each declare the file paths they care about.

What we don't yet know — and the first sortie should establish — is whether every component-keyed API actually **honors** that file scope, or whether some of them treat the whole `repoId` as the unit.

### 2.2 Concrete questions to answer in audit

- `ensureComponentReady(componentId)` — does it download only the files declared in the descriptor, or every file in the manifest?
- `withComponentAccess(componentId)` — is the returned handle scoped to declared files only? Does it materialize them into a stable layout that subfolder-shaped components expect?
- `isComponentReady(componentId)` — does it check only declared files, or every file in the repo?
- `deleteComponent(componentId)` — does it delete just the declared files, or the whole `org_repo/` directory? If the latter, deleting one component breaks every other component that shares the manifest.
- The "re-registering" stderr canary added in the manifest-destiny work — does registering **N components against the same `repoId`** trigger a false positive? It absolutely should not.
- `Acervo.modelDirectory(for:)` returns one path per `org_repo` slug. For bundle components, multiple components share that path — confirmed compatible, or do we need a per-component sub-path?

These need machine-verifiable answers (read the code, write a test) before we know how big the actual gap is.

### 2.3 Existing documentation to update, not duplicate

- `API_REFERENCE.md` — the component-keyed API doc. Needs a "Bundle components" section.
- `ARCHITECTURE.md` — overview of the registry / hydration model.
- `CDN_ARCHITECTURE.md` — security/manifest model. The bundle pattern doesn't change the manifest format, only how components map to it.
- `DESIGN_PATTERNS.md` — best-practice patterns for plugin authors. Add the bundle pattern as a recognised choice.

---

## 3. Goals

- **G1.** Make "many components, one manifest" a documented, supported shape. A plugin author writing `Flux2KleinDescriptor`-style descriptors should know which pattern to pick and what guarantees they get.
- **G2.** Every component-keyed API (`ensureComponentReady`, `withComponentAccess`, `isComponentReady`, `deleteComponent`, manifest fetch) honors the descriptor's declared file scope. No API silently widens its scope to the whole manifest.
- **G3.** No regression for existing per-component-manifest plugins (PixArt, ViT, DINOv2, every `mlx-community/*` user). They keep their semantics unchanged.
- **G4.** The register-warning canary continues to fire on **genuine** re-registration (same `id`, conflicting descriptor) but **does not fire** when N distinct components register against the same `repoId`.
- **G5.** A round-trip test demonstrates the bundle pattern end-to-end: register 3 bundle components against one CDN manifest, ensure-ready each, access each independently, delete one without breaking the others.

---

## 4. Non-goals

- **NG1.** Republishing existing weights in a different CDN layout. PixArt stays as 3 manifests; Flux2 stays as one manifest per HF repo. This is purely a SwiftAcervo-side contract refinement.
- **NG2.** Migrating downstream consumers (SwiftVinetas Flux2Engine, flux-2-swift-mlx). Those are separate missions that consume this work.
- **NG3.** Changing the on-CDN manifest format. The same `manifest.json` shape is fine; bundle behavior is purely a registration/access concern.
- **NG4.** Adding a new "bundle manifest" type at the CDN level. The natural unit is "the descriptor's declared files," not a CDN-side construct.
- **NG5.** Designing a generic file-glob query language. Plugins declare exact `ComponentFile` paths up front (or hydrate from manifest with an explicit subset filter) — no runtime path matching.

---

## 5. Functional requirements

### 5.1 Behavioral guarantees (what the audit will likely surface as gaps)

For a `ComponentDescriptor` `D` with `files = [f1, f2, ...]` where `D.repoId` resolves to a CDN manifest covering a superset `{f1, f2, ..., fN}`:

- **R1.** `ensureComponentReady(D.id)` downloads exactly `D.files`. No more, no less.
- **R2.** `withComponentAccess(D.id) { handle in ... }` exposes those files via paths consistent with their on-disk layout (preserve subfolder structure when present).
- **R3.** `isComponentReady(D.id)` returns true iff every file in `D.files` is on disk and checksums match. Other files in the same manifest are irrelevant.
- **R4.** `deleteComponent(D.id)` removes `D.files`. It does **not** remove files belonging to sibling components (other descriptors with the same `repoId` but different `id`).
- **R5.** `Acervo.fetchManifest(forComponent: D.id)` returns the full CDN manifest (current behavior is correct — no change).
- **R6.** Registering two descriptors with `id = X` against `repoId = R` once each does not fire the re-register canary. Registering the *same* `id` twice with a different file scope does fire it (genuine identity conflict).

### 5.2 On-disk layout

Bundle components materialize files into the same `<sharedModelsDirectory>/<slug(repoId)>/` directory, preserving the manifest's relative paths. Two components sharing a `repoId` see one another's files on disk; this is **expected** and the deletion semantics in **R4** must respect it (delete only the files this component declared).

If a future need arises to isolate component file storage even when sharing a manifest, that is a separate proposal — not in scope here.

### 5.3 Hydration

Bundle descriptors should support **explicit file declaration** at registration time (already supported via the `files:` initialiser at `ComponentDescriptor.swift:122`). Hydration-from-manifest with a path filter is a natural extension but is a stretch goal — the explicit form is enough to unblock Flux2.

If we add a hydration-with-filter overload, it should accept a `Set<String>` of paths or a single subfolder prefix; no glob language.

### 5.4 Registry semantics

`ComponentRegistry`:

- Keys components by `id`. No change.
- Allows multiple components to share `repoId`. No change.
- Re-registration of the same `id` with a *different* descriptor (different `files`, different `type`, etc.) is the genuine collision case the canary watches for. No change.
- Re-registration of the same `id` with an *equivalent* descriptor (idempotent re-registration) is silent. This is already implemented per the `manifest-destiny-01` work (SwiftAcervo `0.11.1`). Confirm it still holds.

---

## 6. Acceptance criteria

A6.1 — **Audit report.** A markdown summary in `docs/incomplete/manifest-as-bundle-audit.md` (or wherever the mission keeps it) listing, for each of `ensureComponentReady`, `withComponentAccess`, `isComponentReady`, `deleteComponent`, `fetchManifest(forComponent:)`, and the re-register canary, whether the current behavior already honors **R1–R6** above. Each entry cites a file:line and a test (or notes the test gap).

A6.2 — **Tests pin every behavior in §5.1.** New tests in `Tests/SwiftAcervoTests/` register 2 or 3 distinct components against the same `repoId` (using a mock CDN with `MockURLProtocol`) and assert R1–R6 hold. These are unit-level — no real CDN download.

A6.3 — **Code changes (where R1–R6 fail).** Minimal, targeted edits to make each failing behavior pass. No speculative API surface — only what's needed to satisfy the tests.

A6.4 — **No regressions.** The existing PixArt-pattern test suite (single component per manifest) passes unchanged. The register-warning canary still fires for genuine re-registration of the same `id`.

A6.5 — **Documentation.** A new section in `API_REFERENCE.md` (or `DESIGN_PATTERNS.md`) called "Bundle components" with:
  - When to use this pattern (one HF/CDN repo bundles multiple logical components in subfolders)
  - How to declare descriptors (one per logical component, all sharing `repoId`, each with its own `files` list)
  - What the contract guarantees (R1–R6 phrased for plugin authors)
  - Worked example using FLUX.2-klein-4B (transformer + text_encoder + vae)

A6.6 — **CHANGELOG entry** describing the contract refinement, marked as additive (no consumer breakage expected; PixArt-pattern code keeps working unchanged).

A6.7 — **Smoke validation against a real bundle manifest.** A local-only test (gated like `TEST_RUNNER_*` flags) downloads a real subset from `black-forest-labs/FLUX.2-klein-4B` (e.g., just `text_encoder/config.json` plus one tokenizer file — small, free) using the bundle pattern, asserts the files land in the right place, and `deleteComponent` removes only those files. Skips gracefully if `R2_PUBLIC_URL` isn't reachable.

---

## 7. Out-of-scope but adjacent

These are explicitly **deferred** — they may become follow-on missions but should not creep into this one:

- Migrating SwiftVinetas Flux2Engine onto the bundle pattern (will be SwiftVinetas's `manifest-destiny-02` mission, blocked on this work landing).
- Migrating flux-2-swift-mlx (the actual Flux2 download/load library) onto the bundle pattern. This is a downstream mission once SwiftAcervo's contract is solid.
- Publishing CDN manifests for `black-forest-labs/FLUX.2-klein-9B` and base variants. Flux2-klein-4B is sufficient to validate the bundle pattern end-to-end.
- A "register from manifest with subset filter" hydration overload. Explicit file declaration in the descriptor is sufficient for now.

---

## 8. Open questions for breakdown

These should be resolved during `/mission-supervisor refine-questions`, not pre-decided here:

- **Q1.** `deleteComponent` for a bundle component: must we **refuse** deletion if files are shared with another registered component, or just delete only the declared files (and rely on the registry to know what's still in use)? Deciding factor: do we want delete to be a destructive escape hatch, or a referential-integrity-aware operation?
- **Q2.** The on-disk size returned by `Acervo.diskSize(forComponent:)` for a bundle component: does it report only the declared files' size, or the whole shared directory's size? §5.1 implies declared-files-only, but this needs explicit confirmation.
- **Q3.** Should `ensureComponentReady` for a bundle component download files **shared with already-ready siblings** (re-verify them) or short-circuit on existing files? The simplest answer is "verify checksums of existing files; download missing ones" but the implementation may already pick a side.
- **Q4.** Does this work merit a SwiftAcervo minor or patch bump? If R1–R6 are already mostly honored and we're just codifying behavior + adding tests + docs, patch is fine. If R1–R6 require non-trivial implementation changes, minor.
- **Q5.** Is there a need for a `BundleComponentDescriptor` convenience initialiser that takes `(repoId, subfolder)` and auto-derives the file list from the manifest? Or is the explicit `files:` initialiser ergonomic enough? Recommendation: defer the convenience init unless it shows up as a clear pain point.

---

## 9. References

- `Sources/SwiftAcervo/ComponentDescriptor.swift:70` — descriptor type, supports explicit file list.
- `Sources/SwiftAcervo/ComponentRegistry.swift` — id-keyed registry, dedup by id.
- `Sources/SwiftAcervo/Acervo.swift:1496` — `fetchManifest(for:)`.
- `Sources/SwiftAcervo/Acervo.swift:1519` — `fetchManifest(forComponent:)`.
- `Sources/SwiftAcervo/Acervo+CDNMutation.swift` — CDN-side operations (read for download path semantics).
- `Sources/SwiftAcervo/AcervoDownloader.swift:34` — CDN base URL + slug logic.
- `Sources/SwiftAcervo/Acervo.swift:217` — `slugify(_:)` (`/` → `_`).
- Existing CDN manifest at `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/black-forest-labs_FLUX.2-klein-4B/manifest.json` — real bundle to test against (transformer + text_encoder/* + tokenizer/* + vae/* + scheduler/*).
- SwiftVinetas `docs/complete/manifest-destiny-01/EXECUTION_PLAN.md` — context on the original component-keyed migration this work refines.
