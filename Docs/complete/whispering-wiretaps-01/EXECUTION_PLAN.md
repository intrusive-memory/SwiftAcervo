---
feature_name: OPERATION WHISPERING WIRETAPS
starting_point_commit: 0bac62b29a72235b430a87251ef2217c5ff84c7c
mission_branch: instrumentation/01
iteration: 1
state: completed
mission: whispering-wiretaps-01
updated: 2026-05-12
---

# EXECUTION_PLAN.md — SwiftAcervo Instrumentation

**Source requirements:** `Docs/REQUIREMENTS-instrumentation.md`
**Target branch:** `instrumentation/01` (cross-repo coordinated naming; see `/Users/stovak/Projects/Vinetas/EXECUTION_PLAN.md`)
**Release type:** Our next minor release version (additive: new public types + new optional parameters with defaults + new setters; no breaking API changes).
**Build/test:** Prefer XcodeBuildMCP `swift_package_build` / `swift_package_test`, or the repo Makefile (`make build`, `make test`). **Never** `swift build` / `swift test`.

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Scope

Add a host-side telemetry hook surface (`AcervoTelemetryEvent`, `AcervoTelemetryReporter`) to SwiftAcervo, wire emission sites across the download / manifest / integrity / cache / CDN / error paths per requirements §3–§5, prove the surface with in-library tests per §7, and ship a minor release so downstream libraries (flux-2-swift-mlx, pixart-swift-mlx, SwiftVinetas) can pin against it.

**Coexists with** (does not replace): `AcervoDownloadProgress` / `AcervoPublishProgress` / `AcervoDeleteProgress` callbacks, existing `os.Logger` call sites.

**Out of scope** (requirements §8): per-byte progress events, telemetry on internal value-type helpers (`SigV4Signer`, `CacheBypassingRequest`, `LevenshteinDistance`), persistent telemetry inside the library, network-quality estimation / RTT histograms.

**Out of scope for this plan** (host-side, lives in Vinetas repo): §6 `AcervoTelemetryAdapter` mapping. Tracked in `/Users/stovak/Projects/Vinetas/EXECUTION_PLAN.md`.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| SwiftAcervo Instrumentation | `/Users/stovak/Projects/SwiftAcervo` | 8 | — | none |

Single-work-unit plan. Layering is handled at the sortie level via entry/exit criteria.

---

## Parallelism Structure

**Critical Path**: Sortie 1 → 2 → 3 → 4 → 5a → 5b → 6a → 6b (length: 8 sorties, sequential).

**Parallel Execution Groups**: None internal to SwiftAcervo — the mission is intrinsically sequential because each emission-wiring sortie depends on the surface introduced by the previous one.

**One narrow opportunity inside Sortie 6a**: the four new test files are independent of each other and could be authored by 4 parallel sub-agents (no builds). The supervising agent runs the build and overhead-measurement steps afterwards. This is a useful sub-agent dispatch only if the supervisor wants to compress wall-clock time inside that one sortie — see Sortie 6a annotation.

**Agent Constraints**:
- **Supervising agent**: handles every sortie that builds, tests, releases, or tags.
- **Sub-agents (up to 4)**: only Sortie 6a's test file authoring is sub-agent-eligible. Sub-agents do NOT run `swift_package_build` / `swift_package_test`.

**Cross-mission parallelism**: SwiftAcervo is one of five sibling missions (flux-2-swift-mlx, pixart-swift-mlx, SwiftVinetas, etc.) coordinated from `/Users/stovak/Projects/Vinetas/EXECUTION_PLAN.md`. SwiftAcervo is foundational — host-side adapter mapping (§6) blocks on its release tag, so SwiftAcervo should ship first.

---

### Sortie 1: Public telemetry types

**Priority**: 8.5 — foundation score 1 (every later sortie depends on these types); dependency depth = 7 (blocks every other sortie); risk = 1 (new files, no existing surface to disturb); complexity = 0.5.

