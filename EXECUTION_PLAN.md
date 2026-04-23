---
feature_name: OPERATION TRIPWIRE GAUNTLET
starting_point_commit: 68f5456d351e87746b571fa11177fd3519bfe28a
mission_branch: mission/tripwire-gauntlet/02
iteration: 2
---

# EXECUTION_PLAN.md — SwiftAcervo Testing Hardening (v0.8.0 pre-release)

Source: `TESTING_REQUIREMENTS.md` (v0.8.0, merge commit `4d01c3f`)
Cross-referenced: `FOLLOW_UP.md` § "Pre-existing Test Flake" and § "Test-Isolation Primitive"

Goal: close every P0 and P1 testing gap identified in `TESTING_REQUIREMENTS.md` before cutting the v0.8.0 release tag. P2 items are deferred and not scheduled. Done means CI green on iOS + macOS, zero skipped tests, and `TESTING_REQUIREMENTS.md` reduced to the P2 residual plus a "fixed in <sortie>" log.

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| Testing Hardening | `/Users/stovak/Projects/SwiftAcervo` | 15 | 1–5 | none |

All sorties execute within a single work unit (the SwiftAcervo repo). The five layers gate dependency order: a sortie in Layer N may not start until every sortie in Layers < N that it lists as a prerequisite is `COMPLETED`. Priority scores below are computed from dependency depth × 3 + foundation × 2 + risk × 1 + complexity × 0.5 and are used to break ties when multiple sorties in a wave are ready at once.

## Parallelism Structure

**Critical Path** (length: 4 sorties): any Layer 1 sortie → any Layer 2 or Layer 3 sortie → any Layer 4 sortie → Sortie 15.

Example: Sortie 1 → Sortie 7 → Sortie 10 → Sortie 15.

**Parallel Execution Waves** (at most 4 sortie agents dispatched concurrently):

- **Wave 1** (Layer 1, no prerequisites): Sorties 1, 2, 3 — dispatch all three in parallel.
- **Wave 2A** (Layer 2, depends on Sortie 3): Sorties 4, 5, 6 — dispatch as soon as Sortie 3 clears, up to 3 in parallel.
- **Wave 2B** (Layer 3, depends on Sorties 1 and 2): Sorties 7, 8, 9 — dispatch as soon as both Sortie 1 and Sortie 2 clear, up to 3 in parallel. Waves 2A and 2B may overlap; the 4-agent cap governs actual concurrency.
- **Wave 3** (Layer 4, depends on all of Layers 1–3): Sorties 10, 11, 12, 13, 14 — dispatch in batches of 4 then 1.
- **Wave 4** (Layer 5, depends on Sorties 10–14): Sortie 15 alone.

**Agent allocation**:
- 1 supervising agent (this instance) orchestrates dispatch and aggregates results.
- Up to 4 sortie sub-agents run concurrently. Each sortie sub-agent performs its own edits, runs `make test`, and reports pass/fail against its exit criteria.
- **No further decomposition**: individual sortie agents MUST NOT spawn their own sub-agents for parallel work. Each sortie is atomic — a single agent end-to-end.

**Build constraints**: Every sortie's exit criteria include a `make test` run. `make test` is the authoritative build/test gate for this repo (per user's global rule: prefer Makefile targets over raw `xcodebuild`). Running `make test` concurrently across multiple sortie agents is acceptable; SwiftPM and Xcode serialize internally.

**Missed parallelism opportunities**: None. The layer structure already exposes maximum parallelism given the dependency graph. Sortie 15 is unavoidably serial (it audits CI state after Layer 4 completes).

---

### Sortie 1: Thread `session:` through the file-download path

**Layer**: 1

**Priority**: 14.0 — blocks Sorties 7, 8, 9; foundational for all end-to-end tests that rely on `MockURLProtocol`; moderate risk (refactor across core download path).

**Entry criteria**:
- [ ] First sortie — no prerequisites.
- [ ] `Sources/SwiftAcervo/AcervoDownloader.swift` exists and compiles.
- [ ] `Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` exists.

