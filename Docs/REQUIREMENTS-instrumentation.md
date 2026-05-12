# SwiftAcervo — Instrumentation Requirements

**Status:** Draft, awaiting implementation
**Pattern source:** [Vinetas `docs/INSTRUMENTATION_PLAN.md`](https://github.com/intrusive-memory/Vinetas/blob/development/docs/INSTRUMENTATION_PLAN.md) + Produciesta `Docs/TELEMETRY_IMPL_PATTERN.md`
**Host:** Vinetas (this is one of five intrusive-memory libraries instrumented as a coherent set)
**Priority:** P3 — lightest surface, no math, ship first to flush the pattern through the dev pipeline

---

## 1. Why instrument SwiftAcervo

SwiftAcervo handles **all model file I/O** for Vinetas: download from Cloudflare R2, integrity verification, on-disk caching, ref-counted access. It contains no diffusion math. The diagnostic value here is **correlation**: when a downstream library (flux-2-swift-mlx, pixart-swift-mlx) reports a numerical anomaly during a denoise step, Acervo's events let the engineer answer "did the weights load correctly in the first place?"

The instrumentation must surface:

- **Integrity verdicts** (expected SHA vs actual SHA, pass/fail) — a corrupted download is the most common root cause of NaN cascades downstream.
- **Per-component download outcomes** — which files made it from CDN to disk, when, how big, at what throughput.
- **Cache hit/miss** — Vinetas should never re-download what's already verified on disk; if it does, the trail makes it obvious.
- **Network failure modes** — distinguish 404 (CDN missing), 5xx (CDN unhealthy), timeout (connectivity), checksum mismatch (file corrupt in transit).

What it must NOT surface:
- Per-byte progress (the existing `AcervoDownloadProgress` callback already does that for UI).
- Internal SigV4 signing details, credential resolution paths.

---

## 2. Coexistence with existing surfaces

Two prior mechanisms already live in this library. The new telemetry pattern **does not replace them**:

| Surface | Audience | Stability | Status under this plan |
|---|---|---|---|
| `AcervoDownloadProgress` / `AcervoPublishProgress` / `AcervoDeleteProgress` callbacks on public APIs (`Acervo.download`, etc.) | App users (UI progress bars) | Public API — breaking change to alter | **Keep as-is.** Telemetry adapter on the Vinetas side can correlate against these if useful. |
| `os.Logger` instances (`AcervoDownloader.swift:37`, `ModelDownloadManager.swift:125`) — 5 call sites total, all `error`/`warning` | Operators reading Console.app | Internal | **Keep as-is.** Every emission site also fires a corresponding `errorThrown` telemetry event with structured payload. Logger calls remain for the human reader; telemetry events are for the host sink. |

Implementation note: do not consolidate the two `Logger` calls into a single helper. They have distinct subsystems and call sites that have known surface area in support workflows.

---

## 3. Public types to add

Two new files in `Sources/SwiftAcervo/Telemetry/`:

```
Sources/SwiftAcervo/Telemetry/
  AcervoTelemetryEvent.swift
  AcervoTelemetryReporter.swift
```

### 3.1 `AcervoTelemetryEvent.swift`

```swift
import Foundation

public enum AcervoTelemetryEvent: Sendable {

    // --- Lifecycle ---
    case downloadOperationStart(modelID: String, requestedFiles: [String], offlineMode: Bool)
    case downloadOperationComplete(modelID: String, totalBytes: Int64, durationSeconds: Double)

    // --- Per-component download ---
    case componentDownloadStart(modelID: String, fileName: String, expectedBytes: Int64?, sourceURL: String)
    case componentDownloadComplete(modelID: String, fileName: String, actualBytes: Int64, durationSeconds: Double, throughputMBps: Double)

    // --- Manifest fetch ---
    case manifestFetchStart(modelID: String, manifestURL: String)
    case manifestFetchComplete(modelID: String, manifestVersion: String, fileCount: Int, totalDeclaredBytes: Int64)

    // --- Integrity ---
    case integrityVerifyStart(modelID: String, fileName: String, expectedSHA: String, declaredBytes: Int64)
    case integrityVerifyComplete(modelID: String, fileName: String, actualSHA: String, actualBytes: Int64, passed: Bool, durationSeconds: Double)

    // --- Cache ---
    case cacheHit(modelID: String, fileName: String, onDiskBytes: Int64, ageSeconds: Double)
    case cacheMiss(modelID: String, fileName: String, reason: CacheMissReason)

    // --- CDN HTTP ---
    case cdnRequest(method: String, url: String, statusCode: Int, latencyMS: Double, byteCount: Int64?)

    // --- Boundary memory events (per INSTRUMENTATION_PLAN §3.1) ---
    case modelLoadComplete(modelID: String, totalSizeMB: Double, componentCount: Int)
    // Adapter MUST route this through captureWithMemorySnapshot.

    // --- Error side-channel ---
    case errorThrown(phase: ErrorPhase, errorDescription: String, modelID: String?, fileName: String?)

    public enum CacheMissReason: String, Sendable {
        case notPresent           // file not on disk
        case shaChangedRemote     // CDN reports different SHA than cached
        case sizeChangedRemote    // CDN reports different byte count
        case corrupted            // on-disk SHA does not match recorded SHA
        case forcedRefresh        // caller passed forceRefresh=true
    }

    public enum ErrorPhase: String, Sendable {
        case manifestDownload
        case manifestDecode
        case manifestVersionUnsupported
        case manifestIntegrity
        case fileDownload
        case fileDownloadSize
        case fileDownloadIntegrity
        case directoryCreation
        case offlineMode
        case s3Request
        case other
    }
}
```

**Why these cases:**
- `downloadOperationStart`/`Complete` bracket the entire `Acervo.download` (or `AcervoManager.download`) call. Single pair per public-API call.
- `componentDownloadStart`/`Complete` fire once per file (n times per operation). Carry per-file throughput so a slow R2 region is visible.
- `manifestFetchStart`/`Complete` separately tracked: the manifest is the first request and a 404 here is a different bug than a 404 on a weight file.
- `integrityVerifyStart`/`Complete` are always paired, even on cache hits (we verify-on-read, not just verify-on-download). `passed: false` is the signal that triggers downstream forensics.
- `cacheHit` / `cacheMiss` are emitted from the lookup site **before** any network request. The `CacheMissReason` enum is the single most diagnostic field in this whole spec — it answers "why are we re-downloading."
- `cdnRequest` is the raw HTTP audit trail. Status code + latency answers infrastructure questions without requiring tcpdump.
- `modelLoadComplete` is the **boundary memory event** — the adapter routes it through `captureWithMemorySnapshot`. All other Acervo events use plain `capture`.
- `errorThrown` mirrors every `throw` site in the library (~10 sites concentrated in `AcervoDownloader.swift`).

### 3.2 `AcervoTelemetryReporter.swift`

```swift
public protocol AcervoTelemetryReporter: Sendable {
    func capture(_ event: AcervoTelemetryEvent) async
}

public struct NoopAcervoTelemetryReporter: AcervoTelemetryReporter {
    public init() {}
    public func capture(_ event: AcervoTelemetryEvent) async {}
}
```

`Sendable`. One method. `async`. Non-throwing. No log levels, no batching, no filtering — those are adapter concerns.

---

## 4. Injection points

### 4.1 Public actors (setter-after-construct)

| Type | File:Line | Setter to add |
|---|---|---|
| `AcervoManager` | `AcervoManager.swift:36` | `public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)` |
| `ModelDownloadManager` | `ModelDownloadManager.swift:119` | `public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)` |
| `S3CDNClient` | `S3CDNClient.swift:108` | `public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)` |
| `ManifestGenerator` | `ManifestGenerator.swift:47` | `public func setTelemetry(_ reporter: (any AcervoTelemetryReporter)?)` |

Each actor stores `private var telemetry: (any AcervoTelemetryReporter)? = nil`. Default behavior is silent (zero overhead when nil).

### 4.2 Internal types (defaulted parameter)

`AcervoDownloader` is `internal struct` (`AcervoDownloader.swift:31`) and accepts a telemetry reporter as a defaulted parameter on the methods called from public orchestrators:

```swift
// AcervoDownloader.swift — pseudocode
static func fetchManifest(
    modelID: String,
    baseURL: URL,
    offlineMode: Bool,
    telemetry: (any AcervoTelemetryReporter)? = nil  // ← added
) async throws -> CDNManifest

static func downloadFile(
    /* ... existing params ... */,
    telemetry: (any AcervoTelemetryReporter)? = nil  // ← added
) async throws

static func verifyIntegrity(
    /* ... existing params ... */,
    telemetry: (any AcervoTelemetryReporter)? = nil  // ← added
) async throws
```

`IntegrityVerification` (a struct, `IntegrityVerification.swift:21`) similarly gets a defaulted telemetry parameter on any method that performs verification.

`HydrationCoalescer` (`internal actor`, `Acervo.swift:1541`) does not get its own telemetry — its work is observable from `AcervoManager`'s perspective.

### 4.3 Acervo enum (static API)

`Acervo.swift:28` defines `public enum Acervo` with the public `download`/`publish`/`delete` static functions. These each gain a defaulted parameter:

```swift
public static func download(
    /* ... existing params ... */,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil   // ← added
) async throws
```

The existing `progress:` callback remains untouched.

---

## 5. Per-event emission spec

| Event | Emission site | Notes |
|---|---|---|
| `downloadOperationStart` | `Acervo.download(...)` entry (`Acervo.swift`) and `AcervoManager.download(...)` entry (`AcervoManager.swift:319`) | One per public-API call. `offlineMode` snapshotted at call time. |
| `downloadOperationComplete` | Successful return of same call sites | Carries wall-clock duration measured at entry. |
| `manifestFetchStart` | `AcervoDownloader.fetchManifest(...)` start (~`AcervoDownloader.swift:214`) | Before URLSession dispatch. |
| `manifestFetchComplete` | After manifest decode success (~`AcervoDownloader.swift:253`) | Carries `manifest.manifestVersion`, `manifest.files.count`, `manifest.totalBytes`. |
| `componentDownloadStart` | Per-file loop entry inside `downloadFile(...)` (~`AcervoDownloader.swift:313`) | One per file. |
| `componentDownloadComplete` | Successful per-file completion (~`AcervoDownloader.swift:430`) | Throughput = `actualBytes / durationSeconds / 1_048_576`. |
| `integrityVerifyStart` | `IntegrityVerification` entry (`IntegrityVerification.swift`) | Even on cache hits. |
| `integrityVerifyComplete` | `IntegrityVerification` exit (`IntegrityVerification.swift`) | `passed: false` paths still emit and **then** continue to throw. |
| `cacheHit` | Cache lookup hit path (`Acervo.swift` and `AcervoManager.swift`) | Before any network IO. |
| `cacheMiss` | Cache lookup miss path | `CacheMissReason` populated from the actual decision. |
| `cdnRequest` | `S3CDNClient.send(...)` / URLSession completion (`S3CDNClient.swift`) | One per HTTP request. Includes `404`s. Use the autoclosure guard on URL construction. |
| `modelLoadComplete` | After last component verified for a model (whether downloaded or cache-hit) | **Adapter routes through `captureWithMemorySnapshot`.** |
| `errorThrown` | Every `throw` site in `AcervoDownloader.swift` (lines 178, 219, 231, 238, 246, 248, 253, 258, 267, 319, 329, 367, 406, 412, 424, 491, 500, 508, 606, 654), `ModelDownloadManager.swift` (lines 183, 272, 328), and any new throw added during instrumentation work | Fire the event **before** the throw. Use a defer pattern if needed for cleanup symmetry. |

### Hot-path discipline

- All payload construction must run inside `await telemetry?.capture(...)` only — guard with `guard let telemetry else { return }` (no `@autoclosure` needed for these payloads since they're cheap primitives).
- `cdnRequest` events fire per HTTP request — at most a few dozen per generation. No debouncing needed in the library; the adapter handles aggregation if it wants.
- `componentDownloadComplete` throughput must be measured from start-of-body-read, not start-of-request (TCP handshake skews the number).

---

## 6. Adapter mapping (Vinetas host side)

Mapping spec for the `AcervoTelemetryAdapter` that will live at `Vinetas/Telemetry/Adapters/AcervoTelemetryAdapter.swift`. Every event maps to a sink phase string + a `Payload` field set:

| Event | Sink phase | Payload fields populated | Memory snapshot? |
|---|---|---|---|
| `downloadOperationStart` | `acervo_download_op_start` | `modelID`, `componentList: [String]` | no |
| `downloadOperationComplete` | `acervo_download_op_complete` | `modelID`, `bytesTransferred`, `durationSeconds` | no |
| `manifestFetchStart` | `acervo_manifest_fetch_start` | `modelID`, `url` | no |
| `manifestFetchComplete` | `acervo_manifest_fetch_complete` | `modelID`, `manifestVersion`, `componentCount`, `bytesDeclared` | no |
| `componentDownloadStart` | `acervo_component_download_start` | `modelID`, `componentName`, `expectedBytes`, `sourceURL` | no |
| `componentDownloadComplete` | `acervo_component_download_complete` | `modelID`, `componentName`, `bytesTransferred`, `throughputMBps`, `durationSeconds` | no |
| `integrityVerifyStart` | `acervo_integrity_start` | `modelID`, `componentName`, `expectedSHA` | no |
| `integrityVerifyComplete` (passed) | `acervo_integrity_pass` | `modelID`, `componentName`, `actualSHA`, `durationSeconds` | no |
| `integrityVerifyComplete` (failed) | `acervo_integrity_FAIL` | `modelID`, `componentName`, `expectedSHA`, `actualSHA`, `bytesActual`, `bytesExpected` | no |
| `cacheHit` | `acervo_cache_hit` | `modelID`, `componentName`, `onDiskBytes`, `ageSeconds` | no |
| `cacheMiss` | `acervo_cache_miss_<reason>` (e.g. `acervo_cache_miss_shaChangedRemote`) | `modelID`, `componentName` | no |
| `cdnRequest` | `acervo_cdn_request_<statusCode>` (e.g. `acervo_cdn_request_200`, `acervo_cdn_request_404`) | `httpMethod`, `httpURL`, `httpStatus`, `latencyMS`, `bytesTransferred` | no |
| `modelLoadComplete` | `acervo_model_load_complete` | `modelID`, `sizeMB`, `componentCount` | **yes** (`captureWithMemorySnapshot`) |
| `errorThrown` | `acervo_error_<phase>` (e.g. `acervo_error_fileDownloadIntegrity`) | `errorDescription`, `modelID`, `componentName` | no |

The adapter must **switch exhaustively** on `AcervoTelemetryEvent`. No `default:`. Adding a new case in the library produces a compile error on the host — that is the intended design.

---

## 7. Tests

### 7.1 In-library tests (must ship with this PR)

Add to `Tests/SwiftAcervoTests/`:

| Test | Purpose |
|---|---|
| `AcervoTelemetryMockReporterTests` | Use a `MockReporter` that records every event into an array. Run a full `Acervo.download` against a mocked URL session and assert: (1) event order matches expected lifecycle; (2) all expected cases fire at least once; (3) `errorThrown` fires before the throw propagates. |
| `AcervoTelemetryNoopOverheadTests` | Run the same mocked `Acervo.download` with `nil` reporter and `NoopAcervoTelemetryReporter`. Assert both wall-clock medians stay within ±2% of each other across 50 iterations. |
| `AcervoTelemetryCacheMissReasonTests` | Drive each `CacheMissReason` deterministically (forced refresh, on-disk SHA mismatch, etc.); assert the right reason fires in each scenario. |
| `AcervoTelemetryIntegrityFailureTests` | Inject a fake on-disk file with a known wrong SHA; assert `integrityVerifyComplete(passed: false)` fires **before** the throw and that `errorThrown(phase: .fileDownloadIntegrity)` follows. |

### 7.2 Sanity checks for the implementer

- No `print()` calls added. No new `Logger` instances. The 5 existing `logger.error`/`logger.warning` calls in `AcervoDownloader.swift:610`/`675` and `ModelDownloadManager.swift:180/269/325` stay. Each of those sites also fires a matching `errorThrown` event.
- No new module dependencies added to the Package.swift.
- `setTelemetry(nil)` from the test suite returns the library to its baseline behavior; assert via `XCTUnwrap` that subsequent operations emit zero events.

---

## 8. Out of scope for this work

These are listed so reviewers don't ask "why not?":

- Per-byte download progress events. The existing `AcervoDownloadProgress` callback already serves this; duplicating in telemetry would be noise.
- Telemetry on internal value-type helpers (`SigV4Signer`, `CacheBypassingRequest`, `LevenshteinDistance`). Not failure surfaces.
- Persistent telemetry to disk **inside** the library. The host owns persistence.
- Network-quality estimation (RTT histograms, etc.). The `cdnRequest` latency field is sufficient; deeper diagnostics can be added later if a real bug calls for them.

---

## 9. Versioning

This is a **minor** version bump for SwiftAcervo (additive: new types, new optional parameters with defaults, new setter). No existing public API changes. Pin floor: `0.13.0` post-release.

---

## 10. Implementation checklist

- [ ] Add `Sources/SwiftAcervo/Telemetry/AcervoTelemetryEvent.swift` per §3.1
- [ ] Add `Sources/SwiftAcervo/Telemetry/AcervoTelemetryReporter.swift` per §3.2
- [ ] Add `setTelemetry(_:)` to `AcervoManager`, `ModelDownloadManager`, `S3CDNClient`, `ManifestGenerator`
- [ ] Add defaulted `telemetry:` parameter to `AcervoDownloader` static methods, `IntegrityVerification` methods, and `Acervo.download`/`.publish`/`.delete`
- [ ] Wire emission sites per §5 (each row of the table = one `await telemetry?.capture(.case(...))`)
- [ ] Ensure every `throw` site is paired with `await telemetry?.capture(.errorThrown(...))` immediately before the throw
- [ ] Add tests per §7.1
- [ ] Run baseline overhead test; commit results in PR description
- [ ] Tag release with `MINOR` bump