**Entry criteria**:
- [ ] First sortie — no prerequisites.
- [ ] Git working tree is clean.
- [ ] Branch `instrumentation/01` exists and is checked out. Verify with `git rev-parse --abbrev-ref HEAD` returns `instrumentation/01`. If absent, create it: `git checkout -b instrumentation/01` from the current default branch HEAD.

**Tasks**:
1. Create `Sources/SwiftAcervo/Telemetry/AcervoTelemetryEvent.swift` with the `public enum AcervoTelemetryEvent: Sendable` declaration **exactly as specified in requirements §3.1** — all case shapes (lifecycle, per-component, manifest, integrity, cache, CDN, boundary memory `modelLoadComplete`, error side-channel) plus nested `CacheMissReason` and `ErrorPhase` enums.
2. Create `Sources/SwiftAcervo/Telemetry/AcervoTelemetryReporter.swift` with the `public protocol AcervoTelemetryReporter: Sendable` (one `async` non-throwing `capture(_:)` method) and the `public struct NoopAcervoTelemetryReporter` no-op implementation **exactly as in requirements §3.2**.
3. Confirm `Package.swift` requires no new module dependencies (the new files use only `Foundation`).

**Exit criteria**:
- [ ] `swift_package_build` (or `make build`) exits 0.
- [ ] `test -f Sources/SwiftAcervo/Telemetry/AcervoTelemetryEvent.swift && test -f Sources/SwiftAcervo/Telemetry/AcervoTelemetryReporter.swift` exits 0.
- [ ] `grep -c "case downloadOperationStart\|case downloadOperationComplete\|case componentDownloadStart\|case componentDownloadComplete\|case manifestFetchStart\|case manifestFetchComplete\|case integrityVerifyStart\|case integrityVerifyComplete\|case cacheHit\|case cacheMiss\|case cdnRequest\|case modelLoadComplete\|case errorThrown" Sources/SwiftAcervo/Telemetry/AcervoTelemetryEvent.swift` returns ≥ 13.
- [ ] `git diff --stat Package.swift` reports no lines changed (no new module deps).
- [ ] `grep -rn "Logger(subsystem" Sources/SwiftAcervo/Telemetry/` returns zero matches.

---

### Sortie 2: Setter injection on public actors

**Priority**: 7.0 — foundation score 1 (introduces the storage surface every emission site reads); dependency depth = 6; risk = 1; complexity = 0.5.

**Entry criteria**:
- [ ] Sortie 1 exit criteria all met.
- [ ] `git status` shows clean tree or only Sortie-1 commits on `instrumentation/01`.

**Tasks**:
1. Add `private var telemetry: (any AcervoTelemetryReporter)? = nil` and `public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)` to `AcervoManager` (`Sources/SwiftAcervo/AcervoManager.swift`, near line 36).
2. Add the same stored property + setter to `ModelDownloadManager` (`Sources/SwiftAcervo/ModelDownloadManager.swift`, near line 119).
3. Add the same stored property + setter to `S3CDNClient` (`Sources/SwiftAcervo/S3CDNClient.swift`, near line 108).
4. Add the same stored property + setter to `ManifestGenerator` (`Sources/SwiftAcervo/ManifestGenerator.swift`, near line 47).
5. No call sites elsewhere are modified — this sortie is storage + setter only.

**Exit criteria**:
- [ ] `swift_package_build` exits 0.
- [ ] `grep -rn "public func setTelemetry" Sources/SwiftAcervo/AcervoManager.swift Sources/SwiftAcervo/ModelDownloadManager.swift Sources/SwiftAcervo/S3CDNClient.swift Sources/SwiftAcervo/ManifestGenerator.swift | wc -l` returns exactly 4.
- [ ] `grep -rn "private var telemetry: (any AcervoTelemetryReporter)?" Sources/SwiftAcervo/ | wc -l` returns exactly 4.
- [ ] `grep -rn "telemetry?.capture" Sources/SwiftAcervo/ | wc -l` returns 0 (no emission sites yet).

---

### Sortie 3: Defaulted parameter on internal/static surfaces

**Priority**: 6.5 — foundation score 1 (parameter threading consumed by emission sortie); dependency depth = 5; risk = 2 (touches static API surface — must preserve existing callers); complexity = 1.

