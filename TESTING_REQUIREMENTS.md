# Testing Requirements: SwiftAcervo

This document defines the testing standard for `SwiftAcervo`. It describes which behaviors must be covered, how tests are structured, what runs in CI vs locally, and where the current gaps are.

---

## 1. Test Targets

| Target | CI | Local | Requires |
|---|---|---|---|
| **SwiftAcervoTests** | Yes | Yes | Nothing (no network, no GPU) |
| **Integration tests** (gated) | No | Yes | Network access to live CDN |

Integration tests live in `SwiftAcervoTests` but are gated with:

```swift
guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else {
    // Not a skip — just an early return. Tests that silently pass are misleading.
    Issue.record("Set INTEGRATION_TESTS=1 to run live network tests")
    return
}
```

Do not use `XCTSkip` or `#skip`. Gated tests that return early without `Issue.record` are invisible failures.

---

## 2. CI Configuration

### Runners and Destinations

| Platform | Runner | Destination |
|---|---|---|
| macOS | `macos-26` (Apple Silicon, arm64) | `platform=macOS,arch=arm64` |
| iOS Simulator | `macos-26` | `platform=iOS Simulator,name=iPhone 17,OS=26.1` |

### Required Status Checks (both must pass before merge to `main` or `development`)

- `Test on macOS`
- `Test on iOS Simulator`

### xcodebuild Flags

```bash
xcodebuild test \
  -scheme SwiftAcervo \
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  COMPILER_INDEX_STORE_ENABLE=NO
```

### Timeout

30 minutes maximum per CI job. Unit tests should complete in under 60 seconds total. Any test approaching 5 seconds on CI needs investigation.

---

## 3. Test Framework

All tests use **Swift Testing** (`import Testing`), not XCTest. Swift 6 strict concurrency is enforced throughout.

```swift
import Testing
@testable import SwiftAcervo

@Suite("AcervoDownloadProgress") struct AcervoDownloadProgressTests {
    @Test func overallProgressIsWeightedByFileSize() { ... }
}
```

Use `#expect()` and `#require()` — not `XCTAssert*`.

---

## 4. What Must Be Tested in CI (No Network Required)

### 4a. Path Resolution

- `Acervo.sharedModelsDirectory` returns a non-empty path inside the sandbox-appropriate container
- `Acervo.modelDirectory(for:)` appends slugified model ID to shared root
- `Acervo.slugify(_:)` replaces `/` with `_` and preserves all other characters including uppercase letters and spaces
- `Acervo.slugify(_:)` rejects IDs that produce empty or root-collision slugs with `.invalidModelId`

### 4b. Model Discovery and Metadata

- `Acervo.listModels()` returns empty array for an empty directory (not an error)
- `Acervo.listModels()` returns models sorted newest-first
- `Acervo.modelInfo(_:)` returns `nil` for an unknown ID without throwing
- `AcervoModel` computed properties: `formattedSize`, `slug`, `baseName`, `familyName`
- `AcervoModel` with zero `sizeBytes` formats as "0 bytes"

### 4c. Search

- `Acervo.findModels(matching:)` is case-insensitive substring match
- `Acervo.findModels(fuzzyMatching:editDistance:)` respects edit distance threshold
- `Acervo.closestModel(to:)` returns `nil` for empty model list
- `levenshteinDistance("", "abc")` returns 3
- `levenshteinDistance("abc", "abc")` returns 0

### 4d. Component Registry

- `Acervo.register(_:)` stores descriptor retrievable by `Acervo.component(_:)`
- Registering the same component ID twice merges metadata (larger memory wins, larger size wins)
- `Acervo.registeredComponents()` returns all registered descriptors
- `ComponentHandle.url(for:)` resolves expected file paths
- `ComponentHandle.urls(matching:)` returns all files matching glob pattern
- `ComponentHandle.availableFiles()` returns only files that exist on disk

### 4e. CDN Manifest

- `CDNManifest` decodes from valid JSON (all fields present)
- `CDNManifest` fails to decode JSON missing required `version` field
- `CDNManifestFile` checksum field is preserved exactly (no lowercasing)
- Unsupported manifest version returns `.manifestVersionUnsupported(n)`
- Model ID mismatch between manifest and request returns `.manifestModelIdMismatch`

### 4f. Integrity Verification

- SHA-256 of a known byte sequence matches expected hex string
- Modified file content produces a different hash (integrity fails)
- File size mismatch returns `.downloadSizeMismatch` before checksum
- Integrity check on missing file returns `.componentFileNotFound`

### 4g. Download Progress

