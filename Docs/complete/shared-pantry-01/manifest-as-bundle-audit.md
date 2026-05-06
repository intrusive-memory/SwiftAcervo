# Manifest-as-Bundle Audit — OPERATION SHARED PANTRY (Sortie 1)

This document audits SwiftAcervo's component-keyed API surface against requirements R1–R6 for the "manifest-as-bundle" shape: multiple `ComponentDescriptor`s sharing one `repoId` (and therefore one CDN manifest), each declaring a different `files` subset. The trigger case is `black-forest-labs/FLUX.2-klein-4B`. Citations reference the source tree as of commit `1ec90e7`.

---

## R1 — ensureComponentReady downloads exactly declared files

**Code trace:**

`Acervo.ensureComponentReady(_:in:)` (`Sources/SwiftAcervo/Acervo.swift:1741`) short-circuits via `isComponentReady` if all declared files are present, then delegates to `downloadComponent(_:force:progress:in:)` (`Sources/SwiftAcervo/Acervo.swift:1667`).

`downloadComponent` reads `descriptor.files` and maps them to a `[String]` file list (`Sources/SwiftAcervo/Acervo.swift:1687`):
```
let fileList = descriptor.files.map(\.relativePath)
```
That list is passed to `Acervo.download(_:files:force:progress:in:)` (`Sources/SwiftAcervo/Acervo.swift:1690–1696`), which passes it as `requestedFiles` to `AcervoDownloader.downloadFiles(modelId:requestedFiles:destination:force:progress:session:)` (`Sources/SwiftAcervo/AcervoDownloader.swift:722`).

Inside `downloadFiles`, when `requestedFiles` is non-empty, only those files are fetched (`Sources/SwiftAcervo/AcervoDownloader.swift:738–748`):
```swift
filesToDownload = try requestedFiles.map { fileName in
    guard let entry = manifest.file(at: fileName) else {
        throw AcervoError.fileNotInManifest(...)
    }
    return entry
}
```
So the download itself is correctly file-scoped. **However**, there is a critical gap in the un-hydrated descriptor path.

**The hydration gap (GAP for un-hydrated bundle descriptors):**

If a `ComponentDescriptor` is registered with `files: nil` (un-hydrated, using the bare `init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)` initializer at `Sources/SwiftAcervo/ComponentDescriptor.swift:145`), `ensureComponentReady` calls `hydrateComponent` first (`Sources/SwiftAcervo/Acervo.swift:1751–1753`).

`performHydration` (`Sources/SwiftAcervo/Acervo.swift:1591`) fetches the full manifest and replaces the descriptor with ALL manifest files:
```swift
let hydratedFiles = manifest.files.map { entry in   // ALL files
    ComponentFile(...)
}
```
After hydration, `descriptor.files` contains every file in the manifest — not the subset declared at registration. This means an un-hydrated bundle descriptor will download the entire manifest. This is the correct behavior for the single-component-per-manifest pattern but breaks R1 for bundle components that intend to declare only a subset via the un-hydrated path.

For **pre-hydrated** descriptors (using `init(id:type:displayName:repoId:files:estimatedSizeBytes:minimumMemoryBytes:metadata:)` at `Sources/SwiftAcervo/ComponentDescriptor.swift:122`) the download honors `descriptor.files` exactly — R1 is HONORED for the hydrated registration path.

**Existing test coverage:** `Tests/SwiftAcervoTests/ComponentDownloadTests.swift` and `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift` test the hydrated registration path only, always using a unique `repoId` per component. No existing test exercises two components with the same `repoId` and different file subsets.

**Verdict:** GAP — for un-hydrated bundle descriptors. HONORED for pre-hydrated bundle descriptors (explicit `files:` at registration).

---

## R2 — withComponentAccess exposes declared files with subfolder layout

**Code trace:**

`AcervoManager.withComponentAccess(_:in:perform:)` (`Sources/SwiftAcervo/AcervoManager.swift:455`) resolves the component directory as:
```swift
let componentDir = baseDirectory.appendingPathComponent(Acervo.slugify(descriptor.repoId))
```
(`Sources/SwiftAcervo/AcervoManager.swift:466`)

It then checks that every file in `descriptor.files` exists on disk (`Sources/SwiftAcervo/AcervoManager.swift:472–477`) and verifies checksums for files that have them (`Sources/SwiftAcervo/AcervoManager.swift:480–491`). Both loops iterate `descriptor.files` exclusively — not the manifest.

