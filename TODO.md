# TODO — Next Release

Hardening follow-ups from the 2026-04-23 "solid base?" audit. None are blocking, but each closes a real gap in the security/correctness story before we sell this as a foundation for downstream LLM apps.

---

## 1. `CDNManifest` tamper-detection test

**Why it matters**: The manifest's `manifestChecksum` is a checksum-of-checksums over every file's SHA-256. It is the single signature that says "this file list has not been tampered with." Every per-file hash test we have today would still pass if an attacker swapped a legitimate file entry for one they control — as long as the per-file hash itself is internally consistent. The manifest checksum is what catches that class of attack. Today it is computed and stored, but no test verifies that a corrupted manifest is rejected.

**What to add** (in `Tests/SwiftAcervoTests/`, likely a new `CDNManifestIntegrityTests.swift`):

- Round-trip: build a manifest, serialize, parse, assert `computeChecksum()` matches the stored value.
- Tamper with an entry's `sha256` after serialization — assert `AcervoError.manifestIntegrityFailed` when the download pipeline re-parses it.
- Tamper with an entry's `path` — same assertion.
- Tamper with an entry's `sizeBytes` — same assertion.
- Add a file entry not present when the checksum was computed — same assertion.
- Remove a file entry — same assertion.
- Leave the file list alone but mutate `manifestChecksum` itself — same assertion.

**Where the code lives**: search for `manifestChecksum` / `manifestIntegrityFailed` in `Sources/SwiftAcervo/`. The parse path that should fail is whatever `Acervo.fetchManifest(for:)` ultimately calls.

**Done when**: all seven mutations above produce `AcervoError.manifestIntegrityFailed`, and the round-trip case passes. Gate in CI like the rest of the test suite.

---

## 2. Multi-file rollback test

**Why it matters**: We advertise atomic downloads. `StreamAndHashTests` verifies atomicity for a single file (temp file → fsync → `moveItem`). The real consumer use case is 5–10 files per model (config + tokenizer + N safetensor shards). If file 2 of 3 fails mid-stream, we claim files 1 and 3 do not land in the final cache in a half-downloaded state. That claim has no test.

**What to add** (in `Tests/SwiftAcervoTests/`, likely extending or joining `EnsureAvailableEmptyFilesTests.swift`):

- Use the existing `MockURLProtocol` plumbing to stage a 3-file manifest where file 2's response either:
  - (a) returns HTTP 500 mid-body, or
  - (b) returns the right bytes but the wrong hash (triggers `integrityCheckFailed`), or
  - (c) returns fewer bytes than `sizeBytes` promises (triggers `downloadSizeMismatch`).
- Invoke `Acervo.ensureAvailable(modelId, files: [])` and assert the thrown error matches.
- **Post-condition assertions** (the actual point of the test):
  - The model directory either does not exist, OR exists but does not contain `config.json` (the validity marker). `Acervo.isModelAvailable(modelId)` must return `false`.
  - No `*.tmp` / partial files are left in either the model directory or the system temp dir root we write to.
  - A subsequent successful call to `ensureAvailable` (with all three mocked responses fixed) completes cleanly — i.e., the failure path did not wedge state that blocks retry.

**Decision to make during implementation**: does "rollback" mean "delete files 1 and 3 on failure" or "leave them as resumable partials"? Read `AcervoDownloader` and write the test against the actual contract. If the current behavior is "leave resumable partials," then the test should assert that, and the doc wording ("atomic downloads") may need softening to "atomic per file with resumable retry."

**Done when**: all three failure modes produce the documented error AND the post-condition assertions hold. If the implementation does not match the doc, open a separate issue rather than patching the test to match buggy behavior.

---

## 3. ~~CI decision for env-gated integration tests~~ — RESOLVED 2026-04-23

**Decision:** upload CI is not SwiftAcervo's responsibility. Each downstream
repository that publishes a model owns the end-to-end `acervo ship` exercise
against its own scoped credentials. The library repo tests the CLI at the unit
level plus a read-only CDN smoke against live infrastructure, and nothing
more.

**What shipped:**

- **Deleted** `Tests/AcervoToolIntegrationTests/` (four files:
  `CDNRoundtripTests`, `HuggingFaceDownloadTests`, `ManifestRoundtripTests`,
  `ShipCommandTests`) along with their `Package.swift` target declaration and
  the `make test-acervo-integration` target. These all existed only to back a
  nightly ship roundtrip that's no longer SwiftAcervo's concern.
- **Added** `Tests/AcervoToolTests/CDNManifestFetchTests.swift` — no-cred
  read-only smoke against the public R2 URL. Wired into PR CI via
  `.github/workflows/tests.yml`. Catches download-side regressions without
  requiring any secrets.
- **Unchanged:** unit coverage for every CLI command, `CDNUploader`'s argv
  construction, `ManifestGenerator`, `HuggingFaceClient` JSON parsing — all
  purely offline and still running in PR CI.

**What downstream repos do now:**

Each repo's model-publish workflow runs `acervo ship --model-id org/repo`
directly, with that repo's own HF / R2 credentials. A broken `acervo ship`
surfaces in whatever repo tries to publish first, bounded by whatever model
cadence that repo has. The tradeoff: regressions might land here and not be
visible until a downstream push fails — we're choosing that latency over
owning shared R2 credentials in this repo's CI.

---

## 4. AcervoManager test isolation race (flaky on iOS)

**Why it matters**: `Tests/SwiftAcervoTests/AcervoManagerTests.swift::withModelAccessProvidesURL` reads `Acervo.modelDirectory(for:)` and `AcervoManager.shared.withModelAccess` sequentially. Both resolve against the global `customBaseDirectory`; another concurrent test in the suite mutates it between the two calls, so `receivedURL` and `expectedDir` point at different tmp paths. The test flakes on iOS depending on test ordering (observed during the v0.8.0 release — an iOS rerun passed cleanly, confirming the race).

**What to do**:

- Nest `AcervoManagerTests` (or at least the `withModelAccess*` tests inside it) under `CustomBaseDirectorySuite` the same way `HydrateComponentTests.uniqueIds` was migrated in sortie-2 of OPERATION DESERT BLUEPRINT. That suite is `.serialized` and snapshots/restores `customBaseDirectory` around each nested test.
- Audit the rest of `AcervoManagerTests` for the same pattern — any test that reads both `Acervo.modelDirectory(for:)` and an `AcervoManager.shared` method in the same closure is susceptible.

**Done when**: `make test` passes 5× consecutively on iOS without any sibling-test interference, and the suite migration is documented in the sortie log for the next mission.