**Tasks**:
1. In `Sources/SwiftAcervo/AcervoDownloader.swift` (definition at line ~292, verify with `grep -n "private static func streamDownloadFile"`), change `streamDownloadFile(...)` to accept `session: URLSession = SecureDownloadSession.shared` and use that session for every `URLSession.shared`/`SecureDownloadSession.shared` reference inside the body.
2. In `Sources/SwiftAcervo/AcervoDownloader.swift` (definition at line ~452, verify with `grep -n "private static func fallbackDownloadFile"`), apply the same change to `fallbackDownloadFile(...)`.
3. In `Sources/SwiftAcervo/AcervoDownloader.swift` (line ~674, `downloadFiles(...)`) and in every `downloadFile(...)` overload it calls (see `grep -n "static func downloadFile"`), thread the `session` parameter through. Default must remain `SecureDownloadSession.shared` so no existing call site changes.
4. Run `make lint` and confirm no formatting diffs remain.
5. Add a single smoke test in a new `Tests/SwiftAcervoTests/DownloadSessionInjectionTests.swift` that: (a) installs a `MockURLProtocol` responder serving a known body, (b) calls the lowest public entry point that ultimately invokes `streamDownloadFile`, (c) asserts `MockURLProtocol.requestCount >= 1` and the file content matches. Nest the new suite under `MockURLProtocolSuite` so it inherits `.serialized`.

**Exit criteria**:
- [ ] `make test` passes.
- [ ] `grep -En "^[^/]*\b(SecureDownloadSession|URLSession)\.shared\b" Sources/SwiftAcervo/AcervoDownloader.swift` returns only default-parameter declarations (lines containing `= SecureDownloadSession.shared`) — no bare call-site usages.
- [ ] The new smoke test runs, asserts the body roundtrip, and passes 3 consecutive `make test` invocations.

---

### Sortie 2: Test-isolation primitive for `customBaseDirectory` and `ComponentRegistry.shared`

**Layer**: 1

**Priority**: 14.25 — blocks Sorties 7, 8, 9; foundational infrastructure reused across every filesystem- or registry-sensitive test; moderate risk (test infrastructure refactor affecting 4+ files).

**Entry criteria**:
- [ ] First-layer sortie — no prerequisites.
- [ ] `FOLLOW_UP.md § "Test-Isolation Primitive"` and `§ "Pre-existing Test Flake"` have been read and their scope confirmed.

**Tasks**:
1. Decide the isolation approach and record the decision in the sortie log: either (a) a shared `@Suite(.serialized) struct CustomBaseDirectorySuite {}` parent (mirrors `MockURLProtocolSuite` in `Tests/SwiftAcervoTests/MockURLProtocolTests.swift`) or (b) a per-suite `withIsolatedAcervoState { ... }` helper that snapshots and restores both globals. Preference: (a) plus (b), applied together.
2. Create `Tests/SwiftAcervoTests/Support/CustomBaseDirectorySuite.swift` exporting `@Suite("Custom Base Directory", .serialized) struct CustomBaseDirectorySuite {}`. If a prior uncommitted copy of this file exists (it does — see `git status`), overwrite it to match this task.
3. Convert every suite that currently assigns `Acervo.customBaseDirectory` to be nested under `CustomBaseDirectorySuite` via `extension CustomBaseDirectorySuite { @Suite(...) struct X { ... } }`. Audit target: `Tests/SwiftAcervoTests/AcervoPathTests.swift`, `Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` (two nested suites), and `Tests/SwiftAcervoTests/ModelDownloadManagerTests.swift`.
4. Add a `Tests/SwiftAcervoTests/Support/ComponentRegistryIsolation.swift` helper that snapshots the current registry contents, yields to a closure, and restores them on exit. Apply it to one representative test that currently relies on `defer { unregisterComponent(...) }` + UUID suffix (e.g., `HydrateComponentTests.uniqueIds`) as a proof-of-use; do not convert every call site in this sortie.
5. Run `make test` five consecutive times. Zero flakes is the bar.

**Exit criteria**:
- [ ] `CustomBaseDirectorySuite` exists and every suite that writes `Acervo.customBaseDirectory` is nested under it.
- [ ] `make test` passes 5 consecutive times with zero failures in `AcervoPathTests.sharedModelsDirectoryPath`, `AcervoPathTests.sharedModelsDirectoryIsAbsolute`, and the Filesystem Edge Cases suites.
- [ ] The proof-of-use test for the registry-isolation helper passes and is referenced by file+line in the sortie log.
- [ ] `FOLLOW_UP.md § "Pre-existing Test Flake"` is updated to note the fix and link to this sortie.

---

### Sortie 3: Add `session:` parameter to public `Acervo.fetchManifest(for:)`