The `ComponentHandle` is constructed with `baseDirectory: componentDir` (`Sources/SwiftAcervo/AcervoManager.swift:501–504`). Within the handle:
- `url(for:)` appends the relative path to `baseDirectory` (`Sources/SwiftAcervo/ComponentHandle.swift:72`).
- `url(matching:)` searches only `descriptor.files` (`Sources/SwiftAcervo/ComponentHandle.swift:93`).
- `urls(matching:)` filters only `descriptor.files` (`Sources/SwiftAcervo/ComponentHandle.swift:113`).
- `availableFiles()` maps `descriptor.files` (`Sources/SwiftAcervo/ComponentHandle.swift:131–137`).

All resolution is relative to `componentDir` (the slug directory), and subfolder paths are preserved because `url(for: "transformer/model.safetensors")` appends the path component-by-component. No flattening occurs.

The handle cannot access sibling files (files in the slug directory belonging to other descriptors) unless those files happen to be in `descriptor.files`. The handle does NOT expose an escape hatch to the raw slug directory for file enumeration — only `rootDirectoryURL` (`Sources/SwiftAcervo/ComponentHandle.swift:47`) points to the shared slug directory, which IS a potential over-exposure if consumers iterate it (not guarded).

**Existing test coverage:** `Tests/SwiftAcervoTests/ComponentHandleTests.swift` tests `url(for:)`, `url(matching:)`, `urls(matching:)`, and `availableFiles()` for subdirectory paths (`Sources/SwiftAcervo/ComponentHandle.swift:33–39`). `Tests/SwiftAcervoTests/ComponentAccessTests.swift` and `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift` test `withComponentAccess`. No test verifies that sibling files (not in `descriptor.files`) cannot be accessed, or that `rootDirectoryURL` does not expose them.

**Verdict:** HONORED — the handle exposes only declared files via the access methods, and subfolder structure is preserved. The `rootDirectoryURL` escape hatch is a documentation concern (not a contract violation), as it is not an access method.

---

## R3 — isComponentReady checks declared files only

**Code trace:**

`Acervo.isComponentReady(_:in:)` (`Sources/SwiftAcervo/Acervo.swift:1259`) iterates exclusively over `descriptor.files`:
```swift
for file in descriptor.files {
    let filePath = componentDir.appendingPathComponent(file.relativePath).path
    guard fm.fileExists(atPath: filePath) else { return false }
    if let expectedSize = file.expectedSizeBytes { ... }
}
return true
```
No directory scan, no manifest fetch. If a file in `descriptor.files` is present and correct, it is counted as ready regardless of what other files exist in the slug directory.

The function returns `false` for un-hydrated descriptors (`descriptor.isHydrated == false`) at `Sources/SwiftAcervo/Acervo.swift:1264–1267`, which is the safe default.

For a bundle component where sibling files exist on disk (e.g., transformer files present because another component was ensured first), `isComponentReady` will check only the component's own declared files and return `true` iff they are all present — sibling files are irrelevant.

**Existing test coverage:** `Tests/SwiftAcervoTests/ComponentDownloadTests.swift` and `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift` have `isComponentReady` tests, but none test the shared-repoId scenario. No test verifies that sibling files on disk do not affect the result.

**Verdict:** HONORED — `isComponentReady` is correctly scoped to `descriptor.files` only. No existing test pins this behavior for the bundle shape.

---

## R4 — deleteComponent removes declared files only (sibling-safe)

**Code trace:**

`Acervo.deleteComponent(_:in:)` (`Sources/SwiftAcervo/Acervo.swift:1827`) removes the **entire slug directory**:
```swift
let componentDir = baseDirectory.appendingPathComponent(slugify(descriptor.repoId))
// ...
try FileManager.default.removeItem(at: componentDir)  // line 1842
```

This is the most critical gap. For a bundle shape where components A, B, and C all share `repoId = "black-forest-labs/FLUX.2-klein-4B"`, calling `deleteComponent("bundle-transformer")` removes the entire `black-forest-labs_FLUX.2-klein-4B/` directory — destroying all files for components B and C as well.

This directly violates R4: "Does NOT remove files belonging to sibling components (other descriptors with same `repoId` but different `id`)."

The existing `deleteComponent` logic was designed when the invariant was "one component = one directory." The bundle shape breaks that invariant.

