---
feature_name: OPERATION FILING SERGEANT
starting_point_commit: 2fb6f80ce3832a4d57117242749f0a6c09e293d5
mission_branch: mission/filing-sergeant/1
iteration: 1
---

# EXECUTION_PLAN.md — SwiftAcervo Testing Mission

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure. Unlike an agile sprint (which maps to time), a mission maps to agentic cycles — which have no inherent time dimension.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One agent, one goal, one return. The term is borrowed from military aviation.

> **Work Unit** — A grouping of sorties (package, component, phase). The supervisor treats them uniformly.

The key distinction: a **mission** is the definable scope; a **sortie** is one agent's focused task within it.

---

## Mission Overview

Bring SwiftAcervo's test suite into full compliance with `TESTING_REQUIREMENTS.md`. The codebase already has a substantial test suite (~350+ tests across 27 files), but gap analysis reveals:

1. **CI workflow** is missing required xcodebuild flags (`-skipPackagePluginValidation`, `ARCHS=arm64`, `ONLY_ACTIVE_ARCH=YES`, `COMPILER_INDEX_STORE_ENABLE=NO`)
2. **Integration test gate** uses compile-time `#if INTEGRATION_TESTS` instead of the required runtime `ProcessInfo.processInfo.environment` guard with `Issue.record()`
3. **`slugify` space/uppercase discrepancy** — `TESTING_REQUIREMENTS.md` §4a claims slugify converts spaces and uppercase; the actual implementation `modelId.replacingOccurrences(of: "/", with: "_")` only replaces `/`. Tests in `AcervoPathTests.swift` already confirm spaces and uppercase are preserved (e.g., `"mlx-community/Qwen2.5-7B-Instruct-4bit"` → `"mlx-community_Qwen2.5-7B-Instruct-4bit"`). **Pre-resolved**: §4a is wrong; the sortie must correct §4a and add tests asserting that spaces and uppercase ARE preserved unchanged.
4. **`customBaseDirectory` isolation** for `sharedModelsDirectory` path tests — tests call production `sharedModelsDirectory` directly without the `customBaseDirectory` isolation pattern from §6
5. **Coverage gaps from §7** (priorities 2–9) are not yet tested: disk-full, file permission denial, manifest version boundary (0, 99), concurrent `getAccessCount`, `withModelAccess`/`withComponentAccess` exception safety, symlinks in model directory

### Pre-Resolved Open Questions

| Question | Resolution |
|----------|-----------|
| Q1: Does `Acervo.slugify` intentionally preserve spaces and uppercase? | **Yes.** Implementation: `modelId.replacingOccurrences(of: "/", with: "_")`. Existing tests confirm this. §4a in TESTING_REQUIREMENTS.md is wrong and must be corrected to read "converts `/` to `_`". |
| Q3: Is a stable CDN model ID needed for integration tests? | **Already resolved.** `IntegrationTests.swift` hardcodes `"mlx-community/Llama-3.2-1B-Instruct-4bit"`. No change needed. |
| Q2: What is the intended behavior for `listModels` with a broken symlink? | **Unresolved.** Sortie 5 agent must inspect the source and test whichever behavior is implemented. Not a blocker. |

---

## Constraints

- **Framework**: Swift Testing (`import Testing`) only — no XCTest
- **Concurrency**: Swift 6 strict concurrency throughout
- **Build tool**: `xcodebuild` — never `swift test` or `swift build`
- **Integration gate**: Runtime `ProcessInfo.processInfo.environment["INTEGRATION_TESTS"]` + `Issue.record()` — never `#if`, `XCTSkip`, or `#skip`
- **Temp isolation**: All filesystem-touching tests must use `customBaseDirectory` pattern from §6

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|--------------|
| WU-1: CI Pipeline Compliance | `.github/workflows/` | 1 | 1 | none |
| WU-2: Integration Gate Migration | `Tests/SwiftAcervoTests/` | 1 | 1 | none |
| WU-3: Slugify Discrepancy Resolution | `Sources/SwiftAcervo/` + `Tests/SwiftAcervoTests/` | 1 | 1 | none |
| WU-4: Requirements Gap Tests — Filesystem Edge Cases | `Tests/SwiftAcervoTests/` | 2 | 2 | WU-1, WU-2 |
| WU-5: Requirements Gap Tests — Manifest & Registry | `Tests/SwiftAcervoTests/` | 1 | 2 | WU-1, WU-2 |
| WU-6: Requirements Gap Tests — Concurrency & Access Safety | `Tests/SwiftAcervoTests/` | 2 | 2 | WU-1, WU-2 |
| WU-7: CI Green Verification | CI / local | 1 | 3 | WU-1 through WU-6 |

