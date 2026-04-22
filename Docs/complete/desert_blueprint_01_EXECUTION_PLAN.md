---
feature_name: OPERATION DESERT BLUEPRINT
starting_point_commit: 78f72a9d6354c5bfafd601b4c52da191bf2d6ea4
mission_branch: mission/desert-blueprint/01
iteration: 1
---

# EXECUTION_PLAN.md — SwiftAcervo Manifest-Driven Component Registration (v0.8.0)

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Summary

**Goal**: Eliminate the duplicated `files:` list that every consumer of SwiftAcervo currently hardcodes in `ComponentDescriptor`. The CDN manifest is the source of truth. SwiftAcervo should fetch it on first use and populate the descriptor itself.

**Source**: `docs/complete/hydration_todo.md` (archived 2026-04-22 — this plan supersedes it)

**Baseline state verified 2026-04-22**: zero items implemented. Codebase at v0.7.3 — `ComponentDescriptor.files` is required, `AcervoDownloader.downloadManifest` is internal and uses a non-injectable `SecureDownloadSession.shared`, no hydration API exists, **no URLProtocol / URLSession mock infrastructure exists in the test suite**.

**Target version**: v0.8.0 (semver minor bump — new public API, no removals).

**Prior mission on this repo**: Operation Swift Ascendant (ModelDownloadManager, shipped in commit `eafa03f`, 2026-04-18). Archived to `docs/complete/swift_ascendant_01_*.md`.

---

## ⚠️ Blockers — Confirm Before Execution

These three decisions from TODO.md § "Open Decisions" shape the API surface and test expectations. Defaults reflect the TODO's own recommendations; the user can override before `/mission-supervisor start`.

### Blocker 1: Hydration semantics on a partially-declared descriptor — **LOCKED: Replace with warning log** (user confirmed 2026-04-22)

When a consumer's declared `files:` list drifts from the CDN manifest, hydration overwrites the declared list with the manifest contents and emits a warning log line: `"Manifest drift detected for \(componentId): declared N files, manifest has M files. Using manifest."` The CDN is authoritative for sha256 checksums, sizes, file membership, and redirect policy; making files another CDN-authoritative property is consistent with existing library behavior. Consumers who want pinning should pin the CDN version, not the file list.