**Layer**: 1

**Priority**: 12.5 — blocks Sorties 4, 5, 6; foundational for all Layer 2 manifest tests; low risk (additive public API).

**Entry criteria**:
- [ ] First-layer sortie — no prerequisites.
- [ ] `Sources/SwiftAcervo/Acervo.swift:1358-1394` (the `fetchManifest` / `fetchManifest(forComponent:)` block introduced on `development`) compiles. **Current shape** (confirmed): the public overloads are `fetchManifest(for:)` and `fetchManifest(forComponent:)`, and each already has an **internal** session-accepting overload (`fetchManifest(for:session:)` and `fetchManifest(forComponent:session:)`). This sortie promotes the `session:`-accepting overloads to `public` (or adds public passthroughs) so tests outside `@testable import` can inject sessions.

**Tasks**:
1. Promote the two `session:`-accepting overloads at `Sources/SwiftAcervo/Acervo.swift:1364-1369` and `Sources/SwiftAcervo/Acervo.swift:1387-1395` from internal (default) visibility to `public`. Preserve their existing forwarding behavior.
2. Ensure the `forComponent:` variant exposes the same public/internal parity so registry-aware lookups are testable from non-`@testable` contexts.
3. Update any `@testable import` call site in `Tests/SwiftAcervoTests/ManifestFetchTests.swift` that currently reaches the internal overload to prefer the new public overload where possible.
4. Run `make lint`.
5. Keep the changes additive — no existing signature may be removed.

**Exit criteria**:
- [ ] `Acervo.fetchManifest(for:session:)` and `Acervo.fetchManifest(forComponent:session:)` are `public`.
- [ ] `make build` and `make test` both pass.
- [ ] `grep -n "public static func fetchManifest" Sources/SwiftAcervo/Acervo.swift` shows four results: both no-session and both session-accepting overloads.

---

### Sortie 4: Behavior tests for `Acervo.fetchManifest(for:)` via the public API

**Layer**: 2

**Priority**: 1.75 — leaf sortie (blocks nothing); low risk test-only work.

**Entry criteria**:
- [ ] Sortie 3 `COMPLETED`.
- [ ] `Tests/SwiftAcervoTests/ManifestFetchTests.swift` exists.

**Tasks**:
1. In `Tests/SwiftAcervoTests/ManifestFetchTests.swift`, replace the symbol-existence check `fetchManifestIsCallable` (currently a compile-only stub) with a real behavior test that calls the public `fetchManifest(for:session:)` overload with a `MockURLProtocol`-backed session.
2. Add an equivalent test for `fetchManifest(forComponent:session:)` that registers a bare descriptor, stubs the manifest response, and asserts the returned `CDNManifest` fields.
3. Add a negative test asserting `AcervoError.componentNotRegistered` when the component ID is unknown.
4. Nest the new tests under `MockURLProtocolSuite` so they inherit `.serialized`.
5. Delete any now-redundant `downloadManifestWithMockSession` coverage that the public-API tests supersede (redundancy = same manifest shape and same response stubs).

**Exit criteria**:
- [ ] `ManifestFetchTests` contains at least three new `@Test` cases exercising the public API and one negative case.
- [ ] `make test` passes.
- [ ] No test in `ManifestFetchTests` is a compile-only "symbol exists" stub (`grep -n "fetchManifestIsCallable\|#expect(type(of:" Tests/SwiftAcervoTests/ManifestFetchTests.swift` returns no matches).

---

### Sortie 5: Manifest error-mode tests — decoding, integrity, and version

**Layer**: 2

**Priority**: 2.0 — leaf sortie; low risk.

**Entry criteria**:
- [ ] Sortie 3 `COMPLETED` (so tests can call through the public `session:`-injected overload).

**Tasks**:
1. Add a test in `Tests/SwiftAcervoTests/HydrationTests.swift` (or a new `ManifestErrorModeTests.swift` nested under `MockURLProtocolSuite`) that stubs a 200 response with malformed JSON and asserts `AcervoError.manifestDecodingFailed`.
2. Add a test that stubs a 200 response with a valid JSON manifest whose `manifestChecksum` does not match the checksum-of-checksums of `files[].sha256`; assert `AcervoError.manifestIntegrityFailed(expected:actual:)` and verify both fields populate.
3. Add a test that stubs a manifest with `manifestVersion = CDNManifest.supportedVersion + 1` and asserts `AcervoError.manifestVersionUnsupported`.
4. Add a companion boundary test with `manifestVersion = 0` and assert rejection.
5. Run `make test` 3 consecutive times.