---

## Parallelism Structure

**Critical Path**: Sortie 1 → Sortie 2 → Sortie 4 → Sortie 5 → Sortie 9 (5 sorties)

**Parallel Execution Groups**:
- **Layer 1** (all 3 can start simultaneously):
  - WU-1: Sortie 1 — **SUB-AGENT** (no build; python3 YAML validation only)
  - WU-2: Sortie 2 — **SUPERVISING AGENT** (has xcodebuild build step)
  - WU-3: Sortie 3 — **SUPERVISING AGENT** (has xcodebuild test step)
  - *Note*: Sub-agent and supervising agent can run S1 + (S2 or S3) concurrently. S2 and S3 are serialized through the supervising agent.

- **Layer 2** (after Layer 1 completes; S4, S6, S7 can start simultaneously):
  - WU-4: Sortie 4 → Sortie 5 (sequential — S5 appends to the file S4 creates)
  - WU-5: Sortie 6 (independent of WU-4 and WU-6; touches CDNManifestTests.swift only)
  - WU-6: Sortie 7 → Sortie 8 (sequential — S8 depends on S7's setup)
  - *Note*: All Layer 2 sorties have build steps → supervising agent handles all. S6 could theoretically overlap with S4/S7 via a sub-agent but it has a build step, so it must be serialized.

- **Layer 3**:
  - WU-7: Sortie 9 — **SUPERVISING AGENT ONLY** (runs full xcodebuild test suite)

**Agent Constraints**:
- **Supervising agent**: Handles all sorties with xcodebuild build/test steps (S2, S3, S4, S5, S6, S7, S8, S9)
- **Sub-agent (1 only)**: Sortie 1 (YAML edit + python3 validation — no xcodebuild)

**Missed Opportunities**: All sorties except S1 require xcodebuild, which limits true parallelism. The only genuine parallel opportunity is S1 (sub-agent) running concurrent with the supervising agent handling S2 or S3.

---

## Priority Scores

| Sortie | Priority Score | Justification |
|--------|---------------|---------------|
| S1 | 25.5 | Highest dependency depth (8 sorties transitively depend on it) |
| S2 | 22.5 | High dependency depth (7 sorties depend on it) |
| S3 | 2.75 | No downstream dependencies; touches source (risk=2) |
| S4 | 5.75 | S5 depends on it; touches new file (risk=2) |
| S7 | 5.75 | S8 depends on it; touches existing files (risk=2) |
| S5 | 2.75 | No further downstream dependencies |
| S8 | 2.75 | No further downstream dependencies |
| S6 | 1.5 | No downstream dependencies; lower risk |
| S9 | 2.0 | Verification only; runs last by design |

---

## WU-1: CI Pipeline Compliance

**Goal**: Update the GitHub Actions test workflow to use all required xcodebuild flags from §2.

**Environment**: CI/CD — required for all PRs to `main` and `development`

---

### Sortie 1: Add Required xcodebuild Flags to Tests Workflow

**Priority**: 25.5 — Highest priority: 7 sorties in layers 2 and 3 depend on CI compliance

**Agent**: Sub-agent (no xcodebuild; only file edit + python3 YAML validation)

**Entry criteria**:
- [ ] First sortie — no prerequisites
- [ ] `.github/workflows/tests.yml` exists and runs `xcodebuild test`

**Tasks**:
1. Open `.github/workflows/tests.yml`
2. In the `test-macos` job's `Test` step, add flags: `-skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO`
3. In the `test-ios` job's `Build for iOS` step, add `-skipPackagePluginValidation ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` (note: `ARCHS=arm64` is not applicable to iOS Simulator destination)
4. In the `test-ios` job's `Test on iOS` step (`test-without-building`), add matching flags
5. Verify the workflow YAML is valid (no syntax errors)
6. Confirm both job names remain exactly `Test on macOS` and `Test on iOS Simulator` (required status check names)

**Exit criteria**:
- [ ] `tests.yml` `test-macos` job `Test` step includes all 4 flags: `-skipPackagePluginValidation`, `ARCHS=arm64`, `ONLY_ACTIVE_ARCH=YES`, `COMPILER_INDEX_STORE_ENABLE=NO` — verify with: `grep -c 'skipPackagePluginValidation\|ARCHS=arm64\|ONLY_ACTIVE_ARCH\|COMPILER_INDEX_STORE' .github/workflows/tests.yml` returns ≥ 4
- [ ] `tests.yml` is valid YAML: `python3 -c "import yaml, sys; yaml.safe_load(sys.stdin)" < .github/workflows/tests.yml` exits 0
- [ ] Job names unchanged: `grep 'name: Test on macOS' .github/workflows/tests.yml` and `grep 'name: Test on iOS Simulator' .github/workflows/tests.yml` each return exactly 1 match

---

## WU-2: Integration Gate Migration

**Goal**: Replace the compile-time `#if INTEGRATION_TESTS` gate in `IntegrationTests.swift` with the runtime `ProcessInfo.processInfo.environment` guard pattern required by §1 and §5a.

**Environment**: Local only — integration tests are never required for CI

---

### Sortie 2: Migrate Integration Tests to Runtime Environment Guard

**Priority**: 22.5 — Second-highest: 7 sorties require runtime gate to be correct

**Agent**: Supervising agent (has xcodebuild build step)

**Entry criteria**:
- [ ] First sortie in its track — no prerequisites
- [ ] `Tests/SwiftAcervoTests/IntegrationTests.swift` uses `#if INTEGRATION_TESTS` compile-time gating (confirmed: line 13 of the file)

**Tasks**:
1. Read `Tests/SwiftAcervoTests/IntegrationTests.swift` in full
2. Remove the outer `#if INTEGRATION_TESTS` / `#endif` wrapper (lines 13 and 499)
3. Move `import Testing`, `import Foundation`, `@testable import SwiftAcervo` to the top of the file (outside the `#if` block — they are currently inside it)
4. In each `@Test` function body, add the runtime guard at the very top (before any other work):
   ```swift
   guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else {
       Issue.record("Set INTEGRATION_TESTS=1 to run live CDN integration tests")
       return
   }
   ```
   The file has 9 `@Test` functions — each must get this guard
5. Verify no `XCTSkip`, `#skip`, or silent early returns remain
6. Check `Package.swift` for any target conditions excluding `IntegrationTests.swift` from the default build; remove any such conditions so the file compiles unconditionally
7. Build to confirm the file compiles without `OTHER_SWIFT_FLAGS`:
   ```bash
   xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `grep -c '#if INTEGRATION_TESTS' Tests/SwiftAcervoTests/IntegrationTests.swift` returns 0
- [ ] `grep -c 'Issue.record' Tests/SwiftAcervoTests/IntegrationTests.swift` returns ≥ 9 (one per `@Test` function)
- [ ] `grep -c 'XCTSkip\|#skip' Tests/SwiftAcervoTests/IntegrationTests.swift` returns 0
- [ ] `xcodebuild build -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

## WU-3: Slugify Discrepancy Resolution

**Goal**: Correct `TESTING_REQUIREMENTS.md` §4a to match the actual `Acervo.slugify` implementation, and add the missing test coverage identified in the gap analysis.

**Environment**: CI — this touches TESTING_REQUIREMENTS.md and CI-gated tests

**Pre-resolved context**: Q1 is resolved. The implementation is `modelId.replacingOccurrences(of: "/", with: "_")` — spaces and uppercase are preserved unchanged. Existing tests confirm this. The fix is to update §4a (not the implementation).

---

### Sortie 3: Correct §4a and Add Missing slugify + customBaseDirectory Tests

**Priority**: 2.75 — No downstream sorties depend on this; run last in Layer 1

**Agent**: Supervising agent (has xcodebuild test step)

**Entry criteria**:
- [ ] First sortie in its track — no prerequisites
- [ ] `Sources/SwiftAcervo/Acervo.swift` `slugify` implementation is readable: `modelId.replacingOccurrences(of: "/", with: "_")`
- [ ] `TESTING_REQUIREMENTS.md` §4a is readable (currently incorrect — claims spaces/uppercase conversion)

**Tasks**:
1. Read `Sources/SwiftAcervo/Acervo.swift` lines 110–118 to confirm slugify implementation (do not modify source)
2. Read `Tests/SwiftAcervoTests/AcervoPathTests.swift` to confirm existing slugify tests
3. Update `TESTING_REQUIREMENTS.md` §4a bullet 3 to read: `Acervo.slugify(_:)` converts `/` to `_` and preserves all other characters including spaces and uppercase
4. Add to `AcervoPathTests.swift`:
   - `@Test("slugify preserves spaces")` — assert `Acervo.slugify("org/model with spaces")` returns `"org_model with spaces"` (space preserved)
   - `@Test("slugify preserves uppercase")` — assert `Acervo.slugify("Org/Model-Name")` returns `"Org_Model-Name"` (uppercase preserved)
   - `@Test("customBaseDirectory redirects sharedModelsDirectory")` — set `Acervo.customBaseDirectory = tempRoot`, assert `Acervo.sharedModelsDirectory.path.hasPrefix(tempRoot.path)`, then restore `Acervo.customBaseDirectory = nil` in defer. Use a unique `UUID()`-based temp dir.
5. Run the full test suite to confirm all new tests pass:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `grep "converts.*spaces\|spaces.*uppercase" TESTING_REQUIREMENTS.md` returns 0 (old incorrect claim is gone)
- [ ] `grep "preserves all other characters" TESTING_REQUIREMENTS.md` returns 1 match (new correct claim present)
- [ ] `grep -c "slugify preserves spaces\|slugify preserves uppercase" Tests/SwiftAcervoTests/AcervoPathTests.swift` returns 2
- [ ] `grep -c "customBaseDirectory redirects" Tests/SwiftAcervoTests/AcervoPathTests.swift` returns 1
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

## WU-4: Requirements Gap Tests — Filesystem Edge Cases

**Goal**: Add tests for coverage gaps §7 priorities 2, 3, and 8 (disk-full, file permission denial, symlinks in model directory).

**Environment**: CI — these are unit tests with no network dependency

---

### Sortie 4: Disk-Full and File Permission Tests

**Priority**: 5.75 — Sortie 5 depends on this sortie

**Agent**: Supervising agent (has xcodebuild test step)

**Entry criteria**:
- [ ] WU-1 Sortie 1 is COMPLETED (CI flags are correct)
- [ ] WU-2 Sortie 2 is COMPLETED (integration gate is runtime-based)
- [ ] `Tests/SwiftAcervoTests/` directory structure is understood

**Tasks**:
1. Create `Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift`
2. Add `@Suite("Filesystem Edge Cases")` with Swift 6 strict concurrency
3. Write test: file permission denial on model directory — create a temp dir via `customBaseDirectory` pattern, make it non-writable (`try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tempDir.path)`), attempt `Acervo.listModels(in:)` or equivalent write operation, verify a descriptive error is thrown (not a crash), restore permissions in `defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path) }` before cleanup
4. Write test: disk-full simulation — since macOS has no built-in disk-full simulation API, write a test that uses a file path that cannot be created (e.g., attempts to create a directory where a file already exists). Verify `.directoryCreationFailed` or equivalent error is thrown. Add a comment: `// NOTE: True disk-full simulation requires a ramdisk; this test verifies error handling for a path-creation failure as the closest unit-testable equivalent.`
5. Each test must use the `customBaseDirectory` isolation pattern from §6 of TESTING_REQUIREMENTS.md
6. All tests must use `#expect()` / `#require()` — no `XCTAssert*`
7. Run the full test suite:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `ls Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` exits 0 (file exists)
- [ ] `grep -c '@Test' Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` returns ≥ 2
- [ ] `grep -c 'posixPermissions\|chmod\|0o000\|0o755' Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` returns ≥ 1 (permission denial test is present)
- [ ] `grep -c 'customBaseDirectory' Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` returns ≥ 2 (isolation pattern used in each test)
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

### Sortie 5: Symlink Edge Cases in Model Discovery

**Priority**: 2.75 — No further downstream dependencies within WU-4

**Agent**: Supervising agent (has xcodebuild test step)

**Entry criteria**:
- [ ] Sortie 4 is COMPLETED
- [ ] `Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` exists

**Tasks**:
1. Read `Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` to understand existing structure
2. Read the `Acervo.listModels(in:)` source implementation to determine its behavior contract for symlinks (does it follow, skip, or error on broken symlinks?)
3. Append a `@Suite("Symlink Discovery Edge Cases")` to `AcervoFilesystemEdgeCaseTests.swift`
4. Write test: symlink in model directory is followed — create a real model dir via `makeFakeModel`, create a symlink to it using `FileManager.default.createSymbolicLink(atPath:withDestinationPath:)`, verify `listModels` does not double-count or error
5. Write test: broken symlink in model directory — create a symlink pointing to a nonexistent target, verify `listModels` does not crash or throw (should skip or return partial results per implementation contract — test whichever the source defines)
6. Write test: deleting a symlinked model — verify delete removes the symlink entry without following it to real data (if applicable per implementation)
7. All tests use `customBaseDirectory` isolation and `makeFakeModel` helper from §6 of TESTING_REQUIREMENTS.md
8. Use `FileManager.default.createSymbolicLink(atPath:withDestinationPath:)` for symlink creation
9. Run the full test suite:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `grep -c 'createSymbolicLink' Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` returns ≥ 2 (at least two symlink tests)
- [ ] `grep -c '@Test' Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` returns ≥ 5 (2 from Sortie 4 + 3 from Sortie 5)
- [ ] `grep -c 'customBaseDirectory' Tests/SwiftAcervoTests/AcervoFilesystemEdgeCaseTests.swift` returns ≥ 5 (isolation used in all tests)
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

## WU-5: Requirements Gap Tests — Manifest & Registry

**Goal**: Add tests for coverage gap §7 priority 4 (manifest version boundary values 0 and 99) and verify the full set of §4e manifest requirements.

**Environment**: CI — pure unit tests, no network

---

### Sortie 6: Manifest Version Boundary Tests

**Priority**: 1.5 — No downstream dependencies; lowest risk in Layer 2

**Agent**: Supervising agent (has xcodebuild test step)

**Entry criteria**:
- [ ] WU-1 Sortie 1 is COMPLETED
- [ ] WU-2 Sortie 2 is COMPLETED
- [ ] `Tests/SwiftAcervoTests/CDNManifestTests.swift` is readable

**Tasks**:
1. Read `Tests/SwiftAcervoTests/CDNManifestTests.swift` to understand existing test structure and which §4e items are already covered
2. Read `Sources/SwiftAcervo/CDNManifest.swift` to understand version validation logic
3. Add missing §4e tests to `CDNManifestTests.swift`. For each test, only add it if not already present — check by searching for the relevant behavior:
   - `@Test("Manifest version 0 returns manifestVersionUnsupported(0)")` — decode a manifest JSON with `"manifestVersion": 0` and verify the validation function returns/throws `.manifestVersionUnsupported(0)`
   - `@Test("Manifest version 99 returns manifestVersionUnsupported(99)")` — same for version 99
   - `@Test("CDNManifestFile sha256 field preserved exactly — no lowercasing")` — decode a manifest with a mixed-case sha256 value (e.g., `"AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789"`) and verify the stored value is character-for-character identical to the input
   - `@Test("Manifest fails to decode JSON missing required version field")` — decode JSON without `"manifestVersion"` key, verify decode throws or returns nil
   - `@Test("Model ID mismatch returns manifestModelIdMismatch")` — verify the validation function throws `.manifestModelIdMismatch` when the request model ID differs from the manifest's `modelId` field
4. All assertions use `#expect()` or `#require()` — no `XCTAssert*`
5. Run the full test suite:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `grep -c 'version 0\|manifestVersion.*0\|unsupported.*0' Tests/SwiftAcervoTests/CDNManifestTests.swift` returns ≥ 1
- [ ] `grep -c 'version 99\|manifestVersion.*99\|unsupported.*99' Tests/SwiftAcervoTests/CDNManifestTests.swift` returns ≥ 1
- [ ] `grep -c 'sha256.*case\|case.*sha256\|lowercas\|preserved' Tests/SwiftAcervoTests/CDNManifestTests.swift` returns ≥ 1
- [ ] `grep -c 'missing.*version\|missing.*required\|manifestVersion.*missing' Tests/SwiftAcervoTests/CDNManifestTests.swift` returns ≥ 1 (or the test exists under a different name — verify presence of `#expect(throws:)` for missing-field decoding)
- [ ] `grep -c 'manifestModelIdMismatch\|mismatch' Tests/SwiftAcervoTests/CDNManifestTests.swift` returns ≥ 1
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

## WU-6: Requirements Gap Tests — Concurrency & Access Safety

**Goal**: Add tests for coverage gaps §7 priorities 5, 6, 7 (`withModelAccess`/`withComponentAccess` exception safety, concurrent `getAccessCount` verification, 10+ concurrent downloads stress test).

**Pre-execution note**: `AcervoManagerTests.swift` already has `withModelAccess lock released after closure throws custom error` (line 264). Sortie 7 must check whether `withComponentAccess` has an equivalent before writing a new test. `AcervoConcurrencyTests.swift` already has `concurrentAccessesTrackStatistics` (line 224) testing `getAccessCount` under 5 concurrent accesses. Sortie 8 must check if this satisfies §7 gap 7 (it covers concurrent `getAccessCount` but only 5 accesses, not 10+) and determine if a new test is needed.

**Environment**: CI for gaps 6 and 7; local-annotated (tagged, not excluded) for gap 5 stress test

---

### Sortie 7: Exception Safety for withModelAccess and withComponentAccess

**Priority**: 5.75 — Sortie 8 depends on this sortie

**Agent**: Supervising agent (has xcodebuild test step)

**Entry criteria**:
- [ ] WU-1 Sortie 1 is COMPLETED
- [ ] WU-2 Sortie 2 is COMPLETED
- [ ] `Tests/SwiftAcervoTests/AcervoManagerTests.swift` is readable
- [ ] `Tests/SwiftAcervoTests/ComponentAccessTests.swift` is readable

**Tasks**:
1. Read `Tests/SwiftAcervoTests/AcervoManagerTests.swift` around lines 264–280 — confirm the existing test `"withModelAccess lock released after closure throws custom error"` exists and covers: single-call exception, lock released, second call succeeds
2. Determine if the existing test satisfies gap 6: if it verifies that a **subsequent** `withModelAccess` call succeeds after the first threw (i.e., the lock is not leaked), the `withModelAccess` part of gap 6 is already covered. If it only checks `isLocked` returns false (not that a subsequent call succeeds), add `@Test("withModelAccess subsequent access succeeds after closure throws")` that makes a second `withModelAccess` call and verifies it completes
3. Read `Tests/SwiftAcervoTests/ComponentAccessTests.swift` — confirm whether any test covers the case where a throwing closure in `withComponentAccess` releases the component lock for a subsequent call
4. If no such test exists: add `@Test("withComponentAccess releases lock when perform closure throws")` to `ComponentAccessTests.swift` — set up a registered component with files on disk, call `withComponentAccess` with a closure that throws `AcervoError.directoryCreationFailed("test")`, verify `isLocked` returns false afterward, then verify a second `withComponentAccess` call completes successfully
5. Add `@Test("withModelAccess lock not leaked under concurrent throws")` to `AcervoManagerTests.swift` — dispatch 3 concurrent `withModelAccess` calls for the same model ID, each with a throwing closure, verify all eventually complete (no deadlock) and `isLocked` returns false after the task group finishes. Use `withTaskGroup` and `@Sendable` closures.
6. Run the full test suite:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `grep -c 'withComponentAccess.*throws\|throws.*withComponentAccess\|releases lock.*throws\|lock.*throws.*component' Tests/SwiftAcervoTests/ComponentAccessTests.swift` returns ≥ 1 (or a functionally equivalent test exists — use judgment)
- [ ] `grep -c 'concurrent.*throws\|throws.*concurrent' Tests/SwiftAcervoTests/AcervoManagerTests.swift` returns ≥ 1
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

### Sortie 8: Concurrent getAccessCount and Stress Concurrency Test

**Priority**: 2.75 — No further downstream dependencies within WU-6

**Agent**: Supervising agent (has xcodebuild test step)

**Entry criteria**:
- [ ] Sortie 7 is COMPLETED

**Tasks**:
1. Read `Tests/SwiftAcervoTests/AcervoConcurrencyTests.swift` lines 224–252 — inspect `concurrentAccessesTrackStatistics` test: it uses 5 concurrent accesses and verifies `getAccessCount` equals baseline + 5. Determine if this satisfies §7 gap 7 ("verified under concurrent access"). If yes, note it as already covered and skip adding a new `getAccessCount` test. If it only uses 5 tasks (not truly stress), add `@Test("getAccessCount reflects all concurrent increments — 10 tasks")` using 10 concurrent `withModelAccess` calls to the same model and verify `getAccessCount` equals N afterward.
2. Create `Tests/SwiftAcervoTests/AcervoStressConcurrencyTests.swift` for the 10+ concurrent downloads stress test (§7 gap 5)
3. Mark the stress test suite with `.serialized` and a custom tag comment: `// STRESS: This suite is NOT excluded from CI but its timeLimit is generous. If wall time exceeds 5s, investigate.`
4. Write `@Test("12 concurrent downloads of different models complete without deadlock", .timeLimit(.minutes(2)))` — dispatch 12 `withModelAccess` calls for distinct model IDs concurrently via `withTaskGroup(of: Bool.self)`; verify all complete (count == 12), no deadlock, and `isLocked` returns false for all model IDs afterward. Use `@Sendable` closures and unique model IDs via `UUID()`.
5. Add a comment above the suite: `// NOTE: This test is deliberately not excluded from CI. The .timeLimit(.minutes(2)) annotation allows generous wall time. If any run approaches 5 seconds, the locking implementation needs investigation.`
6. Run the full test suite:
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO
   ```

**Exit criteria**:
- [ ] `ls Tests/SwiftAcervoTests/AcervoStressConcurrencyTests.swift` exits 0 (file exists)
- [ ] `grep -c '@Test' Tests/SwiftAcervoTests/AcervoStressConcurrencyTests.swift` returns ≥ 1
- [ ] `grep -c 'timeLimit\|\.minutes' Tests/SwiftAcervoTests/AcervoStressConcurrencyTests.swift` returns ≥ 1
- [ ] `grep -c '@Sendable' Tests/SwiftAcervoTests/AcervoStressConcurrencyTests.swift` returns ≥ 1
- [ ] `xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO` exits 0

---

## WU-7: CI Green Verification

**Goal**: Confirm the entire test suite passes on both macOS and iOS Simulator with all required flags, and that the required status checks are properly configured in branch protection.

**Environment**: CI and local

---

### Sortie 9: Full Test Suite Verification and Branch Protection Audit

**Priority**: 2.0 — Verification only; runs last by design

**Agent**: Supervising agent (runs full xcodebuild test suite)

**Entry criteria**:
- [ ] WU-1 through WU-6 all COMPLETED
- [ ] All new test files committed to branch
- [ ] Sorties 1–8 exit criteria verified

**Tasks**:
1. Run macOS verification:
   ```bash
   xcodebuild test \
     -scheme SwiftAcervo \
     -destination 'platform=macOS,arch=arm64' \
     -skipPackagePluginValidation \
     ARCHS=arm64 \
     ONLY_ACTIVE_ARCH=YES \
     COMPILER_INDEX_STORE_ENABLE=NO
   ```
   Confirm exit code 0 and all tests pass
2. Run iOS Simulator verification:
   ```bash
   xcodebuild test \
     -scheme SwiftAcervo \
     -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.1' \
     -skipPackagePluginValidation \
     ONLY_ACTIVE_ARCH=YES \
     COMPILER_INDEX_STORE_ENABLE=NO
   ```
   Confirm exit code 0
3. Check branch protection for required status checks:
   ```bash
   gh api repos/intrusive-memory/SwiftAcervo/branches/main/protection
   ```
   If `Test on macOS` and `Test on iOS Simulator` are not listed as required contexts, update:
   ```bash
   gh api --method PUT repos/intrusive-memory/SwiftAcervo/branches/main/protection \
     --input <(cat <<'EOF'
   {
     "required_status_checks": {
       "strict": true,
       "contexts": ["Test on macOS", "Test on iOS Simulator"]
     },
     "enforce_admins": false,
     "required_pull_request_reviews": null,
     "restrictions": null
   }
   EOF
   )
   ```
4. Check xcodebuild output for total test duration. If any individual test takes ≥ 5 seconds in xcodebuild output, note the test name in a comment
5. Verify integration tests emit `Issue.record` output (not silent pass) by running without the env var and checking output contains "Set INTEGRATION_TESTS=1":
   ```bash
   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO 2>&1 | grep -c "Set INTEGRATION_TESTS=1"
   ```
   Result must be ≥ 9 (one per integration test function)

**Exit criteria**:
- [ ] `xcodebuild test` for macOS exits 0 with all tests passing
- [ ] `xcodebuild test` for iOS Simulator exits 0 with all tests passing
- [ ] `gh api repos/intrusive-memory/SwiftAcervo/branches/main/protection` output contains `"Test on macOS"` and `"Test on iOS Simulator"` in `required_status_checks.contexts`
- [ ] `xcodebuild test ... 2>&1 | grep -c "Set INTEGRATION_TESTS=1"` returns ≥ 9
- [ ] No individual test in xcodebuild output takes ≥ 5 seconds (or if any does, it is flagged with a comment)

---

## Open Questions (Unresolved)

| # | Question | Blocks | Status |
|---|----------|--------|--------|
| Q2 | What is the intended behavior for `Acervo.listModels` with a broken symlink — skip, error, or return partial results? | Sortie 5 | Agent must inspect source and test whichever behavior is implemented |

---

## Sortie Dispatch Order (Dependency Graph)

```
Layer 1 (parallel — no shared file dependencies):
  Sortie 1 — CI workflow flags        [WU-1] — SUB-AGENT
  Sortie 2 — Integration gate fix     [WU-2] — SUPERVISING AGENT
  Sortie 3 — Slugify resolution       [WU-3] — SUPERVISING AGENT

  Supervising agent handles S2 then S3.
  Sub-agent handles S1 concurrently.

Layer 2 (parallel clusters, after Layer 1 completes):
  Cluster A: Sortie 4 → Sortie 5      [WU-4] — SUPERVISING AGENT (sequential)
  Cluster B: Sortie 6                 [WU-5] — SUPERVISING AGENT
  Cluster C: Sortie 7 → Sortie 8     [WU-6] — SUPERVISING AGENT (sequential)

  All Layer 2 sorties have xcodebuild steps → serialized through supervising agent.
  Recommended execution order: S4, S6, S7, S5, S8 (or S4, S7, S6, S5, S8).

Layer 3:
  Sortie 9 — Full verification        [WU-7] — SUPERVISING AGENT
```

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 7 |
| Total sorties | 9 |
| Layer 1 sorties (parallel) | 3 |
| Layer 2 sorties (partially parallel) | 5 |
| Layer 3 sorties | 1 |
| Dependency structure | Layered with intra-WU sequential ordering |
| CI-gated sorties | 1, 2, 3, 4, 5, 6, 7, 8, 9 |
| Local-only tests introduced | Stress test in Sortie 8 (tagged `.timeLimit`, not excluded from CI) |
| Requirements detected | 62 |
| Atomic tasks | 41 |
| Open questions | 1 (Q2 — resolved by agent at runtime; not a blocker) |
| Pre-resolved questions | Q1 (slugify behavior), Q3 (integration test model ID) |
| Sub-agents used | 1 (Sortie 1 only — no xcodebuild) |
| Context budget | 50 turns per sortie |
| Estimated turns per sortie | 11–16 (all right-sized) |