Rejected alternatives: Merge (creates sha256 tiebreaker ambiguity that silently masks drift); Error (makes every CDN manifest update break existing consumers — defeats the mission's purpose).

### Blocker 2: Disk caching for v0.8.0 — **LOCKED: Ship without caching** (user confirmed 2026-04-22)

Every `ensureComponentReady` call fetches the manifest fresh. Adds one HTTP round-trip per startup; no cache-invalidation complexity. **Sortie 7 is skipped** (supervisor marks as `COMPLETED` with note "deferred per Blocker 2 decision").

### Blocker 3: Naming — **LOCKED: `hydrateComponent(_:)`** (user confirmed 2026-04-22)

Implies stateful lifecycle (dehydrated → hydrated). Consistent with the `isHydrated` state property.

**Remaining open**: Blocker 1 only.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| SwiftAcervo | `/Users/stovak/Projects/SwiftAcervo` | 8 | multi (see below) | none |

Single work unit; sorties are layered by dependency.

---

## Sortie Dependency Graph

```
Layer 1:  Sortie 1 (Descriptor API) ──► Sortie 2 (Public manifest + URLSession injection)
                                                ↓
Layer 2:                        Sortie 3 (hydrateComponent + single-flight)
                                                ↓
Layer 3:  Sortie 4 (Auto-hydrate plumbing)  Sortie 5 (Catalog introspection)  [sequential, shared file]
                                                ↓
Layer 4:                              Sortie 6 (7 canonical tests)
                                                ↓
Layer 5:  Sortie 7 (Disk caching — SKIPPED if Blocker 2 = "ship without")
                                                ↓
Layer 6:                     Sortie 8 (Version bump + docs + migration notes)
```

**Note on "parallel" layers** — Layer 1 (Sorties 1 & 2) and Layer 3 (Sorties 4 & 5) were initially modeled as parallelizable. Pass 3 analysis (see Parallelism Structure below) found that both layers touch the same central file (`Sources/SwiftAcervo/Acervo.swift`) and so must execute sequentially. The arrows above reflect the serialized order.

---

### Sortie 1: ComponentDescriptor API — optional files + hydration state

**Priority**: 22 — blocks 6 downstream sorties, defines foundational types, low-risk type edit. Runs first.

**Entry criteria**:
- [ ] First sortie — no prerequisites, but Blocker 1 and Blocker 3 resolved.
- [ ] `make build` passes from a clean tree (`cd /Users/stovak/Projects/SwiftAcervo && make build`).

**Tasks**:
1. In `Sources/SwiftAcervo/ComponentDescriptor.swift`: add a secondary `init` that omits `files` and `estimatedSizeBytes`. Existing init stays as-is (backwards-compat escape hatch).
2. Change internal storage of `files` to `[ComponentFile]?` (or introduce `private enum DescriptorShape { case declared([ComponentFile]); case hydrateFromManifest }`). Pick whichever the sortie agent judges simpler to maintain; document the decision in a code comment on the type.
3. Add `public var isHydrated: Bool { get }` — `true` iff declared-mode OR manifest-backed file list has been populated.
4. Add `public var needsHydration: Bool { get }` — inverse, used by internal auto-hydrate path.
5. In `Sources/SwiftAcervo/AcervoError.swift`: add `case componentNotHydrated(id: String)` with a descriptive `errorDescription`.
6. Wire up existing call sites — `downloadComponent`, `ensureComponentReady`, `isComponentReady`, `verifyComponent` in `Sources/SwiftAcervo/Acervo.swift` currently read `descriptor.files`. For this sortie, make them guard on `isHydrated` and throw `AcervoError.componentNotHydrated(id:)` if not. They will be rewired to auto-hydrate in Sortie 4. Add a `// TODO(Sortie 4): auto-hydrate here` marker on each.

**Exit criteria**:
- [ ] `make build` succeeds with zero new warnings (compare against pre-edit `make build 2>&1 | grep -c warning`).
- [ ] `make test` passes — existing tests that use the original `ComponentDescriptor.init(files:...)` continue to work unchanged.
- [ ] In `Tests/SwiftAcervoTests/ComponentDescriptorTests.swift` (new or existing), a test asserts: `ComponentDescriptor(id: "test/bare", type: .backbone, displayName: "Bare", repoId: "test/bare", minimumMemoryBytes: 0).isHydrated == false` and `.needsHydration == true`.
- [ ] A test asserts: a descriptor built with the original init (providing `files:`) has `isHydrated == true`.
- [ ] `grep -n "case componentNotHydrated" Sources/SwiftAcervo/AcervoError.swift` returns a match.
- [ ] `grep -n "TODO(Sortie 4)" Sources/SwiftAcervo/Acervo.swift | wc -l` returns `4`.

---

### Sortie 2: Public manifest access + URLSession injection

**Priority**: 22.5 — tied for top priority with Sortie 1, blocks 6 downstream sorties, adds foundational testability infrastructure. Runs immediately after Sortie 1.

**⚠️ Scope expanded in Pass 1**: The original sortie exposed `downloadManifest` publicly. Pass 1 found that Sortie 3's concurrent-hydration test and Sortie 6's four CDN-response tests require a mockable URLSession, and none exists today. The mock harness and URLSession injection are added here so the precondition for Sorties 3, 6, 7 is satisfied by the time Layer 2 starts.

**Entry criteria**:
- [ ] Sortie 1 exit criteria met.
- [ ] `make build` passes from a clean tree.

**Tasks**:
1. In `Sources/SwiftAcervo/AcervoDownloader.swift`: change `static func downloadManifest(for modelId: String) async throws -> CDNManifest` to `public static func downloadManifest(...)`. Its current shape (validates version, id, checksum-of-checksums) is correct — do not change behavior.
2. Add a URLSession injection point. Modify the signature to `public static func downloadManifest(for modelId: String, session: URLSession = SecureDownloadSession.shared) async throws -> CDNManifest` and replace the internal `SecureDownloadSession.shared.data(for: request)` call with `session.data(for: request)`. Default preserves existing behavior for every current caller.
3. In `Sources/SwiftAcervo/Acervo.swift`: add a public wrapper `public static func fetchManifest(for componentId: String) async throws -> CDNManifest` that delegates to `AcervoDownloader.downloadManifest(for: componentId)` (omitting the session parameter, so production callers hit the real CDN). Wrapper is the documented public entry point.
4. Add a doc comment on `fetchManifest`: "Returns the CDN manifest for the given component without hydrating the registry. Use this for custom catalogs, cache warmers, or CI verification tools that need manifest data but don't want to trigger downloads."
5. Create `Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` (create the `Support/` subdirectory). Implement a standard `URLProtocol` subclass with:
   - A static registry: `static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?`
   - A request counter: `static private(set) var requestCount: Int`
   - A reset helper: `static func reset()`
   - Thread-safe access (use a lock).
   - A factory helper `static func session() -> URLSession` that returns a `URLSession(configuration:)` with `MockURLProtocol.self` registered.
6. Ensure `MockURLProtocol` is testable via a smoke test in a new file `Tests/SwiftAcervoTests/MockURLProtocolTests.swift` — register a stub responder, issue one GET via the mock session, assert `requestCount == 1` and the response body matches.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `grep -n "public static func downloadManifest" Sources/SwiftAcervo/AcervoDownloader.swift` returns a match.
- [ ] `grep -n "public static func fetchManifest" Sources/SwiftAcervo/Acervo.swift` returns a match.
- [ ] `test -f Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` succeeds.
- [ ] A new test `Tests/SwiftAcervoTests/ManifestFetchTests.swift` calls `Acervo.fetchManifest(for: "test/fixture")` against a `MockURLProtocol`-stubbed session and asserts the returned `CDNManifest` parses cleanly and has `modelId == "test/fixture"`. (The test supplies a locally-constructed manifest fixture; no network I/O.)
- [ ] `make test` passes including `MockURLProtocolTests` and `ManifestFetchTests`.

---

### Sortie 3: `hydrateComponent` implementation

**Priority**: 21.5 — blocks 5 downstream sorties, is the core API of the mission, involves concurrency correctness (single-flight).

**Entry criteria**:
- [ ] Sortie 1 exit criteria met (ComponentDescriptor optional files + isHydrated).
- [ ] Sortie 2 exit criteria met (public manifest fetch + `MockURLProtocol` available).

**Tasks**:
1. In `Sources/SwiftAcervo/Acervo.swift`: implement `public static func hydrateComponent(_ componentId: String) async throws`.
2. Flow: look up descriptor in `ComponentRegistry.shared`; if missing throw `AcervoError.componentNotRegistered`; fetch manifest via `Acervo.fetchManifest`; map `CDNManifestFile → ComponentFile(relativePath: f.path, expectedSizeBytes: f.sizeBytes, sha256: f.sha256)`; rebuild descriptor with populated files and `estimatedSizeBytes = sum(file.sizeBytes)`; store the hydrated descriptor in the registry (see task 6 for the storage mechanism).
3. Apply **Blocker 1 decision**. Default (replace): on drift between declared and manifest, emit a log warning `"Manifest drift detected for \(componentId): declared N files, manifest has M files. Using manifest."` and use the manifest list.
4. **Single-flight guarantee**: ensure concurrent calls for the same `componentId` coalesce into one network fetch. Implement via an internal actor keyed by componentId that maps `componentId → Task<Void, Error>`. If a Task for the same id is in-flight, await its result instead of starting a new fetch. Two `ensureComponentReady` tasks racing must not produce two HTTP GETs.
5. Idempotent: a second call (after the first completes) re-fetches and replaces the stored file list (picks up CDN-side manifest updates between app launches).
6. **Registry merge resolution**: `ComponentRegistry.register(_:)` currently merges `files` by path and takes `max` of `estimatedSizeBytes` (see `Sources/SwiftAcervo/ComponentRegistry.swift:44-92`). This conflicts with the Replace semantics of Blocker 1. Add a new internal method `ComponentRegistry.replace(_:)` that overwrites the stored descriptor wholesale, and call it from `hydrateComponent`. Do NOT modify the existing `register(_:)` behavior — existing consumers rely on its merge semantics.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] New test file `Tests/SwiftAcervoTests/HydrateComponentTests.swift` exists with these assertions, all passing:
  - Register a bare descriptor (no `files:`), stub `MockURLProtocol` to return a known manifest with 3 files, call `hydrateComponent`, assert `ComponentRegistry.shared.component(id)!.isHydrated == true` and file list matches the stubbed manifest (count == 3, paths match).
  - Two `Task { try await hydrateComponent(id) }` dispatched concurrently → stub records exactly one request (`MockURLProtocol.requestCount == 1`) → both tasks complete without error.
  - `hydrateComponent` on a non-registered ID throws `AcervoError.componentNotRegistered`.