**Entry criteria**:
- [ ] Sortie 2 exit criteria all met.

**Tasks**:
1. Add `telemetry: (any AcervoTelemetryReporter)? = nil` defaulted parameter to `AcervoDownloader.fetchManifest(...)`, `AcervoDownloader.downloadFile(...)`, and `AcervoDownloader.verifyIntegrity(...)` in `Sources/SwiftAcervo/AcervoDownloader.swift` (per requirements §4.2).
2. Add the defaulted `telemetry:` parameter to any `IntegrityVerification` method (`Sources/SwiftAcervo/IntegrityVerification.swift`) that performs verification.
3. Add the defaulted `telemetry:` parameter to `Acervo.download(...)`, `Acervo.publish(...)`, and `Acervo.delete(...)` static functions in `Sources/SwiftAcervo/Acervo.swift` per requirements §4.3. The existing `progress:` callback must remain untouched.
4. Thread the parameter through internal call sites so a single reporter passed in at the public-API entry reaches every downstream `AcervoDownloader` / `IntegrityVerification` call. **Do not emit any events** — wiring only.
5. Explicitly do NOT modify `HydrationCoalescer` (per §4.2: its work is observable from `AcervoManager`).

**Exit criteria**:
- [ ] `swift_package_build` exits 0.
- [ ] All existing test targets compile (no call sites broken by parameter addition): `swift_package_test` (or `make test`) exits 0 with the existing suite still green.
- [ ] `grep -n "telemetry: (any AcervoTelemetryReporter)?" Sources/SwiftAcervo/AcervoDownloader.swift | wc -l` returns ≥ 3 (one per method).
- [ ] `grep -n "telemetry: (any AcervoTelemetryReporter)?" Sources/SwiftAcervo/Acervo.swift | wc -l` returns ≥ 3 (download/publish/delete).
- [ ] `grep -n "progress:" Sources/SwiftAcervo/Acervo.swift` shows the same signature lines as on the previous commit (no progress-callback drift).
- [ ] `grep -n "setTelemetry\|telemetry:" Sources/SwiftAcervo/Acervo.swift | grep -i "HydrationCoalescer"` returns zero matches (coalescer untouched).

---

### Sortie 4: Lifecycle, manifest, per-component, CDN emission wiring

**Priority**: 5.5 — dependency depth = 4; foundation score 0; risk = 2 (touches hot paths in `S3CDNClient`); complexity = 2 (5 emission sites across 4 files).

**Entry criteria**:
- [ ] Sortie 3 exit criteria all met.

**Tasks**:
1. Emit `downloadOperationStart` at the entry of `Acervo.download(...)` (`Acervo.swift`) and `AcervoManager.download(...)` (`AcervoManager.swift:319`). Emit `downloadOperationComplete` on successful return. Snapshot `offlineMode` at entry; measure wall-clock duration entry→return.
2. Emit `manifestFetchStart` at the start of `AcervoDownloader.fetchManifest(...)` (~`AcervoDownloader.swift:214`) before URLSession dispatch. Emit `manifestFetchComplete` after successful decode (~line 253) carrying `manifest.manifestVersion`, `manifest.files.count`, `manifest.totalBytes`. **Verify the line numbers by `grep -n "func fetchManifest" Sources/SwiftAcervo/AcervoDownloader.swift`** before editing — line numbers in the requirements are approximate.
3. Emit `componentDownloadStart` at the per-file loop entry in `downloadFile(...)` (~line 313). Emit `componentDownloadComplete` at successful per-file completion (~line 430). Throughput formula: `actualBytes / durationSeconds / 1_048_576`. Per §5 hot-path discipline, **measure duration from start-of-body-read, not start-of-request** (TCP handshake skews the number).
4. Emit `cdnRequest` in `S3CDNClient.send(...)` / URLSession completion (`S3CDNClient.swift`). One per HTTP request, including 404s. Guard payload construction with `guard let telemetry else { return }` so URL/header construction is skipped when reporter is nil.
5. Every emission must follow the pattern `guard let telemetry else { return }; await telemetry.capture(.case(...))` — or an equivalent compile-time-checked optional pattern — so payload construction is skipped when reporter is nil.