**Existing test coverage:** `Tests/SwiftAcervoTests/ComponentDownloadTests.swift:199–223` tests `deleteComponent` but registers each component with a unique `repoId`, so the slug directory and the component's files are identical — the whole-directory removal is correct in that scenario and the gap is invisible. No test registers two components against the same `repoId` and verifies that deleting one leaves the other's files intact.

**Verdict:** GAP — `deleteComponent` removes the entire `org_repo/` directory, not just the declared files. This breaks every sibling component when any one component is deleted.

---

## R5 — fetchManifest(forComponent:) returns full manifest

**Code trace:**

`Acervo.fetchManifest(forComponent:session:)` (`Sources/SwiftAcervo/Acervo.swift:1525–1533`):
```swift
guard let descriptor = ComponentRegistry.shared.component(componentId) else {
    throw AcervoError.componentNotRegistered(componentId)
}
return try await fetchManifest(for: descriptor.repoId, session: session)
```

It looks up the descriptor's `repoId` and delegates to `fetchManifest(for:session:)` (`Sources/SwiftAcervo/Acervo.swift:1502`), which calls `AcervoDownloader.downloadManifest(for:session:)` (`Sources/SwiftAcervo/AcervoDownloader.swift:211`). That function downloads, decodes, and validates the full manifest with no file filtering.

The returned `CDNManifest` contains all files in the CDN repo regardless of which subset the component declared. This is the correct and desired behavior per R5.

**Existing test coverage:** `Tests/SwiftAcervoTests/ManifestFetchTests.swift` tests the `fetchManifest(for:)` path. The component-keyed variant `fetchManifest(forComponent:)` is tested implicitly via hydration tests. No test explicitly verifies that a bundle component's `fetchManifest` returns files belonging to sibling components.

**Verdict:** HONORED — `fetchManifest(forComponent:)` fetches the full CDN manifest unchanged, making no attempt to filter by declared files.

---

## R6 — Re-register canary distinguishes id-collision from sibling-registration

**Code trace:**

`ComponentRegistry.register(_:)` (`Sources/SwiftAcervo/ComponentRegistry.swift:44`) triggers the stderr warning when two conditions are met for the same `id`:
```swift
let sameRepo = existing.repoId == descriptor.repoId
let sameFiles = existing.files == descriptor.files
if !sameRepo || !sameFiles {
    // Log warning to stderr
}
```
(`Sources/SwiftAcervo/ComponentRegistry.swift:64–71`)

**Registering different IDs against the same repoId:** Each new `id` is a new key in `descriptors: [String: ComponentDescriptor]`. The code path for a new key goes to the `else` branch at `Sources/SwiftAcervo/ComponentRegistry.swift:95`, which stores the descriptor directly with no warning. This correctly does NOT fire the canary for distinct IDs sharing a `repoId`. R6 (sibling-safe registration) is HONORED.

**Registering the same `id` twice with different files:** Triggers the `!sameFiles` branch at `Sources/SwiftAcervo/ComponentRegistry.swift:66`, which fires the warning. R6 (id-collision canary) is HONORED.

**Registering the same `id` twice with identical descriptor:** The idempotent short-circuit at `Sources/SwiftAcervo/ComponentRegistry.swift:52–62` exits early (no warning). The `manifest-destiny-01` idempotent short-circuit is intact.

**Existing test coverage:** `Tests/SwiftAcervoTests/ComponentRegistryTests.swift` tests `deduplicateSameRepoAndFiles` (silent) and `deduplicateDifferentRepo` (which triggers the warning path, tested for structural outcome but not for the stderr emission). No test explicitly captures stderr to assert the warning fires for the id-collision case, nor does any test assert it does NOT fire for N distinct IDs sharing a `repoId`.

**Verdict:** HONORED — the canary logic correctly keys on `id` and fires only for genuine id-collisions with changed descriptor content. Sibling registration (different `id`, same `repoId`) never fires the canary. However, no test pins the "sibling does not fire" side of R6.

---

## Resolutions

### Q1

**deleteComponent for shared files: refuse-if-shared vs delete-declared-only**

**Recommendation: delete declared files only.**

The current implementation (`Sources/SwiftAcervo/Acervo.swift:1841–1842`) removes the entire slug directory. For the bundle shape, this must change to iterate `descriptor.files` and remove each file individually, then optionally remove the slug directory only if it is now empty (no files remain).