- [ ] `grep -n "public static func hydrateComponent" Sources/SwiftAcervo/Acervo.swift` returns a match.
- [ ] `grep -n "func replace" Sources/SwiftAcervo/ComponentRegistry.swift` returns a match.

---

### Sortie 4: Auto-hydrate plumbing

**Priority**: 12 — blocks 3 downstream sorties, rewires 4 call sites, medium risk.

**Entry criteria**:
- [ ] Sortie 3 exit criteria met (hydrateComponent callable and single-flight).

**Tasks**:
1. Rewire `Acervo.ensureComponentReady`: if `descriptor.needsHydration`, call `hydrateComponent` first, then re-read from registry. Remove the `TODO(Sortie 4)` marker.
2. Rewire `Acervo.downloadComponent`: same pattern — hydrate-if-needed before consuming `descriptor.files`. Remove the `TODO(Sortie 4)` marker.
3. `Acervo.verifyComponent`: on un-hydrated descriptor, throw `AcervoError.componentNotHydrated(id:)` — verification has no meaningful answer without a file list. Remove the `TODO(Sortie 4)` marker.
4. `Acervo.isComponentReady(_:)` (sync): return `false` on un-hydrated descriptors. Add a doc comment explaining this is the safe default ("not ready → ask for it"). Remove the `TODO(Sortie 4)` marker. The `API_REFERENCE.md` line for this method gets updated in Sortie 8.
5. Add `public static func isComponentReadyAsync(_:) async throws -> Bool` that hydrates first, then runs the existing readiness check. This is the new recommended path for callers who care about accuracy.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `grep -n "TODO(Sortie 4)" Sources/SwiftAcervo/Acervo.swift | wc -l` returns `0`.
- [ ] `grep -n "public static func isComponentReadyAsync" Sources/SwiftAcervo/Acervo.swift` returns a match.
- [ ] New integration test in `Tests/SwiftAcervoTests/AutoHydrateTests.swift`: register a descriptor with no `files:`, stub the CDN via `MockURLProtocol`, call `ensureComponentReady`, assert (a) files are populated post-call via `ComponentRegistry.shared.component(id)!.isHydrated == true`, (b) the component is downloaded, (c) subsequent `isComponentReady` returns `true`.
- [ ] Existing tests for `ensureComponentReady` with pre-declared descriptors (`ComponentDownloadTests`, `ComponentIntegrationTests`) still pass unchanged — run `make test` and assert zero new failures.
- [ ] Test: `verifyComponent` on an un-hydrated descriptor throws `AcervoError.componentNotHydrated`.