**Exit criteria**:
- [ ] `swift_package_build` exits 0.
- [ ] `swift_package_test` (existing suite) exits 0.
- [ ] `grep -c "telemetry?.capture\|await telemetry.capture" Sources/SwiftAcervo/Acervo.swift Sources/SwiftAcervo/AcervoManager.swift Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/S3CDNClient.swift | awk -F: '{s+=$2} END {print s}'` returns ≥ 8 (lifecycle start+complete in both call sites = 4; manifest start+complete = 2; component start+complete = 2; cdnRequest = ≥ 1).
- [ ] `grep -rn "print(" Sources/SwiftAcervo/Telemetry/ Sources/SwiftAcervo/Acervo.swift Sources/SwiftAcervo/AcervoManager.swift Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/S3CDNClient.swift` shows no NEW `print(` lines vs. baseline.
- [ ] No new `Logger(` instances introduced: `git diff --stat Sources/SwiftAcervo/*.swift | grep -i "logger" | wc -l` returns 0 (or, if Logger appears in diff, it must be unchanged context, not an addition).

---

### Sortie 5a: Integrity, cache, and boundary-memory emission wiring

**Priority**: 4.5 — dependency depth = 3; foundation 0; risk = 2 (integrity verifier touches a critical correctness path); complexity = 1.5.

**Entry criteria**:
- [ ] Sortie 4 exit criteria all met.

**Tasks**:
1. Emit `integrityVerifyStart` at `IntegrityVerification` entry. Emit `integrityVerifyComplete` at exit on both `passed: true` AND `passed: false` paths. On `passed: false`, emit **before** the throw. Emit even on cache hits (verify-on-read, not just verify-on-download).
2. Emit `cacheHit` and `cacheMiss` from the cache lookup paths in `Sources/SwiftAcervo/Acervo.swift` and `Sources/SwiftAcervo/AcervoManager.swift`, **before** any network IO. Populate `CacheMissReason` from the actual decision: `.notPresent`, `.shaChangedRemote`, `.sizeChangedRemote`, `.corrupted`, `.forcedRefresh`.
3. Emit `modelLoadComplete` after the last component is verified for a model (whether downloaded or cache-hit). Add a code comment at the emission site stating: `// Adapter routes this event through captureWithMemorySnapshot; library emits normally.`

**Exit criteria**:
- [ ] `swift_package_build` exits 0.
- [ ] `swift_package_test` (existing suite) exits 0.
- [ ] `grep -c "telemetry?.capture(.integrityVerifyStart\|telemetry?.capture(.integrityVerifyComplete" Sources/SwiftAcervo/IntegrityVerification.swift | awk -F: '{s+=$2} END {print s}'` returns ≥ 2.
- [ ] `grep -c "telemetry?.capture(.cacheHit\|telemetry?.capture(.cacheMiss" Sources/SwiftAcervo/Acervo.swift Sources/SwiftAcervo/AcervoManager.swift | awk -F: '{s+=$2} END {print s}'` returns ≥ 2.
- [ ] `grep -n "telemetry?.capture(.modelLoadComplete" Sources/SwiftAcervo/*.swift` returns exactly 1 emission site.
- [ ] `grep -n "captureWithMemorySnapshot" Sources/SwiftAcervo/*.swift` returns the documenting comment.
- [ ] All five `CacheMissReason` cases are referenced somewhere in `Sources/SwiftAcervo/`: `for r in notPresent shaChangedRemote sizeChangedRemote corrupted forcedRefresh; do grep -q ".$r" Sources/SwiftAcervo/*.swift || echo "MISSING: $r"; done` prints nothing.

---

### Sortie 5b: errorThrown emission wiring at every throw site

**Priority**: 4.0 — dependency depth = 2; risk = 2 (~23 sites must be paired correctly); complexity = 2.

**Entry criteria**:
- [ ] Sortie 5a exit criteria all met.

