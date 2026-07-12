---
type: project
title: Background Model Downloads on iOS
issue: https://github.com/intrusive-memory/SwiftAcervo/issues/81
status: proposed
updated: 2026-07-11
---

# REQUIREMENTS — Background Model Downloads on iOS

**Tracking issue:** [intrusive-memory/SwiftAcervo#81](https://github.com/intrusive-memory/SwiftAcervo/issues/81)
**Downstream:** [intrusive-memory/Vinetas#134](https://github.com/intrusive-memory/Vinetas/issues/134)
**Status:** Proposed — not started
**Date:** 2026-07-11
**Baseline:** SwiftAcervo 0.23.0

---

## 1. Problem

On iOS, a model download stops when the host app is backgrounded or the device
is locked. Multi-gigabyte model downloads never complete unless the user keeps
the app foregrounded for the entire transfer.

Root cause: all downloads run on a **foreground** `URLSession`
(`URLSessionConfiguration.default`, `SecureDownloadSession.swift:52`) via a
**`dataTask` chunked stream** (`AcervoDownloader.swift:979`). iOS suspends the app
— and with it the session — shortly after backgrounding, then terminates the
in-flight tasks.

## 2. Platform scope — iOS only

| Platform | Backgrounded-app behavior | Needs background session? |
|----------|---------------------------|---------------------------|
| **iOS**  | App is suspended ~seconds after backgrounding; foreground URLSession tasks are suspended and eventually killed. | **Yes** — this is the bug. |
| **macOS**| App process keeps running when minimized/hidden; foreground URLSession tasks continue. (App Nap may throttle a fully-idle hidden app but does not kill an active transfer, and is opt-out-able.) | **No** — the current foreground path already works. |

**Decision:** The new background path is **iOS-only**. macOS retains the existing
foreground `dataTask` chunked-streaming path unchanged. A background session on
macOS would add out-of-process complexity for no benefit against the reported
problem (macOS does not suspend the app), so it is explicitly out of scope.

All new behavior must be gated behind `#if os(iOS)` (or an injected transport
strategy — see §5), leaving the macOS/CLI code path byte-for-byte as it is today.

## 3. Current architecture (what must be preserved)

The foreground path (`AcervoDownloader.swift`) provides guarantees the background
path must not regress:

- **Redirect pinning** — `SecureDownloadDelegate` rejects any redirect off the
  CDN host (`SecureDownloadSession.swift:25-38`, host from `Acervo.cdnAllowedHost`).
- **SHA-256 integrity verification** — each file is verified before its `.part`
  file is renamed into place (`IntegrityVerification`, referenced throughout
  `downloadFile`).
- **Resumable transfer** — app-level `.part` file + HTTP `Range: bytes=<n>-`
  resume (`AcervoDownloader.swift:558-805`, `648`, `712-746`).
- **App Group destination** — files land in the shared container
  `group.intrusive-memory.models` (`Acervo+PathResolution.swift`).
- **Multi-file models** — a "download" is a *set* of files (shards, configs,
  tokenizer); orchestrated by `downloadFiles` (`AcervoDownloader.swift:1459`)
  behind the public `Acervo.download(_:files:…)` (`Acervo+Download.swift:58`).
- **Progress** — `@Sendable (AcervoDownloadProgress) -> Void`, byte-cumulative
  across all files (`ByteProgressTracker`, `AcervoDownloader.swift:68`).

## 4. Why this is a rewrite, not a config flag

iOS background transfer imposes constraints that the current design violates:

1. **`downloadTask` only, not `dataTask`.** Background sessions
   (`URLSessionConfiguration.background(withIdentifier:)`) support **only**
   `downloadTask`/`uploadTask`. The current chunked `dataTask` stream
   (`session.dataTask`, `AcervoDownloader.swift:979`) cannot run on a background
   config at all. The OS downloads the whole file out-of-process to a system temp
   URL and hands it back via
   `urlSession(_:downloadTask:didFinishDownloadingTo:)`.

2. **Completion can arrive in a *different process launch*.** If the transfer
   finishes while the app is suspended or terminated, iOS **relaunches** the app
   in the background and calls
   `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. The
   session must be **re-created with the same identifier** and its delegate
   re-attached to receive the completion. This breaks the current
   `async throws` single-awaitable model (`Acervo.download(...)` returns when the
   download completes) — there may be **no live `await` continuation** when
   completion arrives.

3. **Resume is different.** Background `downloadTask` resume uses
   `cancel(byProducingResumeData:)` + `downloadTask(withResumeData:)`, not the
   app-level `.part` + `Range` scheme. The OS owns the partial data.

4. **Progress is coarser.** Delivered via
   `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`,
   not per-chunk. Acceptable, but the progress adapter must map it into
   `AcervoDownloadProgress`.

5. **Integrity verification moves to completion.** SHA-256 is computed on the
   OS-delivered file *before* moving it into the App Group container.

## 5. Functional requirements (SwiftAcervo)

### R1 — iOS background session
Provide a background `URLSession` built from
`URLSessionConfiguration.background(withIdentifier:)` with a stable, app-scoped
identifier (e.g. `"productions.intrusive-memory.acervo.download"`), configured
with:
- `sharedContainerIdentifier = "group.intrusive-memory.models"` (so the daemon
  can write into the App Group).
- `isDiscretionary` — configurable; default `false` for user-initiated downloads.
- `allowsCellularAccess` — honored from the existing cellular gate (see R8).
- The existing redirect-pinning delegate behavior (R6).

### R2 — `downloadTask` transport for iOS
Replace the `dataTask` chunked stream with a `downloadTask`-based path on iOS.
Implement `URLSessionDownloadDelegate`:
- `didFinishDownloadingTo` → verify SHA-256 (R5), then move into the App Group
  destination (R7).
- `didWriteData…` → map to `AcervoDownloadProgress` (R11).
- `didCompleteWithError` → resume-data capture / retry (R4).

### R3 — Multi-file completion tracking across relaunch
A model is many files. Persist per-file download state (queued / in-flight /
verified / failed) in durable storage in the App Group container (not in memory),
keyed by session task identifier ↔ (modelId, relative file path). On launch /
`handleEvents…`, reconcile delivered files against this ledger and only report the
*model* complete when every file is verified and in place. Must survive app
termination between file completions.

### R4 — Resume via resume-data
On recoverable failure, capture `resumeData` from the `NSError`
(`NSURLSessionDownloadTaskResumeData`) and persist it (R3 ledger); re-issue with
`downloadTask(withResumeData:)`. Fall back to a fresh `downloadTask` when resume
data is absent or rejected.

### R5 — Preserve SHA-256 integrity verification
No file is moved into the App Group destination until its SHA-256 matches the
manifest. A verification failure deletes the temp file and re-queues (bounded
retries), identical in strength to the current guarantee.

### R6 — Preserve CDN redirect pinning
The background session's task delegate must enforce the same
`willPerformHTTPRedirection` host check as `SecureDownloadDelegate`
(`SecureDownloadSession.swift:25-38`). Downloads must never follow a redirect off
`Acervo.cdnAllowedHost`, even out-of-process.

### R7 — App Group destination + atomic move
Completed, verified files are moved (rename, same volume) into the shared
`group.intrusive-memory.models` model directory via the existing path resolution
(`Acervo+PathResolution.swift`). Partial/temp files never leak into the model dir.

### R8 — Cellular / discretionary policy
Integrate with the host's cellular gate (Vinetas
`CellularDownloadGate.swift`): map its allow/deny into `allowsCellularAccess`
and, where appropriate, `isDiscretionary` / `allowsExpensiveNetworkAccess` on the
background config. Default: user-initiated (non-discretionary), Wi-Fi-or-cellular
per the gate's decision.

### R9 — Platform conditioning
All of the above is `#if os(iOS)`. macOS/CLI continue to use the existing
foreground `SecureDownloadSession.shared` + `dataTask` chunked path with **zero
behavioral change**. Prefer a small internal transport abstraction (e.g. a
`ModelDownloadTransport` protocol with `Foreground` and `BackgroundIOS`
implementations) over scattering `#if` throughout `AcervoDownloader`.

### R10a — Background behavior must surface through the component-download entry points
SwiftVinetas does **not** call `Acervo.download(...)` / `AcervoManager.download(...)`
directly. Its engines call:
- `Acervo.ensureComponentReady(_:progress:telemetry:)`
  (`Acervo+ComponentDownloads.swift:140`) — PixArt.
- `Acervo.ensureAvailable(_:files:progress:)` — FLUX.2.

The iOS background path (R1–R9) must therefore be reachable **through these
component-download entry points**, plus a batch **enqueue** variant that accepts a
set of components/repos+files (so SwiftVinetas can enqueue an entire multi-component
model at once instead of looping). Expose a **durable per-file/per-component state
query** (backed by the R3 ledger) for availability re-derivation after relaunch.

### R10 — Host re-attach API (the key new surface)
Expose public API so the host app can service background completion:
- A way to obtain the session identifier(s) SwiftAcervo uses.
- An entry point the app calls from
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` that
  (a) re-creates/re-attaches the session by identifier and (b) stores the
  system-provided completion handler, invoking it once
  `urlSessionDidFinishEvents(forBackgroundURLSession:)` fires.
- A way to query/subscribe to per-model completion so the app can update UI on
  relaunch (the `async throws` call may no longer be alive — see R11).

### R11 — Progress & completion model
Because completion may outlive the `await`:
- Keep the existing `async throws` `Acervo.download(...)` working for the
  **foreground/macOS** path.
- For iOS background, offer a **callback/observation** completion model (e.g. an
  `AsyncStream` of model-level events, or a delegate/notification) that is
  independent of any live continuation. The `async` overload on iOS should either
  bridge to this (resolving if the app stays alive) or be documented as
  best-effort-foreground with the observation API as the source of truth.
- Progress callbacks remain `@Sendable`.

## 6. Host-app / SwiftVinetas integration requirements (out of scope for this repo, documented here)

These land in Vinetas and/or SwiftVinetas, not SwiftAcervo, but the SwiftAcervo
API (R10/R11) must enable them:

- **iOS app:** implement
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` in
  `VinetasIOSApp` / its `UIApplicationDelegate`, forwarding to R10.
- **Background modes:** no special `UIBackgroundModes` entitlement is required for
  background `URLSession` transfers, but confirm during implementation.
- **App Group:** the background session's `sharedContainerIdentifier` must match
  the app's `group.intrusive-memory.models` entitlement.
- **SwiftVinetas:** `VinetasClient.download(model:progress:)` must forward the
  new completion/observation model rather than assuming a single awaitable.
- **UI:** reflect "download continues in background" and reconcile state on
  relaunch (progress/complete/failed) from the observation API.

## 7. API / compatibility constraints

- **No breaking change to the macOS/foreground public API.** `Acervo.download`,
  `AcervoManager.download`, `AcervoDownloadProgress`, and the `@Sendable` progress
  callback keep their current signatures and semantics on macOS/CLI.
- New iOS surface (R10/R11) is **additive**.
- Semver: additive API + new platform behavior → **minor** bump (0.24.0).

## 8. Testing requirements

- Unit: transport abstraction (R9) selects background on iOS, foreground on macOS.
- Unit: multi-file ledger (R3) — reconciliation, partial completion, idempotent
  re-attach.
- Unit: integrity gate (R5) rejects a corrupted delivered file before the move.
- Unit: redirect pinning (R6) on the background delegate.
- Integration (macOS, CI-runnable): the foreground path is unchanged and still
  passes the existing download tests.
- iOS background transfer cannot be fully exercised in CI (requires the device
  daemon + suspension); cover it with a device/manual test checklist and unit-test
  the delegate/ledger seams around it. **Do not** add an iOS integration test that
  can't run reliably in CI.

## 9. Risks & open questions

- **State durability (R3) is the hard part.** Getting multi-file completion
  correct across app termination is where the real complexity and bug surface
  lives — more than the session config itself.
- **`async throws` semantics (R11).** Decide explicitly whether the iOS `async`
  overload bridges to observation or is deprecated in favor of it. Downstream
  callers (SwiftVinetas) depend on this choice.
- **Discretionary scheduling (R8).** `isDiscretionary`/system scheduling can delay
  downloads unpredictably; keep user-initiated downloads non-discretionary.
- **Verification cost on-device.** SHA-256 over multi-GB files at completion is
  CPU-heavy; ensure it runs off the main thread and does not trip the background
  execution-time budget during `handleEvents…`.

## 10. Out of scope

- Any change to the macOS/CLI download path (§2, R9).
- Background *uploads* (`acervo ship`) — unaffected; this is download-only.
- CDN/manifest format changes.
- The App Store / distribution flow.