**Exit criteria**:
- [ ] Four new `@Test` cases exist, one per scenario above.
- [ ] `make test` passes 3 consecutive times.
- [ ] Each test references the exact `AcervoError` case by name in its assertion.

---

### Sortie 6: HydrationCoalescer error-path and re-fetch tests

**Layer**: 2

**Priority**: 1.75 — leaf sortie; low risk.

**Entry criteria**:
- [ ] Sortie 3 `COMPLETED`.
- [ ] `Sources/SwiftAcervo/Acervo.swift:1403-1424` (HydrationCoalescer actor and its shared instance) compiles.

**Tasks**:
1. Add a test in `Tests/SwiftAcervoTests/HydrationTests.swift` (nested under `MockURLProtocolSuite`) that registers a bare descriptor, configures the responder to return 500 on call 1 and 200 on call 2, invokes `hydrateComponent` twice, asserts the first throws, the second succeeds, and `MockURLProtocol.requestCount == 2`.
2. Add a second test that configures a 200 responder, invokes `hydrateComponent` twice sequentially (awaiting the first before the second), and asserts `MockURLProtocol.requestCount == 2` — proving re-fetch after completion (distinct from the existing single-flight coalesce test).
3. Nest both new tests under `MockURLProtocolSuite`.
4. Confirm the existing `concurrentHydration` single-flight test still passes (no regression).
5. Run `make test` 3 consecutive times.

**Exit criteria**:
- [ ] Two new `@Test` cases exist, each with an explicit `MockURLProtocol.requestCount` assertion.
- [ ] `make test` passes 3 consecutive times.
- [ ] The existing `concurrentHydration` test still passes unchanged.

---

### Sortie 7: End-to-end `downloadComponent` auto-hydration test

**Layer**: 3

**Priority**: 3.5 — leaf sortie but highest complexity in Layer 3 (E2E integration across hydration, streaming, and verification).

**Entry criteria**:
- [ ] Sortie 1 `COMPLETED` (session injection available on the file-download path).
- [ ] Sortie 2 `COMPLETED` (`CustomBaseDirectorySuite` + registry isolation available for clean setup/teardown).

**Tasks**:
1. In a new `Tests/SwiftAcervoTests/DownloadComponentAutoHydrationTests.swift`, register a bare descriptor (via `ComponentDescriptor.init(id:type:displayName:repoId:minimumMemoryBytes:metadata:)`) with `needsHydration == true`.
2. Stub the manifest response and every file-body response via `MockURLProtocol`.
3. Call `Acervo.downloadComponent(...)` and assert: (a) hydration ran (descriptor.files is populated post-call), (b) files landed on disk in the expected slug directory, (c) integrity verification passed, (d) the call returns without throwing.
4. Add an assertion that `MockURLProtocol.requestCount` equals `1 + files.count` (one manifest + one per file).
5. Nest under `MockURLProtocolSuite`. Use the `customBaseDirectory` isolation from Sortie 2.
6. Add a source comment at the top of the new test file: `// Mutation check: exercises the auto-hydration branch in Acervo.swift (currently lines 1539-1541, `if initialDescriptor.needsHydration { try await hydrateComponent(...) }`). If this branch is deleted, this test must fail.` The exact line range may drift — update the comment to match whatever line `grep -n "if initialDescriptor.needsHydration" Sources/SwiftAcervo/Acervo.swift | head -1` returns at commit time.

**Exit criteria**:
- [ ] New `@Test` exercising the full hydration → streaming → verify path exists and passes.
- [ ] `make test` passes 3 consecutive times.
- [ ] `grep -n "Mutation check: exercises the auto-hydration branch" Tests/SwiftAcervoTests/DownloadComponentAutoHydrationTests.swift` returns exactly one hit, and the line range cited in that comment matches the current output of `grep -n "if initialDescriptor.needsHydration" Sources/SwiftAcervo/Acervo.swift` (first match).

---

### Sortie 8: Registry-level SHA-256 cross-check failure test

**Layer**: 3

**Priority**: 3.0 — leaf sortie; moderate risk (tests an under-covered integrity gate).