**Tasks**:
1. Discover every current `throw` site in `Sources/SwiftAcervo/AcervoDownloader.swift` and `Sources/SwiftAcervo/ModelDownloadManager.swift` via `grep -n "throw " Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/ModelDownloadManager.swift`. The lines in requirements §5 (178, 219, 231, 238, 246, 248, 253, 258, 267, 319, 329, 367, 406, 412, 424, 491, 500, 508, 606, 654 and 183, 272, 328) are approximate — use grep output as ground truth.
2. Immediately **before** each throw, emit `await telemetry?.capture(.errorThrown(phase: <ErrorPhase>, errorDescription: <String>, modelID: <String?>, fileName: <String?>))`. Use defer for cleanup symmetry if required.
3. Map each throw site to the right `ErrorPhase` value: `.manifestDownload`, `.manifestDecode`, `.manifestVersionUnsupported`, `.manifestIntegrity`, `.fileDownload`, `.fileDownloadSize`, `.fileDownloadIntegrity`, `.directoryCreation`, `.offlineMode`, `.s3Request`, `.other`.
4. Confirm the 5 existing `os.Logger` calls (`AcervoDownloader.swift:610`/`675`, `ModelDownloadManager.swift:180/269/325` — verify locations via grep) remain present and unchanged. Each is now paired with an `errorThrown` event immediately adjacent.

**Exit criteria**:
- [ ] `swift_package_build` exits 0.
- [ ] `swift_package_test` (existing suite) exits 0.
- [ ] Let `T = grep -c "^[[:space:]]*throw " Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/ModelDownloadManager.swift | awk -F: '{s+=$2} END {print s}'`. Let `E = grep -c "telemetry?.capture(.errorThrown" Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/ModelDownloadManager.swift | awk -F: '{s+=$2} END {print s}'`. `E >= T` MUST hold (at least one emission per throw site).
- [ ] Logger count unchanged: `grep -c "logger\\.error\|logger\\.warning" Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/ModelDownloadManager.swift | awk -F: '{s+=$2} END {print s}'` returns exactly 5.
- [ ] Every `ErrorPhase` case from requirements §3.1 is referenced at least once in the wiring: `for p in manifestDownload manifestDecode manifestVersionUnsupported manifestIntegrity fileDownload fileDownloadSize fileDownloadIntegrity directoryCreation offlineMode s3Request other; do grep -q ".$p" Sources/SwiftAcervo/AcervoDownloader.swift Sources/SwiftAcervo/ModelDownloadManager.swift || echo "MISSING: $p"; done` prints nothing.

---

### Sortie 6a: In-library tests and overhead baseline

**Priority**: 3.0 — dependency depth = 1; risk = 1; complexity = 2 (four test files + perf measurement).

**Parallelism note**: The four test files are independent file creations and are eligible for up to 4 sub-agent fan-out. The supervising agent retains the build + overhead-measurement steps. If a single agent dispatches this sortie, it authors all four files sequentially.

**Entry criteria**:
- [ ] Sortie 5b exit criteria all met.

**Tasks**:
1. Create `Tests/SwiftAcervoTests/AcervoTelemetryMockReporterTests.swift` with a `MockReporter: AcervoTelemetryReporter` that records every event into an array. Run a full `Acervo.download` against a mocked URL session. Assert: (a) event order matches the expected lifecycle (`downloadOperationStart` first, `downloadOperationComplete` last; `manifestFetch*` precedes `componentDownload*`); (b) every case in `AcervoTelemetryEvent` fires at least once across the test's scenarios; (c) `errorThrown` fires before the throw propagates.
2. Create `Tests/SwiftAcervoTests/AcervoTelemetryNoopOverheadTests.swift` running the same mocked `Acervo.download` with `nil` reporter vs. `NoopAcervoTelemetryReporter`, across 50 iterations each. Assert wall-clock median delta ≤ 2%.
3. Create `Tests/SwiftAcervoTests/AcervoTelemetryCacheMissReasonTests.swift` driving each `CacheMissReason` deterministically: forced refresh, on-disk SHA mismatch, size mismatch, not present, sha-changed-remote. Assert the matching reason fires for each scenario.
4. Create `Tests/SwiftAcervoTests/AcervoTelemetryIntegrityFailureTests.swift` injecting a fake on-disk file with a known wrong SHA. Assert (a) `integrityVerifyComplete(passed: false)` fires; (b) `errorThrown(phase: .fileDownloadIntegrity)` follows; (c) the throw propagates to the caller after both events have been recorded.
5. Sanity test inside `AcervoTelemetryMockReporterTests`: after `setTelemetry(nil)`, subsequent operations record zero events. Verify by clearing the mock array, calling `setTelemetry(nil)`, running another `Acervo.download`, then `XCTAssertTrue(mock.events.isEmpty)`.
6. Run the full test suite via `swift_package_test` (or `make test`).
7. Record the 50-iteration median wall-clock numbers from step 2 in `Tests/SwiftAcervoTests/AcervoTelemetryNoopOverheadTests.swift` as a code comment, for inclusion in the PR description.