Refusing deletion if another registered component shares the `repoId` (referential-integrity approach) is operationally unpleasant: it would prevent users from freeing storage for one component unless they first unregister all siblings. It also couples deletion to registry state in a way that makes offline cleanup impossible. The "delete declared files only" approach is consistent with R4, is what the requirements state, and does not break sibling components that happen to be in the same directory.

**Concrete implementation sketch:**
```swift
// Iterate declared files and remove each one
for file in descriptor.files {
    let fileURL = componentDir.appendingPathComponent(file.relativePath)
    if fm.fileExists(atPath: fileURL.path) {
        try fm.removeItem(at: fileURL)
    }
}
// Optionally remove slug dir if now empty
if let contents = try? fm.contentsOfDirectory(atPath: componentDir.path),
   contents.isEmpty {
    try? fm.removeItem(at: componentDir)
}
```
This is the change Sortie 5 must make to fix R4.

### Q2

**diskSize(forComponent:): declared-files-only vs whole-directory**

`Acervo.diskSize(forComponent:)` does not exist in the codebase at `1ec90e7`. The function is mentioned in the requirements as something to audit, but there is no implementation to trace. 

**Recommendation: When implemented, it should report declared-files-only.** This aligns with R3 (readiness checks declared files only), makes each component's reported size independent of siblings, and avoids double-counting when multiple components share a manifest. Implementation should sum actual on-disk sizes (via `FileManager.attributesOfItem`) for `descriptor.files`, not compute the size of the slug directory as a whole. This function is not in scope for Sortie 5 unless Sortie 2–4 tests require it — it is a follow-on API to add cleanly.

### Q3

**ensureComponentReady when sibling already ready: re-verify checksums vs short-circuit**

The current implementation (`Sources/SwiftAcervo/Acervo.swift:1756–1758`) short-circuits via `isComponentReady`, which checks file presence and optional size but does NOT re-verify SHA-256 checksums of existing files (`Sources/SwiftAcervo/Acervo.swift:1259–1289`). SHA-256 verification happens only during `downloadComponent` (via the streaming download path or the post-download registry-level check at `Sources/SwiftAcervo/Acervo.swift:1702–1714`).

**Recommendation: Preserve the current short-circuit behavior.** Re-verifying checksums on every `ensureComponentReady` call would be expensive for large models (multi-GB safetensors) and is not required for correctness — the files were verified when first downloaded. The right time to re-verify is `verifyComponent`, which is already available. If a sibling component's download wrote shared files that this component also declared, those files passed integrity checks at download time. The short-circuit is appropriate.

The potential edge case — a file appearing on disk because a sibling downloaded it but with incorrect content (e.g., different manifest version) — is addressed by the fact that `AcervoDownloader.downloadFiles` validates each file against the manifest's SHA-256 at download time. So any file already on disk and passing the `isComponentReady` size check was validly downloaded.

### Q4

**Patch vs minor version bump**

This question is reserved for Sortie 5's outcome, which will determine whether source changes are needed. Based on this audit, at least two gaps (R1 for un-hydrated bundle descriptors, R4 for `deleteComponent`) require non-trivial source edits. This indicates a **minor version bump** is likely warranted. Final decision deferred to Sortie 5 per EXECUTION_PLAN.md.

### Q5

**BundleComponentDescriptor convenience init — recommend defer or add**

**Recommendation: Defer.**

The explicit `ComponentDescriptor.init(id:type:displayName:repoId:files:estimatedSizeBytes:minimumMemoryBytes:metadata:)` at `Sources/SwiftAcervo/ComponentDescriptor.swift:122` is ergonomic enough for bundle declarations. A plugin author writing `Flux2KleinDescriptor` declares three descriptors with different `files:` lists, each pointing at the same `repoId`. This is straightforward and requires no convenience wrapper.

A `BundleComponentDescriptor(repoId:subfolder:)` convenience init that auto-derives the file list from the CDN manifest would require a network fetch at registration time (undesirable — registration is synchronous and offline-capable) or would need to be async (breaking the simple `Acervo.register` pattern). Neither tradeoff is worth it for the current unblock goal. Revisit only if downstream consumers demonstrate the explicit form is a genuine pain point.

---

## Summary table