**Entry criteria**:
- [ ] Sortie 1 `COMPLETED`.
- [ ] Sortie 2 `COMPLETED`.

**Tasks**:
1. In `Tests/SwiftAcervoTests/ComponentIntegrationTests.swift` (or a new companion file), construct a scenario per `TESTING_REQUIREMENTS.md` P0 §"Registry-level SHA-256 cross-check": stage a file on disk whose content hashes to `X`, register a hydrated descriptor whose `sha256` is `Y`, call `downloadComponent` with `force: false`.
2. Assert `AcervoError.integrityCheckFailed(file:expected:actual:)` is thrown with the correct three fields.
3. Assert the corrupt file was deleted (file does not exist post-throw).
4. The registry-level second pass is implemented at `Sources/SwiftAcervo/Acervo.swift:1560-1576` (the loop over `descriptor.files` following the manifest-driven download), distinct from the streaming pass at `AcervoDownloader.swift:401-408` (inside `streamDownloadFile`). Add a source comment at the top of the test that cites both line ranges so future readers know which gate this test targets. Update the ranges to whatever `grep -n "Additional registry-level checksum verification" Sources/SwiftAcervo/Acervo.swift` and `grep -n "throw AcervoError.integrityCheckFailed(" Sources/SwiftAcervo/AcervoDownloader.swift` return at commit time.
5. Nest under `MockURLProtocolSuite`.

**Exit criteria**:
- [ ] New `@Test` exists and asserts all three fields of `integrityCheckFailed`.
- [ ] Post-throw file deletion is asserted via `FileManager.default.fileExists(...)`.
- [ ] `make test` passes 3 consecutive times.
- [ ] `grep -n "Registry-level second pass:" <new-or-modified-test-file>` returns at least one hit, and the cited line ranges for `Acervo.swift` and `AcervoDownloader.swift` match the current grep output (first match for each).

---

### Sortie 9: `Acervo.ensureAvailable(modelId, files: [])` empty-files behavior tests

**Layer**: 3

**Priority**: 1.75 — leaf sortie; low risk.

**Entry criteria**:
- [ ] Sortie 1 `COMPLETED`.
- [ ] Sortie 2 `COMPLETED`.

**Tasks**:
1. Add tests in a new `Tests/SwiftAcervoTests/EnsureAvailableEmptyFilesTests.swift` (nested under `MockURLProtocolSuite`).
2. Stub a manifest response with three file entries. Call `Acervo.ensureAvailable(modelId: ..., files: [])`. Assert all three files land on disk.
3. Add a regression test: `files: ["config.json"]` must download only the named file.
4. Add a test that asserts `AcervoError.fileNotInManifest` fires for a non-empty `files:` array containing a name the manifest does not list.
5. Confirm `ModelDownloadManager.ensureModelsAvailable` (which funnels to the same path) still passes.
6. Add a source comment: `// Exercises the requestedFiles.isEmpty branch in AcervoDownloader.swift (currently line ~686, "if requestedFiles.isEmpty { filesToDownload = manifest.files }").` Update the line number to match `grep -n "if requestedFiles.isEmpty" Sources/SwiftAcervo/AcervoDownloader.swift` at commit time.

**Exit criteria**:
- [ ] Three new `@Test` cases exist covering empty, named subset, and not-in-manifest.
- [ ] `make test` passes 3 consecutive times.
- [ ] `grep -n "requestedFiles.isEmpty branch" Tests/SwiftAcervoTests/EnsureAvailableEmptyFilesTests.swift` returns at least one hit, and the cited line number matches the current output of `grep -n "if requestedFiles.isEmpty" Sources/SwiftAcervo/AcervoDownloader.swift`.

---

### Sortie 10: `ShipCommand.swift` unit tests

**Layer**: 4

**Priority**: 5.0 — blocks Sortie 15; moderate complexity (argument parsing + pipeline stubbing).

**Entry criteria**:
- [ ] Every Layer 1–3 sortie (Sorties 1–9) `COMPLETED`.
- [ ] `Sources/acervo/ShipCommand.swift` compiles.

**Tasks**:
1. Create `Tests/AcervoToolTests/ShipCommandTests.swift`.
2. Happy-path: parse a valid argv, assert each flag (`--force`, `--skip-upload`, `--model-id`) is captured with the expected value.
3. Missing required argument: assert the command exits non-zero with the canonical "missing --model-id" error.
4. Error surfacing: stub one pipeline step (manifest, upload, verify) to throw; assert the corresponding exit code.
5. Step sequencing: assert steps run in the documented order when every step is stubbed to succeed.