- Single-file progress: overall fraction equals file fraction
- Multi-file progress: overall fraction is weighted by file size (large files dominate)
- Overall fraction never exceeds 1.0
- `AcervoDownloadProgress` is `Sendable` (compile-time enforcement)

### 4h. Concurrency

- Two downloads for **the same model ID** run serially (second waits for first)
- Two downloads for **different model IDs** run in parallel (measured by wall time)
- `AcervoManager.getDownloadCount()` increments correctly under concurrent access
- `AcervoManager.clearCache()` leaves the manager in a usable state for subsequent operations

### 4i. Security

- `SecureDownloadSession` rejects HTTP 302 redirects to non-CDN domains
- `SecureDownloadSession` allows redirects within the same CDN domain
- Manifest integrity check rejects manifests with incorrect checksums

### 4j. Legacy Migration

- `Acervo.migrateModels()` moves files from deprecated `~/Library/Caches/` path to current canonical path
- Migration is idempotent: running twice does not error or duplicate files
- Migration for an already-migrated model is a no-op

### 4k. Errors

All 18 `AcervoError` cases must have:
- Non-nil `localizedDescription`
- Description contains the relevant context string (filename, model ID, status code, etc.)

---

## 5. What Must Be Tested with Network Access (Integration Tests)

These tests run locally when `INTEGRATION_TESTS=1` is set. They are never required for CI.

### 5a. Precondition Check

```swift
guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else {
    Issue.record("Set INTEGRATION_TESTS=1 to run live CDN integration tests")
    return
}
```

### 5b. Live CDN Behaviors

- Downloading a known small model file from CDN succeeds (HTTP 200, correct Content-Length)
- Manifest fetch for a known model ID returns valid JSON that decodes to `CDNManifest`
- SHA-256 of downloaded file matches manifest checksum
- `Acervo.ensureAvailable(_:)` creates model directory, writes all declared files
- `Acervo.ensureAvailable(_:)` for an already-downloaded model is a no-op (no network request)
- Download with `force: true` re-downloads even if files exist on disk

### 5c. Error Recovery

- Interrupted download (simulated via test server) retries cleanly
- Truncated file fails integrity check and triggers re-download on next call
- Invalid CDN URL in manifest produces `.downloadFailed(statusCode:)` with correct code

### 5d. Timeout Values

| Test | Timeout |
|---|---|
| Manifest fetch | 30 seconds |
| Small file download (< 1 MB) | 60 seconds |
| Full model download | 600 seconds |

---

## 6. Test Helpers

### Temporary Storage Isolation

Every test that reads or writes to the model directory must use a temporary root:

```swift
let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("acervo-test-\(UUID())")
try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempRoot) }

// Configure Acervo to use this root
Acervo.customBaseDirectory = tempRoot
defer { Acervo.customBaseDirectory = nil }
```

Tests that do not set `customBaseDirectory` must not write any files.

### Fake Model Fixtures

Tests that need a model to be "available" without a real download:

```swift
func makeFakeModel(id: String, in root: URL) throws -> URL {
    let modelDir = root.appendingPathComponent(Acervo.slugify(id))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    // config.json presence is the validity marker
    try "{}".write(to: modelDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    return modelDir
}
```

---

## 7. Coverage Gaps (Priority Order)

| Priority | Gap | Resolution |
|---|---|---|
| 1 | No test verifies live CDN download integrity end-to-end | Add integration tests (gated) |
| 2 | No test for disk-full condition during download | Add unit test with mock filesystem |
| 3 | No test for file permission denial on model directory | Add unit test with restricted temp dir |
| 4 | Manifest version mismatch only tested with one unsupported version | Add boundary test (version 0, version 99) |
| 5 | No stress test: 10+ concurrent downloads of different models | Add local-only concurrency stress test |
| 6 | `withModelAccess` / `withComponentAccess` not tested for exception safety | Add unit test with throwing `perform` closure |
| 7 | `AcervoManager` statistics: `getAccessCount()` not verified under concurrent access | Add concurrency test |
| 8 | Symlinks in model directory not tested (discovery, deletion) | Add edge-case unit tests |
| 9 | Component handle scope: accessing URLs after `withComponentAccess` exits not enforced | Document limitation or add assertion |
| 10 | iOS device behavior (App Group container path) not tested — Simulator only | Note in CI config; mark as manual |

---

## 8. What is Out of Scope

- Testing HuggingFace download behavior — SwiftAcervo only downloads from its own CDN
- Testing model weight correctness — that belongs in `SwiftVinetas` GPU integration tests
- Testing UI — SwiftAcervo has no UI layer
- Platform-specific behavior on physical iOS devices — not part of automated testing