---

### Sortie 5: Catalog introspection hydration-awareness

**Priority**: 10.5 — blocks 3 downstream sorties, touches 2 public methods, low risk.

**Entry criteria**:
- [ ] Sortie 4 exit criteria met. (Sortie 5 depends only on Sortie 3 technically, but runs after Sortie 4 because both touch `Acervo.swift`. See Parallelism Structure.)

**Tasks**:
1. Audit `Acervo.pendingComponents()` (lines ~1154-1168 in `Acervo.swift`) and `Acervo.totalCatalogSize()` (lines ~1176-1201) — both currently read `descriptor.estimatedSizeBytes` and call `isComponentReady`.
2. Apply **Strategy (a) Skip** (default): exclude un-hydrated descriptors from both methods' results. Document in a doc comment on each method: "Un-hydrated components are excluded from this result; their size is unknown until `hydrateComponent` is called. Use `unhydratedComponents()` to enumerate them."
3. Add a new method `public static func unhydratedComponents() -> [String]` — returns component IDs awaiting hydration (`registeredComponents().filter(\.needsHydration).map(\.id)`).

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] `grep -n "public static func unhydratedComponents" Sources/SwiftAcervo/Acervo.swift` returns a match.
- [ ] New test `Tests/SwiftAcervoTests/CatalogHydrationTests.swift`:
  - Register two descriptors: one with `files:` (declared, `estimatedSizeBytes = 100`), one without (`isHydrated == false`).
  - Assert `Acervo.pendingComponents().map(\.id)` contains the declared ID but NOT the un-hydrated ID.
  - Assert `Acervo.totalCatalogSize().pending == 100` (only the declared one counts).
  - Assert `Acervo.unhydratedComponents()` returns exactly `[bareId]`.