**Exit criteria**:
- [ ] At least five `@Test` cases exist (happy-path, one per error stub, plus one sequencing assertion).
- [ ] `make test` passes.
- [ ] No test relies on live R2 or HF credentials (`grep -En "R2_(ACCESS|SECRET)|HF_TOKEN" Tests/AcervoToolTests/ShipCommandTests.swift` returns no real reads from `ProcessInfo.processInfo.environment`).

---

### Sortie 11: `DownloadCommand.swift` unit tests

**Layer**: 4

**Priority**: 4.75 — blocks Sortie 15; moderate complexity.

**Entry criteria**:
- [ ] Every Layer 1–3 sortie `COMPLETED`.
- [ ] `Sources/acervo/DownloadCommand.swift` compiles.

**Tasks**:
1. Create `Tests/AcervoToolTests/DownloadCommandTests.swift`.
2. Happy-path argument parsing test.
3. HuggingFace-only path smoke test (HF client stubbed).
4. Missing required argument test.
5. Exit-code mapping for at least one failure mode.

**Exit criteria**:
- [ ] At least three `@Test` cases exist.
- [ ] `make test` passes.
- [ ] No live HF calls (the HF client is invoked only through a stubbed protocol or injected test double).

---

### Sortie 12: `UploadCommand.swift` unit tests

**Layer**: 4

**Priority**: 5.0 — blocks Sortie 15; moderate complexity.

**Entry criteria**:
- [ ] Every Layer 1–3 sortie `COMPLETED`.
- [ ] `Sources/acervo/UploadCommand.swift` compiles.

**Tasks**:
1. Create `Tests/AcervoToolTests/UploadCommandTests.swift`.
2. Happy-path argument parsing.
3. Missing R2 credentials test: assert the command exits non-zero with a clear error message.
4. Upload-only path with stubbed R2 client: assert correct bucket/key arguments.
5. Missing required argument test.

