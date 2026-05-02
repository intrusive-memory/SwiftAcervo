# Testing Requirements: SwiftAcervo (v0.8.0)

This document is a prioritized punch list of known testing gaps in SwiftAcervo as of v0.8.0 (merge commit `4d01c3f`, PR #22, shipped 2026-04-22). The baseline is 443 passing tests across 44 suites. Each bullet below pins the gap to a specific file and line so a reader can jump straight to the code. For mission-process items (CI workflow migration, registry-state races, disk caching deferral, stash review, sortie-process feedback), see [FOLLOW_UP.md](FOLLOW_UP.md). For what shipped in v0.8.0, see [CHANGELOG.md](CHANGELOG.md).

---

## P0: Correctness gaps

### Hydration failure modes not exercised

`Tests/SwiftAcervoTests/HydrationTests.swift` covers:

- 404 manifest (`manifest404OnHydration`)
- `manifestModelIdMismatch` (`manifestIdMismatch`)
- Drift replace semantics + stderr warning (`hydrationPicksUpManifestDrift`)
- Concurrent coalesce (`concurrentHydration`)
- Un-registered ID (`HydrateComponentTests.hydrateUnknownComponentThrows`)

It does **not** cover these three `AcervoError` cases along the hydrate path:

- **`AcervoError.manifestDecodingFailed`** — `Sources/SwiftAcervo/AcervoError.swift:55`, thrown from `AcervoDownloader.downloadManifest(for:session:)`. Add a test that stubs a 200 response with malformed JSON body and asserts this case.
- **`AcervoError.manifestIntegrityFailed`** — `Sources/SwiftAcervo/AcervoError.swift:58`. Stub a 200 response with a manifest whose `manifestChecksum` does not match the checksum-of-checksums computed from `files[].sha256`. Assert `expected` and `actual` populate correctly.
- **`AcervoError.manifestVersionUnsupported`** — `Sources/SwiftAcervo/AcervoError.swift:61`. Stub a manifest with `manifestVersion` = `CDNManifest.supportedVersion + 1` and assert rejection. Consider adding a companion case for version `0` for boundary coverage.

Pattern to follow: the three tests above in `HydrationTests.swift` using `MockURLProtocol.responder`.

### `HydrationCoalescer` error-path slot clearing

`Sources/SwiftAcervo/Acervo.swift:1354-1370`. The `defer { inflight[id] = nil }` block implies a first-call throw should not poison the slot for subsequent callers. No test exercises this. Scenario: responder returns 500 on first call, then 200 on second call. First `hydrateComponent` throws; second must succeed and produce a hydrated descriptor. Assert `MockURLProtocol.requestCount == 2`.

### `HydrationCoalescer` re-fetch after completion

`Sources/SwiftAcervo/Acervo.swift:1381-1382` documents: "A later call (after completion) re-fetches so CDN manifest updates between app launches are picked up." No test asserts this. Scenario: call `hydrateComponent`, assert `requestCount == 1`; call again, assert `requestCount == 2`. Existing coalesce tests assert the opposite (single-flight under contention), not re-fetch after settle.

### `downloadComponent` auto-hydration end-to-end

`Sources/SwiftAcervo/Acervo.swift:1490` — the branch `if initialDescriptor.needsHydration { try await hydrateComponent(...) }` is never exercised by a test that reaches a successful download. Existing tests either pre-hydrate (then call `ensureComponentReady` with files pre-staged on disk) or assert errors on unregistered IDs. Gap: no end-to-end "register bare descriptor -> `downloadComponent` -> hydrates from manifest -> streams files -> verifies integrity -> returns" test. Blocked today by the non-injectable download session (see P1 first item); implementing that unblocks this test.

### Registry-level SHA-256 cross-check

`Sources/SwiftAcervo/Acervo.swift:1515-1527`. After `download(...)` completes, `downloadComponent` re-hashes every file and compares against `descriptor.files[].sha256`, throwing `integrityCheckFailed` and deleting the corrupt file on mismatch. No dedicated test covers this second verification pass (the streaming path at `AcervoDownloader.swift:401-408` covers the first pass). Scenario: stage a file on disk whose content hashes to `X`, install a hydrated descriptor whose `sha256` is `Y`, call `downloadComponent` with `force: false`. The download short-circuits because the file exists, but the registry-level check should still fail with `integrityCheckFailed(file:expected:actual:)` and delete the file.

---

## P0: Public API behavior untested

### `Acervo.fetchManifest(for:)` has no behavior coverage

`Tests/SwiftAcervoTests/ManifestFetchTests.swift:66-72` (`fetchManifestIsCallable`) is a compile-time symbol existence check only — it never invokes the method. The underlying `downloadManifest(for:session:)` is covered (`downloadManifestWithMockSession`, line 16), but the public wrapper at `Sources/SwiftAcervo/Acervo.swift:1344-1346` is not, because it hard-codes `SecureDownloadSession.shared` and cannot be stubbed. Resolution: add a `session:` parameter to the public `fetchManifest` (mirroring `hydrateComponent`'s public/internal pair), then add behavior tests identical to `downloadManifestWithMockSession` but through the public API.

### `Acervo.ensureAvailable(modelId, files: [])` empty-files path is uncovered

`Sources/SwiftAcervo/AcervoDownloader.swift:685-688` — when `requestedFiles` is empty, the downloader fetches the entire manifest's file list. This is the primary manifest-driven knob at the *model* level (distinct from the component-level hydration added in v0.8.0). `ModelDownloadManager.ensureModelsAvailable` at `Sources/SwiftAcervo/ModelDownloadManager.swift:323` depends on this path. Zero tests exercise "empty files array means all files." Gap depth is worse because the file-download session itself is not injectable — see P1 below.

---

## P1: Architectural testability gaps

### Download session is not injectable on the file-download paths

`Sources/SwiftAcervo/AcervoDownloader.swift:302` (`streamDownloadFile`) and `Sources/SwiftAcervo/AcervoDownloader.swift:465` (`fallbackDownloadFile`) both pin `SecureDownloadSession.shared` directly. Only `downloadManifest(for:session:)` takes a session parameter (made public in v0.8.0 per CHANGELOG.md). Consequence: every file-body download is unreachable from `MockURLProtocol`. This blocks:

- End-to-end `downloadComponent` auto-hydration (P0)
- `ensureAvailable` empty-files coverage (P0)
- Registry-level SHA-256 cross-check failures (P0)
- Any cancellation, retry, or resumption test that does not require a live network

Resolution: thread a `session: URLSession = SecureDownloadSession.shared` parameter from `downloadFiles(...)` at `AcervoDownloader.swift:674` down through `downloadFile(...)` (both overloads) and into both private helpers. Keep the default so no call site needs to change. This is the single highest-leverage testability change available. Estimated footprint: ~15 lines across one file.

### Test isolation for global state

Already tracked in [FOLLOW_UP.md](FOLLOW_UP.md) "Pre-existing Test Flake" and "Test-Isolation Primitive." Relevant here because it forces current tests to work around global state with UUID-suffixed IDs (`HydrateComponentTests.uniqueIds`, `HydrationTests.uniqueIds`, `AutoHydrateTests.uniqueIds`) and `defer { unregister }` blocks. The model-storage root is now driven by the `ACERVO_APP_GROUP_ID` environment variable (the prior `customBaseDirectory` static was removed). The checked-in scheme at `.swiftpm/xcode/xcshareddata/xcschemes/SwiftAcervo-Package.xcscheme` sets it to `group.acervo.testbundle.default` so tests share a stable bundle root; tests that need stricter per-test isolation override the value via `withIsolatedAcervoState` in `Tests/SwiftAcervoTests/Support/ComponentRegistryIsolation.swift`. The `AppGroupEnvironmentSuite` `.serialized` parent serializes any test that mutates the env var.

---

## P1: CLI command coverage

Component coverage exists at `Tests/AcervoToolTests/` for:

- `ManifestGeneratorTests.swift`
- `CDNUploaderTests.swift`
- `HuggingFaceClientTests.swift`
- `IntegrityStepTests.swift`
- `ToolCheckTests.swift`

The command layer under `Sources/acervo/` has **no unit tests**. Missing coverage by file:

- `Sources/acervo/ShipCommand.swift` — argument parsing, flag handling (`--force`, `--skip-upload`, etc.), step sequencing, exit codes, error surfacing from each pipeline step.
- `Sources/acervo/DownloadCommand.swift` — argument parsing, HuggingFace-only path, exit codes.
- `Sources/acervo/UploadCommand.swift` — argument parsing, R2 credential validation, upload-only path.
- `Sources/acervo/VerifyCommand.swift` — argument parsing, all-integrity-checks path, exit codes.
- `Sources/acervo/ManifestCommand.swift` — argument parsing, manifest generation from local files path.

Each command deserves at least: a "happy-path arguments parse correctly" test, a "missing required argument exits non-zero" test, and a "each component error maps to the right exit code" test.

### Upload / ship pipeline testing — not this repo

The `acervo ship` pipeline (HuggingFace → manifest → R2 upload → verify) is
**not** tested in SwiftAcervo's CI. Each downstream repository that publishes
a model is responsible for exercising `ship` against its own credentials in
that repo's model-publish workflow. SwiftAcervo itself never uploads, so
maintaining a shared R2 integration suite here was dead weight.

What remains in this repo:

- **Unit coverage** for the CLI command layer (`AcervoToolTests/`): argument
  parsing, manifest generation, integrity step logic, `CDNUploader` `aws` argv
  construction — no live network, no credentials.
- **Read-only CDN smoke** (`AcervoToolTests/CDNManifestFetchTests.swift`):
  fetches a known-published manifest from the public R2 URL, verifies the
  checksum-of-checksums, spot-checks one file's SHA-256. Runs in PR CI. No
  credentials required.

---

## P2: Additional coverage

Keep this list short; not worth scheduling until P0/P1 are addressed.

- `ComponentDescriptor` Hashable / Equatable behavior under concurrent Set insertion from multiple tasks.
- Progress-report callback invocation count and ordering when a download is cancelled mid-stream (`AcervoDownloader.swift:726` task-group cancellation path).
- `levenshteinDistance` edge cases: empty string vs. long string, strings with non-ASCII scalars, and strings at the current edit-distance threshold boundary.
- `AcervoMigration` partial-failure recovery: migration halfway through a multi-file move when the second move fails (no test verifies the directory is left in a consistent state).
- `componentNotHydrated` error reached from paths other than `verifyComponent` (if any are added later — currently only one throw site at `Acervo.swift:1497`).

---

## Testing infrastructure needed

Two options to unblock the P1 gaps:

1. **Local HTTP fixture server.** Stand up an in-process HTTP server in `Tests/SwiftAcervoTests/Support/` that serves manifests and file bodies. Would cover the full download pipeline without credentials or CDN access. Larger implementation footprint; introduces a test-only dependency and a port-allocation concern.

2. **Make the file-download session injectable** (P1 first item) and use `MockURLProtocol` as every hydration test already does. `Tests/SwiftAcervoTests/Support/MockURLProtocol.swift` is already in place, already used by 20+ tests, and already handles the process-wide static-storage concern via the `MockURLProtocolSuite` `.serialized` trait.

Option 2 is smaller, faster to implement, and consistent with how the v0.8.0 hydration tests work. Recommend Option 2 unless a future test scenario specifically requires wire-level behavior that `URLProtocol` interception cannot model.