- [ ] Doc comment on each modified method contains the string `"Un-hydrated components are excluded"`.

---

### Sortie 6: Test suite — the canonical 7 from TODO.md

**Priority**: 9.5 — blocks 2 downstream sorties, large (7 tests), includes the concurrency test (highest flake risk).

**Entry criteria**:
- [ ] Sorties 1–5 exit criteria all met.
- [ ] `MockURLProtocol` available (from Sortie 2).

**Tasks**: implement the seven tests enumerated in `docs/complete/hydration_todo.md` § Tests to Add. All seven go in a new file `Tests/SwiftAcervoTests/HydrationTests.swift`. Use `MockURLProtocol` (from Sortie 2) for all CDN stubbing — do NOT hit the real R2 CDN.

1. **Register-without-files round trip** — register bare descriptor → `ensureComponentReady` (with stubbed manifest + stubbed file downloads) → assert populated file list matches the stubbed manifest.
2. **Hydration picks up manifest drift** — register descriptor with a stale declared `files: [ComponentFile(relativePath: "old.bin", ...)]` → stub manifest to return `[new.bin, other.bin]` → call `hydrateComponent` → assert descriptor's files now == `[new.bin, other.bin]` (Blocker 1 default: replace) and assert the warning log was emitted (capture via log handler or a test-only log recorder).
3. **`isHydrated` transitions** — bare descriptor: `isHydrated == false`. After `hydrateComponent`: `isHydrated == true`.
4. **Manifest 404 on hydration** — stub `MockURLProtocol` to return HTTP 404 → assert `hydrateComponent` throws `AcervoError.manifestDownloadFailed(statusCode: 404)` → assert `ComponentRegistry.shared.component(id)!.isHydrated == false` afterwards (no partial state left behind).
5. **Concurrent hydration** — stub `MockURLProtocol` to return a valid manifest with a 100ms artificial delay → launch 10 concurrent `Task { hydrateComponent(id) }` → wait all → assert `MockURLProtocol.requestCount == 1` → all 10 tasks see hydrated state.
6. **Manifest ID mismatch** — register `foo/bar` → stub manifest with `modelId: "baz/qux"` → assert `AcervoError.manifestModelIdMismatch(expected: "foo/bar", actual: "baz/qux")` thrown → assert registry still has the original un-hydrated descriptor.
7. **Backwards compatibility** — existing descriptors that declare `files:` still work identically through `downloadComponent`, `ensureComponentReady`, `verifyComponent`. Assert: no hydration network call is made for a declared descriptor (`MockURLProtocol.requestCount == 0` for manifest URL after calling `ensureComponentReady`).