**Exit criteria**:
- [ ] All four files exist: `for f in AcervoTelemetryMockReporterTests AcervoTelemetryNoopOverheadTests AcervoTelemetryCacheMissReasonTests AcervoTelemetryIntegrityFailureTests; do test -f "Tests/SwiftAcervoTests/${f}.swift" || echo "MISSING: $f"; done` prints nothing.
- [ ] `swift_package_test` exits 0 with all four new test classes reporting passes.
- [ ] `AcervoTelemetryNoopOverheadTests` reports median delta ≤ 2% (printed via XCTest output or recorded in a comment block in the test file).
- [ ] `grep -n "// OVERHEAD BASELINE:" Tests/SwiftAcervoTests/AcervoTelemetryNoopOverheadTests.swift` returns 1 line (baseline numbers committed for PR description harvest).

---

### Sortie 6b: Version bump, PR, and minor release tag

**Priority**: 2.0 — dependency depth = 0; risk = 1 (release operations are well-trodden); complexity = 1.

**Entry criteria**:
- [ ] Sortie 6a exit criteria all met.
- [ ] `git status` is clean except for the diff that constitutes the instrumentation work.

**Tasks**:
1. Bump SwiftAcervo to our next minor release version (additive surface per requirements §9). Update wherever the version is recorded in the repo (verify via `grep -rn "version\|Version" Package.swift Makefile 2>/dev/null` — if version lives only in git tags, this is a no-op for files).
2. Update `CHANGELOG.md` with a new entry for our next minor release version. The entry should mention: new public `AcervoTelemetryEvent` enum, new public `AcervoTelemetryReporter` protocol + `NoopAcervoTelemetryReporter`, new `setTelemetry(_:)` methods on `AcervoManager` / `ModelDownloadManager` / `S3CDNClient` / `ManifestGenerator`, new defaulted `telemetry:` parameter on `Acervo.download` / `.publish` / `.delete`, and the §7 test additions.
3. Open a PR from `instrumentation/01` against the repo's default branch. PR description copies the overhead-baseline numbers from `AcervoTelemetryNoopOverheadTests.swift` and links the requirements document.
4. After CI passes and PR merges, tag the next minor release version (highest existing semver tag + minor bump). Push the tag to origin.
5. Verify downstream consumers (flux-2-swift-mlx, pixart-swift-mlx, SwiftVinetas) can now pin against the new tag — note this in the PR comments or a release-notes file.

**Exit criteria**:
- [ ] PR exists on remote: `gh pr view --json url,state,mergedAt | jq -r '.url, .state'` returns a URL and `MERGED`.
- [ ] `git tag --list` includes a tag matching our next minor release version (verified by sorting all semver tags numerically and confirming the new tag is exactly one minor increment above the previous highest).
- [ ] `git ls-remote --tags origin | grep <new-tag>` returns one line (tag pushed to origin).
- [ ] `CHANGELOG.md` has a new entry referencing `AcervoTelemetryEvent` / `AcervoTelemetryReporter` / `setTelemetry`.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 1 |
| Total sorties | 8 |
| Dependency structure | strictly sequential (critical path = all 8 sorties) |
| Average sortie size (estimated turns) | ~20 turns (budget = 50) |
| Maximum sortie size | Sortie 5b (~28 turns) |
| New public types | 2 (`AcervoTelemetryEvent`, `AcervoTelemetryReporter`) + `NoopAcervoTelemetryReporter` |
| Public surface changes | 4 setters + 3 defaulted params on `Acervo` static API + defaulted params on `AcervoDownloader` / `IntegrityVerification` |
| Emission sites | ~12 distinct event kinds across 5 source files; `errorThrown` paired with ≥ 23 throw sites |
| New test files | 4 |
| Out of scope | Host-side adapter (§6, tracked in Vinetas plan) |
| Release type | Our next minor release version |
| Parallelism | 1 supervising agent throughout; optional 4-way sub-agent fan-out inside Sortie 6a for test-file authoring |