| Requirement | Verdict | Existing test coverage | Gap to fix in Sortie 5 |
|-------------|---------|------------------------|------------------------|
| R1 | GAP | No bundle-shape test; single-repo tests pass | `performHydration` (`Acervo.swift:1611`) overwrites declared files with all manifest files for un-hydrated descriptors. Hydrated (explicit-files) descriptors are already correct. Fix: hydration must not replace a declared file subset for bundle components. |
| R2 | HONORED | `ComponentHandleTests.swift` covers subdirectory paths; no sibling-scope test | No code fix needed. Consider adding a documentation note about `rootDirectoryURL` exposing the shared slug dir. |
| R3 | HONORED | Single-repo tests only | No code fix needed. Add bundle-shape test to pin the behavior. |
| R4 | GAP | Single-repo tests only; whole-dir delete passes trivially | `deleteComponent` (`Acervo.swift:1841`) removes entire slug directory. Fix: iterate `descriptor.files` and remove declared files only. |
| R5 | HONORED | Manifest fetch tests pass | No code fix needed. Add bundle-component test to confirm full manifest is returned. |
| R6 | HONORED | Structural dedup tested; no stderr capture for canary | No code fix needed. Add tests: (a) sibling registration does not fire warning; (b) id-collision with different files fires warning; (c) idempotent re-registration is silent. |

---

## Test results

### Sortie 4 test run — 2026-05-06

**Total test suite**: 537 tests in 62 suites. **6 failures** — all 6 are intentional R4 failures that pin the *intended* behavior against the current (broken) source. No regressions in pre-existing tests.

#### R4 failures (expected — Sortie 5 must fix)

These tests assert the intended behavior of `deleteComponent` (declared-files-only removal, sibling-safe). Current source at `Acervo.swift:1842` removes the entire slug directory, causing all sibling files to be destroyed.

| Test method | Failing assertion | Root cause |
|-------------|-------------------|------------|
| `testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings` | `fileExists("text_encoder/config.json", ...)` — expected true, got false | `deleteComponent("bundle-transformer")` removes entire `test-bundle-org_flux-style-bundle/` dir |
| `testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings` | `fileExists("text_encoder/model.safetensors", ...)` — expected true, got false | same root cause |
| `testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings` | `fileExists("vae/config.json", ...)` — expected true, got false | same root cause |
| `testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings` | `fileExists("vae/diffusion_pytorch_model.safetensors", ...)` — expected true, got false | same root cause |
| `testDeleteComponent_R4_SiblingComponentsRemainReadyAfterPartialDelete` | `isComponentReady("bundle-text-encoder", ...) == true` — got false | slug dir already removed; files absent |
| `testDeleteComponent_R4_SiblingComponentsRemainReadyAfterPartialDelete` | `isComponentReady("bundle-vae", ...) == true` — got false | slug dir already removed; files absent |

**`testDeleteComponent_R4_SlugDirRemovedAfterAllComponentsDeleted`**: PASSED (trivially — current source removes the slug dir on the first delete call, so the post-delete check that the dir is absent or empty passes immediately; this does not indicate correctness).

**Sortie 5 fix**: `Acervo.swift` `deleteComponent(_:in:)` must iterate `descriptor.files` and remove each declared file individually, then remove the slug directory only if it is empty. The exact implementation sketch is in Q1 above.

#### R6 results (all PASSED)

The canary uses `FileHandle.standardError.write(...)` at `ComponentRegistry.swift:70`. Tests observe it via `dup2` + `Pipe` (same pattern as `HydrationTests.swift:209–244`), wrapped in the file-private `BundleStderrCapture.capturing {}` helper added to `BundleComponentTests.swift`.

| Test method | Result | What it proved |
|-------------|--------|----------------|
| `testReregisterCanary_R6_DoesNotFireForSiblingComponents` | PASSED | Registering 3 distinct IDs against same `repoId` emits nothing to stderr — sibling registration is always silent |
| `testReregisterCanary_R6_FiresOnSameIdDifferentFiles` | PASSED | Re-registering same ID with a different `files` list emits the `[SwiftAcervo] Warning: re-registering component` message |
| `testReregisterCanary_R6_DoesNotFireForIdenticalDescriptor` | PASSED | Re-registering the same ID with an identical descriptor hits the idempotent short-circuit (lines 52–62) and emits nothing |

#### R2, R3, R5 results (from Sortie 3)

All 5 R2/R3/R5 tests that were added by Sorties 2 and 3 continue to PASS (confirmed: no regressions).

#### Sortie 5 action items