**Exit criteria**:
- [ ] `Tests/SwiftAcervoTests/HydrationTests.swift` exists.
- [ ] `grep -cE "^\s*func test" Tests/SwiftAcervoTests/HydrationTests.swift` returns `7`.
- [ ] `make test` passes with all 7 new tests green.
- [ ] Zero flakes on 5 consecutive `make test` runs (concurrency test #5 is the most likely flake risk) — supervising agent runs `for i in 1 2 3 4 5; do make test || exit 1; done` and the loop completes without failure.

---

### Sortie 7: Disk caching (CONDITIONAL — SKIP if Blocker 2 = "ship without")

**Priority**: 6 — blocks only Sortie 8; skipped by default.

**Entry criteria**:
- [ ] Sortie 6 exit criteria met.
- [ ] Blocker 2 resolved to "ship with caching".
- [ ] If Blocker 2 resolved to "ship without" (default), this sortie is **SKIPPED** — supervisor marks the sortie as `COMPLETED` with note "deferred per Blocker 2 decision". No dispatch.

**Tasks**:
1. In `AcervoDownloader.downloadManifest` (or a new caching wrapper): after a successful manifest fetch, write the raw bytes to `{modelDir}/manifest.json`. `modelDir` is the per-component directory under the App Group shared container.
2. On next call: if `manifest.json` exists and its mtime is less than `cacheTTL` ago, return the parsed cached manifest (after re-validating id + checksum-of-checksums). Otherwise, refetch.
3. Default TTL: 24 hours. Configurable via a new `Acervo.configuration.manifestCacheTTL: TimeInterval` property (requires adding a configuration struct if one does not exist — audit before adding).
4. On 404 / network error: fall back to disk cache if present, log a warning, return the cached manifest.

**Exit criteria**:
- [ ] `make build` succeeds.
- [ ] New test in `Tests/SwiftAcervoTests/ManifestCacheTests.swift`: first hydration writes `manifest.json` to disk (assert file exists in the per-component dir). Second hydration within TTL: `MockURLProtocol.requestCount` does not increment.
- [ ] Third hydration after TTL expiry (set TTL to a small value like 1ms for the test, or expose a time-override hook): `MockURLProtocol.requestCount` increments by 1.

---

### Sortie 8: Version bump, docs, migration notes

**Priority**: 2 — terminal sortie, no downstream dependencies, low risk.

**Entry criteria**:
- [ ] Sorties 1–6 exit criteria all met (and Sortie 7 if Blocker 2 was "ship with caching").

**Tasks**:
1. Bump version — edit `Sources/SwiftAcervo/Acervo.swift:30` from `public static let version = "0.7.3"` to `public static let version = "0.8.0"`. Also grep for any other `0.7.3` references: `grep -rn "0.7.3" Sources/ Package.swift *.md | grep -v node_modules` and update each (usually only the canonical constant in `Acervo.swift`).
2. Update `USAGE.md`: new section "Manifest-driven components" showing the bare-minimum descriptor (no `files:`) and how auto-hydration works on first `ensureComponentReady`. Include the migration snippet from `docs/complete/hydration_todo.md` § Migration Path.
3. Update `API_REFERENCE.md`: document `hydrateComponent`, `fetchManifest`, `isComponentReadyAsync`, `unhydratedComponents`, `ComponentDescriptor.isHydrated`, `ComponentDescriptor.needsHydration`, `AcervoError.componentNotHydrated`. Note the `isComponentReady` sync behavior change (now returns `false` for un-hydrated descriptors).
4. Create a new file `CHANGELOG.md` at repo root (verified 2026-04-22: this file does not yet exist) with a v0.8.0 entry covering: new public API surface, new error case, recommended migration, **non-breaking** for existing callers. Use Keep a Changelog format (Added / Changed / Deprecated / Fixed).
5. Extract the remaining CI-workflow follow-on from `docs/complete/hydration_todo.md` (§ "CI Workflow Is a Separate Problem") into a new `FOLLOW_UP.md` at repo root so that context isn't lost in the archive. Leave `docs/complete/hydration_todo.md` in place as the historical record.

**Exit criteria**:
- [ ] `grep -n 'let version = \"0.8.0\"' Sources/SwiftAcervo/Acervo.swift` returns a match.
- [ ] `grep -rn "0.7.3" Sources/ Package.swift` returns no matches (excluding `CHANGELOG.md` historical entries).
- [ ] `USAGE.md` contains a new section that mentions `hydrateComponent` or "auto-hydration" and shows a `ComponentDescriptor` init without `files:`.
- [ ] `API_REFERENCE.md` contains entries for every new public symbol (verify with `grep -c "hydrateComponent\|fetchManifest\|isComponentReadyAsync\|unhydratedComponents\|isHydrated\|needsHydration\|componentNotHydrated" API_REFERENCE.md` returning at least 7).
- [ ] `test -f CHANGELOG.md` succeeds AND `grep -n "0.8.0" CHANGELOG.md` returns a match.
- [ ] `test -f FOLLOW_UP.md` succeeds AND `grep -n "CI" FOLLOW_UP.md` returns a match.
- [ ] `test -f TODO.md` fails (file was archived to `docs/complete/hydration_todo.md` on 2026-04-22).
- [ ] `make build && make test` both succeed.

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 2 → Sortie 3 → Sortie 4 → Sortie 5 → Sortie 6 → (Sortie 7) → Sortie 8 (length: 7 or 8 sorties)

**Parallel Execution Groups**: None practical. Pass 3 analysis:

| Candidate Parallel Pair | Conflict |
|---|---|
| Sortie 1 + Sortie 2 | Both modify `Sources/SwiftAcervo/Acervo.swift` (Sortie 1 edits 4 call sites; Sortie 2 adds `fetchManifest`). Concurrent edits to the same file cause merge conflicts. |
| Sortie 4 + Sortie 5 | Both modify `Sources/SwiftAcervo/Acervo.swift` (Sortie 4 rewires 4 methods and adds `isComponentReadyAsync`; Sortie 5 modifies `pendingComponents`, `totalCatalogSize` and adds `unhydratedComponents`). Same conflict. |

**Agent Constraints**:
- **Supervising agent**: Handles ALL sorties. Every sortie has a `make build` exit criterion (per SwiftAcervo CLAUDE.md conventions), and sub-agents cannot run builds.
- **Sub-agents (up to 4 available, 0 used)**: No sub-agent work items identified. This mission is genuinely serial due to (a) central-file contention on `Acervo.swift` and (b) universal build requirement.

**Build Constraints**: 8 of 8 sorties restricted to the supervising agent.

**Missed Opportunities**: None. The central-file-hub architecture of `Acervo.swift` is intentional (single public API surface); changing it to enable parallelism is out of scope for this mission.

---

## Open Questions & Missing Documentation

Pass 4 scanned every sortie for vague criteria and unresolved questions. Findings:

### Resolved in-plan (no user action needed)

| Sortie | Issue Type | Original Issue | Resolution |
|---|---|---|---|
| 2 | Missing infra | Tests reference "existing test fixture infrastructure (whatever SwiftAcervo tests currently use for CDN responses)" — verified 2026-04-22 that no such infrastructure exists (`Tests/SwiftAcervoTests/Fixtures/` contains only `.gitkeep`, no `URLProtocol` subclass, no injectable session). | Sortie 2 scope expanded to include `MockURLProtocol` creation and URLSession injection into `downloadManifest`. |
| 3 | Vague criterion | "re-register with merge semantics" conflicted with Blocker 1 Replace semantics. | Sortie 3 Task 6 added: introduce `ComponentRegistry.replace(_:)` that overwrites wholesale, leaving existing `register(_:)` merge behavior untouched. |
| 5 | Vague criterion | "assert `pendingComponents()` behaves per chosen strategy" — un-verifiable without committing to a strategy. | Sortie 5 commits to Strategy (a) Skip explicitly; exit criteria now assert exact result sets. |
| 6 | Mock unavailable | Tests 4, 5, 6 require network stubbing that did not exist. | Provided by Sortie 2's `MockURLProtocol`. Sortie 6 now references it directly in each test. |
| 6 | Flake risk | Concurrency test was flagged as likely-flake. | Exit criterion now requires 5 consecutive passing `make test` runs. |
| 8 | Missing file | CHANGELOG.md referenced but does not exist. | Sortie 8 Task 4 explicitly creates it. |
| 8 | Unclear criterion | "TODO.md is either deleted or reduced" was ambiguous. | Now two clear options (A: delete, B: replace with FOLLOW_UP.md), agent picks and documents in commit. |

### All Blockers Resolved

| Issue | Status |
|---|---|
| **Blocker 1** (hydration semantics on drift) | ✓ Locked 2026-04-22: Replace with warning log. |
| **Blocker 2** (disk caching in v0.8.0) | ✓ Locked 2026-04-22: Ship without. Sortie 7 will be skipped. |
| **Blocker 3** (naming) | ✓ Locked 2026-04-22: `hydrateComponent`. |

Plan is fully unblocked and ready to dispatch.

### Subtle semantic note (documented, not blocking)

Sortie 4 changes `Acervo.isComponentReady(_:)` sync to return `false` for un-hydrated descriptors. Existing callers who registered descriptors with `files:` see NO change (those are hydrated from the start). Callers who adopt the new `files:`-less init and then check `isComponentReady` synchronously will see `false` until they either call `hydrateComponent` or `ensureComponentReady`. Sortie 8 migration notes call this out. Considered non-breaking for v0.8.0 because the un-hydrated code path is new.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 8 (7 mandatory + 1 conditional on Blocker 2) |
| Dependency structure | 6 layers, effectively serial (central-file contention) |
| Blockers requiring user input | 3 (with defaults: replace / no-caching / hydrateComponent) |
| Target version | 0.8.0 |
| Public API additions | `hydrateComponent`, `fetchManifest`, `isComponentReadyAsync`, `unhydratedComponents`, `ComponentDescriptor.isHydrated`, `ComponentDescriptor.needsHydration`, `AcervoError.componentNotHydrated` |
| Test infrastructure additions | `MockURLProtocol` (new), URLSession injection in `AcervoDownloader.downloadManifest` |
| Breaking changes | None (new init is additive; existing init unchanged; sync `isComponentReady` returns `false` for the new un-hydrated code path only) |
| Critical path length | 7 sorties (8 if Sortie 7 active) |
| Parallelism | 0 sub-agents useful (supervising-agent-only mission) |
| Estimated size per sortie | Pass 1: all right-sized at 16–31 turns (budget 50) |

---

## Refinement Pass Results

| Pass | Status | Changes |
|------|--------|---------|
| 1. Atomicity & Testability | ✓ PASS | Sortie 2 scope expanded (added mock infra tasks); Sortie 1 TODO markers made greppable; Sortie 5 strategy committed; Sortie 8 CHANGELOG creation made explicit. 0 splits, 0 merges (all sorties sized 32–62% of budget). |
| 2. Prioritization | ✓ PASS | Priority scores added to all sorties. Existing order matches dependency-driven priority; no reordering needed. |
| 3. Parallelism | ✓ PASS | Critical path identified (7–8 sorties). No useful sub-agent parallelism — central-file contention on `Acervo.swift`. All sorties run on supervising agent. |
| 4. Open Questions & Vague Criteria | ✓ PASS | 7 in-plan issues auto-fixed (mock infra, registry replace, strategy commitment, CHANGELOG creation, TODO.md disposition, isComponentReady semantic note, flake mitigation). 3 user-decision Blockers preserved with defaults. 0 unresolvable issues. |

**VERDICT**: ✓ Plan is ready to execute. All 3 Blockers resolved as of 2026-04-22.

**Next step**: `/mission-supervisor start`