---

## Refinement Pass Notes

### Pass 1 (Atomicity & Testability)
- **Split**: Original Sortie 5 → 5a (integrity/cache/boundary) + 5b (errorThrown wiring at ~23 sites). Original 5 was borderline-oversized and mixed two concerns.
- **Split**: Original Sortie 6 → 6a (tests + overhead baseline) + 6b (version bump + PR + tag). Original 6 had 9 tasks across 3 distinct concerns.
- **Tightened exit criteria**: Replaced vague "verified later by tests" criterion in original Sortie 5 with concrete grep counts and case-coverage checks. Replaced `wc -l == 4` style assumptions with explicit shell pipelines using `awk` summation across files.
- **Added line-number sanity step**: Sortie 4 and Sortie 5b explicitly require `grep -n` to re-discover line numbers, since the requirements doc's line numbers are approximate and may drift.

### Pass 2 (Prioritization)
- No reordering possible — the dependency graph is a straight chain (each sortie hard-depends on the previous one's exit state). Priority scores added for transparency; they descend in execution order as expected for a sequential mission.

### Pass 3 (Parallelism)
- Critical path = all 8 sorties (intrinsic sequential dependency).
- Single sub-agent-eligible opportunity flagged: Sortie 6a's four test files are independent and could be authored by up to 4 parallel sub-agents. Supervisor retains build + overhead-measurement steps. Other sorties touch the same source files in dependency order — no safe parallelism.

### Pass 4 (Open Questions & Vague Criteria)
- **Auto-fixed**: Removed the concrete `0.13.0` pin floor from the requirements doc text and replaced with "our next minor release version" everywhere in the plan (per supervisor rule against concrete version numbers).
- **Auto-fixed**: Promoted "Branch `instrumentation/01` exists and is checked out" from assumption to an explicit verifiable entry criterion with the exact `git rev-parse` command and a fallback `git checkout -b` recipe.
- **Auto-fixed**: Vague "verified later by tests" exit criterion in original Sortie 5 → concrete grep-based throw-site / emission-site counting in 5b.
- **Auto-fixed**: Loose line-number references made explicit as "approximate — verify via grep" with the exact grep commands.

### Unresolved Items
None blocking. Two minor items worth surfacing for visibility but not blocking start:

1. **Version-source location**: Sortie 6b asks the agent to find where the version is recorded; the repo may track version only via git tags (no file edit needed). The exit criteria handle both cases.
2. **CI gating**: PR merge in Sortie 6b assumes CI is green. If CI is currently red on this repo's default branch for unrelated reasons, that surfaces before merge — not before dispatch.

---

## Refinement Verdict

**Plan is ready to execute.**

| Pass | Status | Changes |
|------|--------|---------|
| 1. Atomicity & Testability | PASS | 2 sortie splits (5→5a/5b, 6→6a/6b); 4 exit criteria tightened |
| 2. Prioritization | PASS | No reorderings (sequential dependency chain); priority scores annotated |
| 3. Parallelism | PASS | Critical path = 8 sorties; 1 supervising agent; optional 4-way fan-out inside 6a |
| 4. Open Questions & Vague Criteria | PASS | 4 auto-fixes; 0 blocking items; 2 informational notes |

**Next step**: `/mission-supervisor start /Users/stovak/Projects/SwiftAcervo/EXECUTION_PLAN.md`