1. **Fix R4 (HIGH SEVERITY)**: Change `deleteComponent(_:in:)` at `Acervo.swift:1827–1843` to iterate `descriptor.files` and remove each file individually, then remove the slug dir if empty. Test `testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings` and `testDeleteComponent_R4_SiblingComponentsRemainReadyAfterPartialDelete` will turn green. `testDeleteComponent_R4_SlugDirRemovedAfterAllComponentsDeleted` will remain green (it will now test the proper sequence rather than the trivial case).
2. **No R6 fix needed**: All R6 tests pass against current source. R6 is fully HONORED.
3. **Confirm R1 gap**: The Sortie 2 R1 tests exercise the pre-hydrated path only (they pass). The un-hydrated path gap (noted in Sortie 1 audit) has no failing test yet — Sortie 5 must decide whether to add one or defer.
4. **Version bump**: At least R4 is a non-trivial fix → minor version bump is warranted (per Q4 resolution).

---

## Sortie 5 outcome

**Executed**: 2026-05-06

### R4 fix — IMPLEMENTED

`Acervo.swift` `deleteComponent(_:in:)` (lines 1827–1843) was replaced with a per-file delete loop. The new implementation:

1. Iterates `descriptor.files` and removes each declared file individually via `try? fm.removeItem(at:)` (missing files are silently ignored — never-downloaded or already-deleted files are a no-op, not an error).
2. After each file removal, walks up the directory tree from the file's parent directory to (but not including) the slug directory, pruning any directory that is now empty. This handles subfolder cleanup (e.g., `transformer/` becomes empty after its only file is removed).
3. After all declared files are removed, removes the slug directory itself if it is now empty (all bundle components have been deleted).

This change is strictly confined to the body of `deleteComponent(_:in:)`. No public types were added, no method signatures changed, and no surrounding code was touched.

### R1 gap — DOCUMENTED (option a)

The un-hydrated bundle descriptor path in `performHydration` (`Acervo.swift:1611`) replaces `files` with the full manifest. This is intentional and correct for single-component manifests; it is a misuse for bundle components (which must always use the pre-hydrated `files:` initializer). No test exercises this path in a failing way.

Option (b) was evaluated: `descriptor.isHydrated` exists as a public property, but a guard in `performHydration` would be unsafe — `performHydration` is only called when `needsHydration` is true (i.e., the descriptor is un-hydrated), so a guard on `isHydrated` would be a dead-code no-op. The real issue is that callers should never pass a bundle descriptor to the un-hydrated registration path. Option (a) (documentation only) is the correct and sufficient response.

Two documentation changes were applied:
- A `NOTE:` comment added in `performHydration` at `Acervo.swift:1611` explaining why hydration overwrites `files` and why bundle descriptors must not use the un-hydrated path.
- A **Bundle pattern** doc-comment section added to `ComponentDescriptor.init(id:type:displayName:repoId:files:estimatedSizeBytes:minimumMemoryBytes:metadata:)` in `ComponentDescriptor.swift` (lines 122+) stating that bundle descriptors must always use this initializer, and explaining the consequence of leaving them un-hydrated.

### make test outcome

**537 tests in 62 suites — ALL PASSED. Exit code 0. Zero failures.**

Previously failing R4 tests now pass:
- `testDeleteComponent_R4_RemovesDeclaredFilesAndPreservesSiblings` — PASS
- `testDeleteComponent_R4_SiblingComponentsRemainReadyAfterPartialDelete` — PASS
- `testDeleteComponent_R4_SlugDirRemovedAfterAllComponentsDeleted` — PASS (now tests real behavior, not the trivial whole-dir-remove shortcut)

Per-requirement pass status:
- **R1**: 2 tests — PASS (pre-hydrated path honored; un-hydrated gap documented not fixed)
- **R2**: 2 tests — PASS
- **R3**: 2 tests — PASS
- **R4**: 3 tests — PASS (was 3 failures before this sortie)
- **R5**: 1 test — PASS
- **R6**: 3 tests — PASS

### Version bump recommendation

**Minor version bump** (e.g., 0.11.1 → 0.12.0). The R4 fix is a non-trivial behavioral change to `deleteComponent`: the old implementation removed the entire slug directory; the new implementation removes only declared files. Although the change is additive in the sense that it adds correct behavior, the semantic of `deleteComponent` changes observably for the bundle shape. Per Q4 resolution in this document, a minor bump is warranted whenever a non-trivial source change is required. Sortie 6 should update `CHANGELOG.md` framing this as a behavioral fix for the bundle component shape, marked as a non-breaking behavioral refinement.

