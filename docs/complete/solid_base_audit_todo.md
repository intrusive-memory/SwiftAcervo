# TODO — "solid base?" audit follow-ups (archived 2026-04-25)

Hardening follow-ups from the 2026-04-23 "solid base?" audit. None were
blocking, but each closed a real gap in the security/correctness story before
SwiftAcervo could be sold as a foundation for downstream LLM apps.

All three items are now resolved. This file is preserved as the origin record;
the live TODO.md has been removed.

---

## 1. ~~`CDNManifest` tamper-detection test~~ — RESOLVED 2026-04-25

**Why it mattered**: The manifest's `manifestChecksum` is a checksum-of-checksums
over every file's SHA-256. It is the single signature that says "this file list
has not been tampered with." Every per-file hash test we had would still pass
if an attacker swapped a legitimate file entry for one they controlled — as
long as the per-file hash itself was internally consistent. The manifest
checksum is what catches that class of attack, but no test verified that a
corrupted manifest was rejected.

**What shipped:**

- New `Tests/SwiftAcervoTests/CDNManifestIntegrityTests.swift` (nested under
  `SharedStaticStateSuite.MockURLProtocolSuite`, fully deterministic, no
  network).
- Five end-to-end tests using `MockURLProtocol` to drive
  `Acervo.fetchManifest(for:session:)`:
  - **Round-trip baseline** — clean manifest decodes and validates.
  - **Tampered file `sha256`** → `manifestIntegrityFailed`.
  - **Added file entry** → `manifestIntegrityFailed`.
  - **Removed file entry** → `manifestIntegrityFailed`.
  - **Mutated `manifestChecksum` field itself** → `manifestIntegrityFailed`.
- Each negative test asserts both the `expected` (declared) and `actual`
  (recomputed) fields of the thrown error match the served manifest.

**Decision called out during implementation:**

The original audit listed seven mutations and assumed all seven would produce
`manifestIntegrityFailed`. That was wrong. The algorithm in
`CDNManifest.computeChecksum(from:)` only hashes the per-file `sha256` values:

> "sort `files[].sha256` lexicographically, concatenate, SHA-256 the bytes."

So `path` and `sizeBytes` mutations are NOT covered by `manifestChecksum`. They
pass manifest verification and are caught downstream:

- `path` mismatches surface as `fileNotInManifest` when a caller asks for a file
  by name (existing coverage in `EnsureAvailableEmptyFilesTests`).
- `sizeBytes` mismatches surface as `downloadSizeMismatch` once bytes start
  arriving (existing coverage in `StreamAndHashTests`).

Two additional tests in the new file document this current contract as
regression sentinels (`Tampered path passes manifest integrity check`,
`Tampered sizeBytes passes manifest integrity check`). If anyone later
tightens `computeChecksum` to cover those fields, those sentinels will break
and force a contract-doc update.

**Not blocking, but a real attack surface to consider in v2:** if the threat
model ever needs to defend against a CDN that can serve a *consistent* but
malicious manifest (one whose declared checksum is recomputed after path
substitution), `manifestChecksum` should be expanded to cover all three
fields per file, or replaced with a signature.

---

## 2. ~~Multi-file rollback test~~ — RESOLVED 2026-04-25

**Why it mattered**: We advertised atomic downloads. `StreamAndHashTests`
verified atomicity for a single file. The real consumer use case is 5–10 files
per model. If file 2 of 3 failed mid-stream, we claimed files 1 and 3 didn't
land in the final cache in a half-downloaded state. That claim had no test.

**What shipped:**

- New `Tests/SwiftAcervoTests/MultiFileRollbackTests.swift` (nested under
  `SharedStaticStateSuite.MockURLProtocolSuite`, fully deterministic, no
  network, all 3 tests run in <30 ms total).
- Three sub-tests, one per documented per-file failure mode, each driving a
  3-file manifest where `config.json` is the failing file:
  - **HTTP 500** → `AcervoError.downloadFailed`.
  - **Right size, wrong bytes** → `AcervoError.integrityCheckFailed`.
  - **Short body** → `AcervoError.downloadSizeMismatch`.
- After each failure each test asserts:
  1. The expected error case is thrown with the right associated values.
  2. `config.json` is NOT present in the destination directory.
  3. `Acervo.isModelAvailable(modelId, in: tempDir)` returns `false`.
  4. No `*.tmp` or `*.partial` artifacts are left in the destination tree.
  5. A subsequent `downloadFiles` call with a fixed responder completes
     cleanly and `isModelAvailable` flips to `true` (no wedged state blocks
     retry).

**Contract clarification reached during implementation:**

The audit's open question was: does "rollback" mean "delete files 1 and 3 on
failure" or "leave them as resumable partials"? Reading
`AcervoDownloader.downloadFiles`, the actual contract is:

> Atomicity is **per file**, not per call. Each file streams to a UUID-named
> temp file in `FileManager.default.temporaryDirectory`, is verified, and only
> then `moveItem`d into the destination. The destination directory therefore
> never observes a partial / half-written file at any path the manifest
> declares. But concurrent siblings that completed before the failure are
> kept on disk so a retry can short-circuit them via the size-match skip.

The new tests assert exactly this contract. They do *not* assert files 1 and
3 are deleted on failure (because they aren't, and shouldn't be — re-downloading
verified bytes wastes bandwidth on every flake).

**Doc note for future:** the marketing wording "atomic downloads" in
USAGE.md / CDN_ARCHITECTURE.md is technically accurate as "atomic per file,"
but a careful reader could read it as "atomic per call." Worth a one-line
softening when those docs next get touched. Not opening a tracking issue —
the test suite is now the source of truth for the actual guarantee.

**Why CI flakiness was not a concern:**

Both this suite and the integrity suite run end-to-end through
`MockURLProtocol`. There is no network, no real timing, and no concurrency
edge that the test depends on (the deterministic post-conditions hold whether
or not sibling files completed before the failure surfaced). Total wall-clock
for all 10 new tests is under 30 ms. Both were written rather than DEFERRED.

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