**Exit criteria**:
- [ ] At least three `@Test` cases exist.
- [ ] `make test` passes.
- [ ] Credential validation path is exercised without actual credentials (tests set a sentinel or unset env var and assert the CLI's error, not a real upload).

---

### Sortie 13: `VerifyCommand.swift` unit tests

**Layer**: 4

**Priority**: 5.0 — blocks Sortie 15; moderate complexity.

**Entry criteria**:
- [ ] Every Layer 1–3 sortie `COMPLETED`.
- [ ] `Sources/acervo/VerifyCommand.swift` compiles.

**Tasks**:
1. Create `Tests/AcervoToolTests/VerifyCommandTests.swift`.
2. Happy-path: all integrity checks pass → exit 0.
3. Corrupted manifest: at least one check fails → non-zero exit code.
4. Missing required argument test.
5. Exit-code mapping for each distinct failure class (manifest missing, file missing, checksum mismatch).

**Exit criteria**:
- [ ] At least four `@Test` cases exist.
- [ ] `make test` passes.

---

### Sortie 14: `ManifestCommand.swift` unit tests

**Layer**: 4

**Priority**: 5.0 — blocks Sortie 15; includes a determinism test that is a foundational guarantee for downstream CDN roundtrip tests.

**Entry criteria**:
- [ ] Every Layer 1–3 sortie `COMPLETED`.
- [ ] `Sources/acervo/ManifestCommand.swift` compiles.

**Tasks**:
1. Create `Tests/AcervoToolTests/ManifestCommandTests.swift`.
2. Happy-path: generate a manifest from a fixture directory; assert expected JSON shape and checksum-of-checksums.
3. Missing required argument test.
4. Empty directory test: assert meaningful error (no files to manifest).
5. File-ordering determinism test: regenerating a manifest from the same directory produces byte-identical output (compare via `Data` equality or SHA-256 of each output).

**Exit criteria**:
- [ ] At least four `@Test` cases exist.
- [ ] `make test` passes.
- [ ] Manifest output is byte-identical across two generations of the same input (determinism test asserts `Data` equality).

---

### Sortie 15: Audit and document CI gating for `AcervoToolIntegrationTests`

**Layer**: 5

**Priority**: 0.5 — docs-only leaf, no downstream dependents.

**Entry criteria**:
- [ ] Sorties 10–14 `COMPLETED` (so any gaps surfaced there feed into this audit).

**Tasks**:
1. Read every file under `.github/workflows/` (currently: `mirror_model.yml`, `release.yml`, `tests.yml`) and enumerate which jobs run `Tests/AcervoToolIntegrationTests/` (`CDNRoundtripTests.swift`, `HuggingFaceDownloadTests.swift`, `ManifestRoundtripTests.swift`, `ShipCommandTests.swift`).
2. For each integration test, determine whether `R2_*` and `HF_TOKEN` secrets are provided by the job environment (look for `env:` blocks and `secrets.*` references).
3. Write a new subsection under `TESTING_REQUIREMENTS.md` § "CLI command coverage" titled **"CI integration test gating"**, listing each integration test as a row with four columns: workflow file, job name, required secrets, behavior when secrets are absent (skip vs. fail).
4. If any integration test is currently unreachable in CI (no job runs it, or secrets are never provided), file it as a new P1 gap in `TESTING_REQUIREMENTS.md` with `[ ]` checkbox and explicit action item.
5. No code changes — documentation only.

**Exit criteria**:
- [ ] `TESTING_REQUIREMENTS.md` contains a new subsection titled exactly `CI integration test gating` under `CLI command coverage` (verify with `grep -n "^#### CI integration test gating\|^### CI integration test gating" TESTING_REQUIREMENTS.md`).
- [ ] The new subsection contains one row per integration test file listed in Task 1.
- [ ] Any currently-unreachable integration test is surfaced as a new P1 gap in the same document.
- [ ] `make test` still passes (no regression).

---

## Open Questions & Missing Documentation

Pass 4 scan of the refined plan surfaced no blocking open questions. All referenced files, workflows, and sections exist in the repo. Two residual items are worth flagging as soft-yellows; neither blocks execution:

| Sortie | Issue Type | Description | Disposition |
|--------|-----------|-------------|-------------|
| Sortie 2 | Ambiguity | Task 1 offers options (a) and (b) but states the preference is both applied together. | Accepted as-is — preference is explicit; sortie log records the choice. |
| Sortie 4 | Soft criterion | Task 5: "Delete any now-redundant `downloadManifestWithMockSession` coverage" relies on the agent's judgment of redundancy. | Tightened during Pass 4: redundancy is defined as "same manifest shape AND same response stubs" as one of the new public-API tests. |

No other open questions, missing documents, or external dependencies remain.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 15 |
| Dependency structure | 5 layers; within a layer sorties are independent and can run in parallel |
| Layer 1 (foundations) | Sorties 1, 2, 3 |
| Layer 2 (hydration + manifest tests, depends on Sortie 3) | Sorties 4, 5, 6 |
| Layer 3 (end-to-end tests, depends on Sorties 1 and 2) | Sorties 7, 8, 9 |
| Layer 4 (CLI unit tests, depends on all of Layers 1–3) | Sorties 10, 11, 12, 13, 14 |
| Layer 5 (CI audit) | Sortie 15 |
| Critical path length | 4 sorties (e.g., 1 → 7 → 10 → 15) |
| Max concurrent agents per wave | 4 |
| Average sortie estimated size | ~18 turns (budget: 50 turns/sortie) |

Blocking dependencies across all sorties:
- 4 blocked by 3
- 5 blocked by 3
- 6 blocked by 3
- 7 blocked by 1, 2
- 8 blocked by 1, 2
- 9 blocked by 1, 2
- 10, 11, 12, 13, 14 each blocked by the entire union of 1–9
- 15 blocked by 10, 11, 12, 13, 14

Priority ordering within each layer (higher score = dispatched first when slot contention arises):

- Layer 1: Sortie 2 (14.25) > Sortie 1 (14.0) > Sortie 3 (12.5)
- Layer 2: Sortie 5 (2.0) > Sortie 4 (1.75) = Sortie 6 (1.75)
- Layer 3: Sortie 7 (3.5) > Sortie 8 (3.0) > Sortie 9 (1.75)
- Layer 4: Sorties 10, 12, 13, 14 (5.0) > Sortie 11 (4.75)
- Layer 5: Sortie 15 (0.5)

Priority differences within each layer are within noise; no physical renumbering was applied. The priority score is an advisory signal for the supervisor when choosing which of N ready sorties to dispatch first into a free slot.