### Files modified in Sources/

- `Sources/SwiftAcervo/Acervo.swift`: R4 fix in `deleteComponent(_:in:)` + R1 NOTE comment in `performHydration`.
- `Sources/SwiftAcervo/ComponentDescriptor.swift`: Bundle pattern doc-comment on the `files:` initializer.

No new public types. No method signature changes. Tests/ untouched.

---

## Sortie 7 outcome

**Executed**: 2026-05-06

### Smoke test added

`Tests/SwiftAcervoTests/BundleComponentSmokeTests.swift` was created. It is gated behind the canonical `INTEGRATION_TESTS` environment variable (matching the convention in `IntegrationTests.swift` and `ModelDownloadManagerTests.swift`). When `INTEGRATION_TESTS` is unset, the test returns immediately (passes in 0.001 s with no assertions).

### Requirements exercised (against real CDN)

| Requirement | Assertion |
|-------------|-----------|
| R1 | `ensureComponentReady` downloads only declared files; transformer and vae safetensors are absent |
| R2 | `text_encoder/config.json` lands at `<slug>/text_encoder/config.json` (subfolder preserved) |
| R3 | `isComponentReady` returns true for both components after download |
| R4 | `deleteComponent("smoke-text-encoder")` removes `text_encoder/config.json` but leaves `tokenizer_config.json` intact |

### File selection

| Component | File | Rationale |
|-----------|------|-----------|
| `smoke-text-encoder` | `text_encoder/config.json` | Small JSON config (< 5 KB); exercises subfolder-preserving path layout |
| `smoke-tokenizer` | `tokenizer_config.json` | Root-level tokenizer config (< 5 KB); standard HF model file |

Both files are JSON configs, not safetensors weights. Total download is well under 1 MB.

### CI behaviour (INTEGRATION_TESTS unset)

`make test` exits 0. The smoke test passes trivially (returns immediately). No network access. No files written to disk.

**`make test` result (without env var)**: 606 tests in 70 suites — ALL PASSED. Exit code 0.

### Live-run command (operator-attested)

Run the following to execute the smoke test against the real CDN. Replace the app-group ID with any valid group your developer certificate covers (or use the env-var form shown below, which bypasses the entitlement requirement for CLI/test runners):

```bash
INTEGRATION_TESTS=1 \
ACERVO_APP_GROUP_ID=group.dev.com.example.acervo \
xcodebuild test \
  -scheme SwiftAcervo-Package \
  -destination 'platform=macOS,arch=arm64' \
  2>&1 | grep -iE "smoke|BundleComponentSmoke|PASS|FAIL|error:"
```

Or, using `make test` with grep:

```bash
INTEGRATION_TESTS=1 \
ACERVO_APP_GROUP_ID=group.dev.com.example.acervo \
make test 2>&1 | grep -iE "smoke|BundleComponentSmoke"
```

### Expected live-run outcome

The test connects to `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/black-forest-labs_FLUX.2-klein-4B/manifest.json`, downloads two small JSON files, verifies subfolder paths and file content, deletes one component, and asserts sibling safety. Expected result: **PASS**.

### Files written to disk on success

```
~/Library/Group Containers/<ACERVO_APP_GROUP_ID>/SharedModels/
└── black-forest-labs_FLUX.2-klein-4B/
    ├── text_encoder/
    │   └── config.json        (smoke-text-encoder component — DELETED at end of test)
    └── tokenizer_config.json  (smoke-tokenizer component — remains after partial delete,
                                then removed by defer cleanup)
```

### Cleanup behaviour

The smoke test uses a `defer { try? FileManager.default.removeItem(at: slugDir) }` block inside `withIsolatedSharedModelsDirectoryAsync`. On both success and failure:

1. The entire `black-forest-labs_FLUX.2-klein-4B/` slug directory is removed from the isolated Group Containers path.
2. `withIsolatedSharedModelsDirectoryAsync` then removes the per-test Group Containers root directory.

No files are left in the developer's group container after the test completes. The test is re-runnable.

### App-group dependency

The smoke test (like all integration tests) requires either:

- An `ACERVO_APP_GROUP_ID` environment variable set to a group identifier the test process can access, OR
- A `com.apple.security.application-groups` entitlement covering the group ID (UI app targets only).

For command-line / `make test` runs, set `ACERVO_APP_GROUP_ID` explicitly. `Acervo.sharedModelsDirectory` will `fatalError` if neither source is configured.
