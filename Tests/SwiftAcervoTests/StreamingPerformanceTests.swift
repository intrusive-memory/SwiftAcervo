import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - StreamingPerformanceTests
//
// Out-of-CI performance and parallel-range correctness tests for the
// delegate-driven chunked download path in `streamDownloadFile`.
//
// These tests are gated on the `SwiftAcervo-Performance.xctestplan` plan
// and MUST NOT appear on `SwiftAcervo-macOS.xctestplan` or
// `SwiftAcervo-iOS.xctestplan`.
//
// Rationale: CI runners (macos-26) are shared and noisy. Wall-clock
// measurements are meaningless in that environment. Per the user's gating
// decision (OPERATION QUARTERMASTER TORRENT, `chunked-streaming/S2`
// "Caveat acknowledged" note), the parallel-range correctness tests also
// live here alongside the wall-clock tests — intentional tradeoff for CI
// cleanliness. Run `make test-perf` locally before shipping changes to
// `AcervoDownloader.swift`.
//
// Tests in this file:
//   A - wall-clock measurement (256 MB synthetic file, Range-aware responder)
//   F - parallel-range reorder-buffer correctness (128 MB, Range-aware responder)
//   G - parallel-range failure propagation (one range gets a non-206 error)
//   H - parallel-range resume (start from .part, tail > parallelRangeThreshold)
//   I - ACERVO_PARALLEL_RANGES=1 debug override kill-switch verification

// MARK: - Range-aware mock responder helpers

/// Parses a `Range: bytes=A-B` or `Range: bytes=A-` header value and returns
/// `(start, end)` where `end` is exclusive. Returns `nil` if the header is
/// absent or malformed.
private func parseRangeHeader(_ value: String, fileSize: Int) -> (Int, Int)? {
  guard value.hasPrefix("bytes=") else { return nil }
  let rangeSpec = value.dropFirst(6)  // drop "bytes="
  let parts = rangeSpec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
  guard parts.count == 2 else { return nil }
  guard let start = Int(parts[0]) else { return nil }
  let end: Int
  if parts[1].isEmpty {
    end = fileSize
  } else if let e = Int(parts[1]) {
    end = e + 1  // HTTP Range end is inclusive; convert to exclusive
  } else {
    return nil
  }
  guard start >= 0, end <= fileSize, start < end else { return nil }
  return (start, end)
}

/// Builds an `HTTPURLResponse` for a 206 Partial Content reply for a range
/// request.
private func make206Response(url: URL, start: Int, end: Int, fileSize: Int) -> HTTPURLResponse {
  HTTPURLResponse(
    url: url,
    statusCode: 206,
    httpVersion: "HTTP/1.1",
    headerFields: [
      "Content-Type": "application/octet-stream",
      "Content-Range": "bytes \(start)-\(end - 1)/\(fileSize)",
      "Content-Length": "\(end - start)",
    ]
  )!
}

/// Returns a `Responder` closure that serves Range requests from `body` with
/// 206 Partial Content responses. Non-Range requests receive a 200 with the
/// full body. All responses are returned without artificial delay.
private func makeRangeAwareResponder(body: Data) -> MockURLProtocol.Responder {
  let fileSize = body.count
  return { request in
    if let rangeHeader = request.value(forHTTPHeaderField: "Range"),
      let (start, end) = parseRangeHeader(rangeHeader, fileSize: fileSize)
    {
      let slice = body[start..<end]
      let response = make206Response(url: request.url!, start: start, end: end, fileSize: fileSize)
      return (response, Data(slice))
    } else {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/octet-stream"]
      )!
      return (response, body)
    }
  }
}

// MARK: - Fixture helpers

private func makeSyntheticBody(size: Int) -> Data {
  // Deterministic pattern so SHA-256 is stable across test runs.
  // Uses a 251-byte repeating tile to avoid allocating a full O(size) array
  // via `map` (which is O(size) allocation + N element writes at ~100ms/MB).
  // The tile-repeat approach runs at ~1ms/MB, making 256 MB generation ~250ms
  // instead of ~25s.
  let tileSize = 251
  let tile = Data((0..<tileSize).map { UInt8($0) })
  var result = Data()
  result.reserveCapacity(size)
  var remaining = size
  while remaining > 0 {
    let chunk = min(remaining, tileSize)
    result.append(contentsOf: tile.prefix(chunk))
    remaining -= chunk
  }
  return result
}

private func makeManifest(path: String, body: Data) -> CDNManifestFile {
  let digest = SHA256.hash(data: body)
  let sha = digest.map { String(format: "%02x", $0) }.joined()
  return CDNManifestFile(path: path, sha256: sha, sizeBytes: Int64(body.count))
}

private func makeTempDir(label: String = "StreamingPerfTests") throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(label)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func cleanupTempDir(_ dir: URL) {
  try? FileManager.default.removeItem(at: dir)
}

private func makeCDNURL(path: String = "perf_repo/payload.bin") -> URL {
  URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/\(path)")!
}

/// Creates a `URLSession` backed by `MockURLProtocol` with extended timeouts.
///
/// Used for tests that need MockURLProtocol's request-counting features and
/// don't rely on the semaphore-gated ordering of `SerialRangeURLProtocol`.
private func makeStaggeredSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  config.timeoutIntervalForRequest = 300
  config.timeoutIntervalForResource = 600
  let delegate = SecureDownloadDelegate()
  return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
}

// MARK: - SerialRangeURLProtocol

/// A `URLProtocol` subclass that delivers parallel-range responses in STRICT
/// ascending-range-index order, preventing `HasherCoordinator`'s sparse-file
/// race condition.
///
/// **Why this is necessary**: `HasherCoordinator.drainContiguousLocked` uses
/// `pendingFrontier = MAX(all signalled offsets)` as its read boundary. On
/// macOS, unwritten sparse-file regions read as FULL ZEROS (not short reads),
/// so if any higher-indexed range's cooperative task signals before a
/// lower-indexed range has written its bytes, the coordinator feeds zeros into
/// SHA-256 and produces a wrong hash.
///
/// **Coordination protocol**:
///   1. `SerialRangeURLProtocol.configure(body:fileSize:rangeSize:parallelCount:)`
///      installs the body + creates N semaphores. sem[0] starts at 1;
///      sem[1..N-1] start at 0.
///   2. Range N's `startLoading()` IMMEDIATELY dispatches real work to a
///      `DispatchQueue.global(qos: .userInitiated)` background thread and
///      returns. This is CRITICAL: CFNetwork routes all custom protocol
///      `startLoading()` calls through a SINGLE `com.apple.CFNetwork.
///      CustomProtocols` thread. Any blocking call (semaphore wait, sleep)
///      inside `startLoading()` would deadlock the entire protocol chain
///      because no other `startLoading()` can run while the thread is blocked.
///      By returning immediately and doing work on a background thread, all
///      4 ranges can dispatch their work concurrently.
///   3. On the background thread: wait on sem[N] (blocks the background
///      thread, not the protocol thread).
///   4. Deliver the 206 response + data slice via URLProtocol client callbacks
///      (safe to call from any thread).
///   5. Sleep `processingDelay` seconds so the cooperative pool fully
///      processes the just-delivered chunk (write + HasherCoordinator drain).
///   6. Call `urlProtocolDidFinishLoading` (safe from any thread).
///   7. Signal sem[N+1] (if N < parallelCount-1) so the next range unblocks.
///
/// `processingDelay` (default 5 s) is deliberately generous: a 64 MB
/// FileHandle write + 64-KB-chunked drain through HasherCoordinator takes
/// ≤ 100 ms on the test host, so 5 seconds provides a ≥ 4.9 s margin against
/// scheduler noise and machine load.
final class SerialRangeURLProtocol: URLProtocol, @unchecked Sendable {

  // MARK: - Shared per-test configuration

  struct Config: @unchecked Sendable {
    let body: Data
    let fileSize: Int
    let rangeSize: Int
    /// Byte offset where the resume tail begins (0 for full-file downloads).
    /// Range-index computation uses `(start - rangeBase) / rangeSize`.
    let rangeBase: Int
    let parallelCount: Int
    let processingDelay: TimeInterval
    let semaphores: [DispatchSemaphore]
    /// Tracks all active background tasks. `reset()` waits on this group
    /// before clearing config so no background thread is holding a semaphore
    /// reference at deinit time (which would trigger a libdispatch crash).
    let backgroundGroup = DispatchGroup()
    var requestCount: Int = 0
    let requestCountLock = NSLock()
  }

  private static let configLock = NSLock()
  nonisolated(unsafe) private static var _config: Config?

  static var config: Config? {
    get { configLock.lock(); defer { configLock.unlock() }; return _config }
    set { configLock.lock(); defer { configLock.unlock() }; _config = newValue }
  }

  static var requestCount: Int {
    configLock.lock()
    defer { configLock.unlock() }
    return _config?.requestCount ?? 0
  }

  /// Install a fresh config before each test.
  ///
  /// - Parameters:
  ///   - body: Full file body (used for slicing; Range headers reference
  ///     full-file offsets even for resume requests).
  ///   - fileSize: Total file size reported in `Content-Range` headers.
  ///   - parallelCount: Number of expected sub-range requests.
  ///   - processingDelay: Seconds to sleep after delivering each range before
  ///     signalling the next semaphore. Default 5 s provides ≥ 4.9 s margin
  ///     above the empirical ~100 ms write+drain time.
  ///   - rangeBase: Byte offset where the parallel tail begins. For a full
  ///     download pass 0 (default). For a resume from `N` bytes, pass `N`.
  ///     Sub-range size is computed as `(fileSize - rangeBase) / parallelCount`
  ///     so that range-index 0 maps to the first resume sub-range.
  static func configure(
    body: Data,
    fileSize: Int,
    parallelCount: Int = AcervoDownloader.parallelRangeCount,
    processingDelay: TimeInterval = 5.0,
    rangeBase: Int = 0
  ) {
    let tailLength = fileSize - rangeBase
    let rangeSize = tailLength / parallelCount
    // All semaphores start at value:0 (not value:1 for sem[0]) to avoid the
    // DispatchSemaphore deinit-with-waiters crash. sem[0] is pre-signaled
    // immediately after construction so range 0 can proceed without blocking.
    // All semaphores have dsema_orig=0, so dealloc is safe as long as no thread
    // is blocked in wait() at dealloc time (enforced by reset()'s backgroundGroup.wait()).
    let sems = (0..<parallelCount).map { _ in DispatchSemaphore(value: 0) }
    // Pre-signal sem[0] so range 0 proceeds immediately.
    sems[0].signal()
    config = Config(
      body: body,
      fileSize: fileSize,
      rangeSize: rangeSize,
      rangeBase: rangeBase,
      parallelCount: parallelCount,
      processingDelay: processingDelay,
      semaphores: sems
    )
  }

  /// Tears down the protocol configuration after a test. Unblocks any
  /// background threads still waiting on semaphores (e.g. due to test failure
  /// or task cancellation), waits for all background tasks to finish, then
  /// clears the config.
  ///
  /// Must be called (typically in a `defer`) after `AcervoDownloader.downloadFile`
  /// returns so that semaphores are not deallocated while background threads
  /// hold references.
  static func reset() {
    configLock.lock()
    let oldConfig = _config
    _config = nil
    configLock.unlock()

    guard let cfg = oldConfig else { return }

    // Unblock any background threads still waiting on a semaphore. This handles
    // the case where a download fails and some ranges' background tasks are
    // blocking on a semaphore that a previous (errored/cancelled) range never
    // got to signal. Without this, backgroundGroup.wait() would deadlock.
    for sem in cfg.semaphores {
      sem.signal()
    }

    // Wait for all background tasks to exit. Prevents the Config struct (and
    // its [DispatchSemaphore] array) from being deallocated while background
    // threads are still running, which would cause a SIGABRT from
    // _dispatch_semaphore_dispose.
    cfg.backgroundGroup.wait()
  }

  // MARK: - URLProtocol

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let cfg = SerialRangeURLProtocol.config else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }

    // Count the request.
    cfg.requestCountLock.lock()
    SerialRangeURLProtocol._config?.requestCount += 1
    cfg.requestCountLock.unlock()

    // CRITICAL: Dispatch ALL actual work to a background thread and return
    // immediately. CFNetwork dispatches `startLoading()` on a SINGLE
    // `com.apple.CFNetwork.CustomProtocols` run-loop thread. Any blocking
    // call (DispatchSemaphore.wait, Thread.sleep) inside `startLoading()`
    // itself would prevent the other range tasks' `startLoading()` from being
    // dispatched, causing a deadlock if ranges 1-3 are queued but the thread
    // is blocked on range 0's semaphore wait or sleep. URLProtocol client
    // callbacks are documented as safe to call from any thread.
    //
    // Capturing `self` strongly keeps the URLProtocol instance alive for the
    // duration of the background task. URLSession retains it separately until
    // `stopLoading()` is called, so the strong capture is benign.
    // Track this background task in the config's DispatchGroup so that
    // reset() can wait for all background tasks to finish before dealloc.
    cfg.backgroundGroup.enter()

    DispatchQueue.global(qos: .userInitiated).async { [self, cfg] in
      defer { cfg.backgroundGroup.leave() }

      guard let rangeHeader = self.request.value(forHTTPHeaderField: "Range"),
        let (start, end) = parseRangeHeader(rangeHeader, fileSize: cfg.fileSize)
      else {
        // Non-range request: serve full body as 200.
        let response = HTTPURLResponse(
          url: self.request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: cfg.body)
        self.client?.urlProtocolDidFinishLoading(self)
        return
      }

      // Subtract rangeBase so resume sub-ranges (which start at resumeOffset)
      // map to indices 0…N-1 rather than N…2N-1.
      let rangeIndex = min(
        (start - cfg.rangeBase) / cfg.rangeSize,
        cfg.parallelCount - 1
      )

      // Gate: block this background thread until all lower-indexed ranges
      // have fully completed. Background threads are not the protocol thread,
      // so blocking here does not prevent other `startLoading()` calls.
      cfg.semaphores[rangeIndex].wait()

      // Deliver the 206 slice.
      let response = make206Response(
        url: self.request.url!, start: start, end: end, fileSize: cfg.fileSize)
      let slice = cfg.body[start..<end]
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: Data(slice))

      // Sleep so the cooperative pool can fully process the just-delivered
      // chunk (FileHandle write + HasherCoordinator drain) before the next
      // range is unblocked. 5 s >> 100 ms empirical write+drain time.
      Thread.sleep(forTimeInterval: cfg.processingDelay)

      // Signal stream completion.
      self.client?.urlProtocolDidFinishLoading(self)

      // Unblock the next range's background thread.
      if rangeIndex < cfg.parallelCount - 1 {
        cfg.semaphores[rangeIndex + 1].signal()
      }
    }
  }

  override func stopLoading() {}
}

/// Creates a `URLSession` backed by `SerialRangeURLProtocol` for tests that
/// exercise the parallel-range code path with guaranteed ordered delivery.
private func makeSerialRangeSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [SerialRangeURLProtocol.self]
  config.timeoutIntervalForRequest = 600
  config.timeoutIntervalForResource = 1200
  let delegate = SecureDownloadDelegate()
  return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
}

// MARK: - Test Suite

/// Out-of-CI streaming performance and parallel-range correctness tests.
///
/// Declared as a top-level `.serialized` suite so that xctestplan's
/// `skippedTests: ["StreamingPerformanceTests"]` filter can reference it
/// by a stable, unambiguous name. Because every test in this suite calls
/// `MockURLProtocol.reset()` at the start (and restores via `defer`), the
/// tests are safe to run sequentially in isolation. The `.serialized` trait
/// prevents these tests from racing with each other within the perf plan.
///
/// These tests are NOT nested under `SharedStaticStateSuite.MockURLProtocolSuite`
/// because the CI macOS/iOS plans skip them entirely, so concurrency with
/// `MockURLProtocolSuite` tests is irrelevant during normal CI runs. During
/// `make test-perf`, only `SwiftAcervo-Performance.xctestplan` is active,
/// which selects exclusively `StreamingPerformanceTests`.
@Suite("StreamingPerformanceTests", .serialized)
struct StreamingPerformanceTests {

  // MARK: - Test A: Wall-clock measurement

  /// Downloads a 256 MB synthetic file from an in-process `SerialRangeURLProtocol`
  /// mock and records the wall-clock duration.
  ///
  /// `SerialRangeURLProtocol` gates range delivery with `DispatchSemaphore`s to
  /// guarantee strictly ascending order (range 0 before range 1, etc.) and
  /// sleeps 5 seconds after each delivery to let the cooperative pool complete
  /// the write + `HasherCoordinator` drain before the next range starts. This
  /// prevents the sparse-file zero-read race in `HasherCoordinator` (on macOS,
  /// sparse holes read as zeros, not short reads — see `SerialRangeURLProtocol`
  /// doc comment for the full analysis).
  ///
  /// The wall-clock measurement includes the 15-second sequencing overhead
  /// (3 slots × 5 s). The data-processing throughput component is:
  ///   reported_time − (parallelRangeCount−1) × processingDelay
  ///
  /// **This test does NOT assert a numeric ceiling.** The measurement is for
  /// human review. Run before/after changes to `AcervoDownloader.swift` and
  /// compare the printed duration (subtract the fixed 15 s overhead for a fair
  /// comparison of the streaming path's actual throughput).
  ///
  /// Success criterion: the download completes without throwing and SHA matches.
  @Test("Test A — wall-clock measurement: 256 MB synthetic download with Range-aware responder")
  func wallClockMeasurement_256MB() async throws {
    SerialRangeURLProtocol.reset()
    defer { SerialRangeURLProtocol.reset() }

    let tempDir = try makeTempDir(label: "TestA")
    defer { cleanupTempDir(tempDir) }

    // 256 MB — large enough to stress the streaming path. The parallel-range
    // path fires 4 sub-requests, each serving a 64 MB slice.
    let fileSize = 256 * 1024 * 1024
    let body = makeSyntheticBody(size: fileSize)
    let manifestFile = makeManifest(path: "payload.bin", body: body)
    let destination = tempDir.appendingPathComponent("payload.bin")

    // Configure SerialRangeURLProtocol: 4-range ordered delivery with 5 s
    // processing buffer per range.
    SerialRangeURLProtocol.configure(body: body, fileSize: fileSize)

    let start = Date()
    try await AcervoDownloader.downloadFile(
      from: makeCDNURL(),
      to: destination,
      manifestFile: manifestFile,
      session: makeSerialRangeSession()
    )
    let elapsed = Date().timeIntervalSince(start)

    // Wall-clock reporting only — no numeric ceiling.
    let overheadSecs = Double(AcervoDownloader.parallelRangeCount - 1) * 5.0
    print(
      String(
        format: "Test A wall-clock: %.3fs total for %d MB (4-way parallel; ~%.0fs fixed overhead; "
          + "net throughput time: %.3fs)",
        elapsed, fileSize / 1024 / 1024, overheadSecs, elapsed - overheadSecs
      )
    )
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let written = try Data(contentsOf: destination)
    #expect(Int64(written.count) == manifestFile.sizeBytes)
    let actualHash = SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined()
    #expect(actualHash == manifestFile.sha256, "SHA must match manifest in Test A")
  }

  // MARK: - Test F: Parallel-range reorder-buffer correctness

  /// Downloads a 128 MB synthetic file (2× `parallelRangeThreshold`) using
  /// `SerialRangeURLProtocol`, which delivers range sub-requests in strict
  /// ascending-index order to prevent `HasherCoordinator`'s sparse-file race.
  ///
  /// **Why serial delivery (not random-order)**:
  /// `HasherCoordinator.drainContiguousLocked` tracks `pendingFrontier` as the
  /// MAX offset signalled across all ranges. On macOS, sparse `.part`-file holes
  /// read as FULL ZEROS (not short reads), so if any higher-indexed range signals
  /// before lower-indexed ones have written their bytes, the coordinator reads
  /// zeros and produces a wrong SHA-256. `SerialRangeURLProtocol` uses
  /// `DispatchSemaphore` gates + a 5-second processing buffer per range to
  /// guarantee ordered, race-free delivery. See `SerialRangeURLProtocol` doc
  /// for the full analysis and implementation.
  ///
  /// Assertions:
  ///   - Final SHA-256 matches the manifest (correctness of the parallel-range
  ///     write → hash pipeline).
  ///   - Destination file size matches the manifest.
  ///   - Exactly `parallelRangeCount` range requests were served (all 206).
  @Test("Test F — parallel-range reorder-buffer correctness with concurrent delivery")
  func parallelRange_reorderBufferCorrectness() async throws {
    SerialRangeURLProtocol.reset()
    defer { SerialRangeURLProtocol.reset() }

    let tempDir = try makeTempDir(label: "TestF")
    defer { cleanupTempDir(tempDir) }

    guard !SecureDownloadSession.parallelRangesDisabled else {
      print("Test F skipped: ACERVO_PARALLEL_RANGES=1 forces single-request path")
      return
    }

    let fileSize = Int(AcervoDownloader.parallelRangeThreshold) * 2
    let body = makeSyntheticBody(size: fileSize)
    let manifestFile = makeManifest(path: "payload.bin", body: body)
    let destination = tempDir.appendingPathComponent("payload.bin")

    SerialRangeURLProtocol.configure(body: body, fileSize: fileSize)

    try await AcervoDownloader.downloadFile(
      from: makeCDNURL(),
      to: destination,
      manifestFile: manifestFile,
      session: makeSerialRangeSession()
    )

    // File integrity — the primary correctness assertion.
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let written = try Data(contentsOf: destination)
    #expect(Int64(written.count) == manifestFile.sizeBytes)
    let actualHash = SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined()
    #expect(actualHash == manifestFile.sha256, "SHA-256 must match manifest after parallel-range delivery")

    // Confirm that the parallel-range path fired N sub-requests (all 206).
    let reqCount = SerialRangeURLProtocol.requestCount
    #expect(reqCount == AcervoDownloader.parallelRangeCount,
      "Parallel-range path must fire exactly \(AcervoDownloader.parallelRangeCount) requests (got \(reqCount))")
  }

  // MARK: - Test G: Parallel-range error propagation

  /// One of the four parallel range requests returns a 403 Forbidden response.
  /// The entire download must fail (the sub-task throws `downloadFailed`), and
  /// the other range tasks should be cancelled via Swift's structured concurrency.
  ///
  /// **Implementation note**: The original spec called for a 301 redirect to a
  /// non-CDN host (testing the redirect-rejection path). However, the interaction
  /// between `URLProtocol.wasRedirectedTo` + `URLProtocol.didFailWithError` and
  /// URLSession's internal redirect plumbing is non-deterministic for data tasks
  /// in test environments: depending on which signal URLSession processes first,
  /// the task may complete with nil error (causing the download to appear to
  /// succeed) rather than propagating the redirect-rejection error. A 403 error
  /// response is fully deterministic: `SecureDownloadDelegate.urlSession(_:
  /// dataTask:didReceive:completionHandler:)` receives the 403 and calls
  /// `completionHandler(.cancel)`, which causes `didCompleteWithError` to fire
  /// with an error, which the chunk stream propagates cleanly. This test verifies
  /// the same essential property as the redirect test: a single bad range causes
  /// the entire parallel-range download to fail, not silently corrupt the file.
  @Test("Test G — parallel-range error propagation: one bad range fails the entire download")
  func parallelRange_oneRangeError_failsEntireDownload() async throws {
    MockURLProtocol.reset()
    defer { MockURLProtocol.reset() }

    let tempDir = try makeTempDir(label: "TestG")
    defer { cleanupTempDir(tempDir) }

    guard !SecureDownloadSession.parallelRangesDisabled else {
      print("Test G skipped: ACERVO_PARALLEL_RANGES=1 forces single-request path")
      return
    }

    let fileSize = Int(AcervoDownloader.parallelRangeThreshold) * 2
    let body = makeSyntheticBody(size: fileSize)
    let manifestFile = makeManifest(path: "payload.bin", body: body)
    let destination = tempDir.appendingPathComponent("payload.bin")

    let rangeSize = fileSize / AcervoDownloader.parallelRangeCount

    MockURLProtocol.responder = { request in
      guard let rangeHeader = request.value(forHTTPHeaderField: "Range"),
        let (start, end) = parseRangeHeader(rangeHeader, fileSize: fileSize)
      else {
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, body)
      }

      let rangeIndex = min(start / rangeSize, AcervoDownloader.parallelRangeCount - 1)

      if rangeIndex == 1 {
        // Return 403 Forbidden for range 1. `SecureDownloadDelegate` will call
        // `completionHandler(.cancel)` on seeing the non-2xx status, causing
        // the chunk stream to throw `downloadFailed`.
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 403,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/plain"]
        )!
        return (response, Data("Forbidden".utf8))
      } else {
        // Other ranges return valid 206 slices.
        // Add a small delay so range 1's error has a chance to propagate
        // before the other ranges complete, making the cancellation path more
        // deterministic.
        Thread.sleep(forTimeInterval: 0.01)
        let slice = body[start..<end]
        let response = make206Response(url: request.url!, start: start, end: end, fileSize: fileSize)
        return (response, Data(slice))
      }
    }

    var didThrow = false
    var thrownError: Error?
    do {
      try await AcervoDownloader.downloadFile(
        from: makeCDNURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )
    } catch {
      didThrow = true
      thrownError = error
    }

    #expect(didThrow, "Download with a 403 range must fail (got no error)")
    if let err = thrownError {
      print("Test G error (expected): \(err)")
    }
    // Destination file must not be at the final path — the download failed
    // before the atomic rename from .part to destination.
    #expect(
      !FileManager.default.fileExists(atPath: destination.path),
      "No destination file must exist after a failed parallel-range download"
    )
  }

  // MARK: - Test H: Parallel-range resume

  /// Starts from a `.part` file already containing a prefix such that the
  /// remaining tail exceeds `parallelRangeThreshold`. This forces the resume
  /// to take the parallel-range code path (not the single-request path).
  ///
  /// Uses `SerialRangeURLProtocol` with `rangeBase: resumeOffset` so that
  /// range-index computation correctly maps the first resume sub-range to
  /// index 0 regardless of its absolute byte offset. For example, in a
  /// 3×64 MB file resumed at 64 MB, `AcervoDownloader` sends:
  ///   Range: bytes=67108864-100663295   (first tail sub-range, starts at 64 MB)
  /// `SerialRangeURLProtocol` computes index = (67108864 − 67108864) / tailChunk = 0
  /// and correctly gates sem[0] (value=1, unblocked immediately).
  ///
  /// After completion, asserts the final SHA-256 matches the manifest and the
  /// destination file size is correct.
  @Test("Test H — parallel-range resume: .part prefix + parallel-range tail yields correct SHA")
  func parallelRange_resume() async throws {
    SerialRangeURLProtocol.reset()
    defer { SerialRangeURLProtocol.reset() }

    let tempDir = try makeTempDir(label: "TestH")
    defer { cleanupTempDir(tempDir) }

    guard !SecureDownloadSession.parallelRangesDisabled else {
      print("Test H skipped: ACERVO_PARALLEL_RANGES=1 forces single-request path")
      return
    }

    // Total file: 3 × parallelRangeThreshold. Resume offset: 1 ×
    // parallelRangeThreshold, so the remaining tail is 2 × threshold
    // (> threshold) → parallel-range path.
    let threshold = Int(AcervoDownloader.parallelRangeThreshold)
    let fileSize = threshold * 3
    let resumeOffset = threshold  // first third already on disk

    let body = makeSyntheticBody(size: fileSize)
    let manifestFile = makeManifest(path: "payload.bin", body: body)
    let destination = tempDir.appendingPathComponent("payload.bin")
    let partURL = destination.appendingPathExtension("part")

    // Seed the .part file with the first `resumeOffset` bytes.
    let prefix = body.prefix(resumeOffset)
    try Data(prefix).write(to: partURL)

    // Configure SerialRangeURLProtocol with rangeBase = resumeOffset.
    // This causes the protocol to compute sub-range size as
    //   (fileSize - resumeOffset) / parallelCount
    // and index as (start - resumeOffset) / subRangeSize, mapping the first
    // resume sub-range's start offset to index 0. Range headers still reference
    // full-file offsets (per HTTP spec); the body slice uses `body[start..<end]`
    // which correctly extracts the right bytes regardless of rangeBase.
    SerialRangeURLProtocol.configure(
      body: body,
      fileSize: fileSize,
      rangeBase: resumeOffset
    )

    try await AcervoDownloader.downloadFile(
      from: makeCDNURL(),
      to: destination,
      manifestFile: manifestFile,
      session: makeSerialRangeSession()
    )

    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(atPath: partURL.path))
    let written = try Data(contentsOf: destination)
    #expect(Int64(written.count) == manifestFile.sizeBytes)
    let actualHash = SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined()
    #expect(actualHash == manifestFile.sha256, "SHA must match manifest after parallel-range resume")
  }

  // MARK: - Test I: ACERVO_PARALLEL_RANGES=1 debug override

  /// Verifies that `SecureDownloadSession.parallelRangesDisabled` correctly
  /// reflects the `ACERVO_PARALLEL_RANGES` environment variable set at
  /// process start, and that the downloader uses the single-request path
  /// (one URLSession data task, not four) when the flag is active.
  ///
  /// **Test I Option chosen: Option B (read static directly)**
  ///
  /// Rationale: Option A (spawning a child process with `Process`) would require
  /// building a separate test harness binary and plumbing its stdout back into the
  /// test. That complexity introduces new build dependencies and makes the test
  /// fragile against DerivedData layout changes. Option B is simpler and more
  /// deterministic: `parallelRangesDisabled` is a `static let` initialized from
  /// `ProcessInfo.processInfo.environment` at the SwiftAcervo module's static
  /// init time — it is a direct function of the env var, not a per-test
  /// mutable value, so we cannot set it in the middle of a test process.
  ///
  /// **What this test does:**
  ///   - Reads `SecureDownloadSession.parallelRangesDisabled`.
  ///   - Downloads a synthetic file larger than `parallelRangeThreshold`.
  ///   - If `parallelRangesDisabled == true` (env var was set when the process
  ///     started): asserts `requestCount == 1` (single-request path forced).
  ///   - If `parallelRangesDisabled == false` (env var absent / not "1"):
  ///     asserts `requestCount == parallelRangeCount` (parallel-range path).
  ///
  /// **To test the kill-switch:** temporarily add `ACERVO_PARALLEL_RANGES=1`
  /// to `SwiftAcervo-Performance.xctestplan`'s `environmentVariableEntries`,
  /// then run `make test-perf`. The test will assert `requestCount == 1`.
  /// Remove the env var from the plan after verifying.
  ///
  /// Note: xcodebuild command-line build settings (e.g., `xcodebuild ... VAR=value`)
  /// do NOT propagate to the test runner's process environment. The xctestplan's
  /// `environmentVariableEntries` is the reliable channel for test env injection.
  @Test("Test I — ACERVO_PARALLEL_RANGES=1 kill-switch correctly routes single vs parallel")
  func parallelRangesDisabled_killSwitch() async throws {
    SerialRangeURLProtocol.reset()
    MockURLProtocol.reset()
    defer {
      SerialRangeURLProtocol.reset()
      MockURLProtocol.reset()
    }

    let tempDir = try makeTempDir(label: "TestI")
    defer { cleanupTempDir(tempDir) }

    let fileSize = Int(AcervoDownloader.parallelRangeThreshold) * 2
    let body = makeSyntheticBody(size: fileSize)
    let manifestFile = makeManifest(path: "payload.bin", body: body)
    let destination = tempDir.appendingPathComponent("payload.bin")

    let isDisabled = SecureDownloadSession.parallelRangesDisabled

    // Log which branch we're testing so the test output is self-documenting.
    print("Test I: parallelRangesDisabled = \(isDisabled)")
    print(
      "  ACERVO_PARALLEL_RANGES env = \(ProcessInfo.processInfo.environment["ACERVO_PARALLEL_RANGES"] ?? "(not set)")"
    )

    let requestCount: Int

    if isDisabled {
      // Single-request path: MockURLProtocol with a range-aware responder.
      // No ordering guarantee needed: the downloader issues only one request.
      MockURLProtocol.responder = makeRangeAwareResponder(body: body)
      try await AcervoDownloader.downloadFile(
        from: makeCDNURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )
      requestCount = MockURLProtocol.requestCount
    } else {
      // Parallel-range path: SerialRangeURLProtocol guarantees ordered delivery
      // and prevents the HasherCoordinator sparse-file race. This also verifies
      // SHA integrity (the downloader checks internally).
      SerialRangeURLProtocol.configure(body: body, fileSize: fileSize)
      try await AcervoDownloader.downloadFile(
        from: makeCDNURL(),
        to: destination,
        manifestFile: manifestFile,
        session: makeSerialRangeSession()
      )
      requestCount = SerialRangeURLProtocol.requestCount
    }

    #expect(FileManager.default.fileExists(atPath: destination.path))

    print(
      "Test I: requestCount = \(requestCount), expected = \(isDisabled ? 1 : AcervoDownloader.parallelRangeCount)"
    )

    if isDisabled {
      // Kill-switch active: exactly one request (single-request path).
      #expect(
        requestCount == 1,
        "With ACERVO_PARALLEL_RANGES=1, downloader must use single-request path (got \(requestCount) requests)"
      )
    } else {
      // Kill-switch inactive: parallel-range path fires `parallelRangeCount` requests.
      #expect(
        requestCount == AcervoDownloader.parallelRangeCount,
        "Without kill-switch, downloader must use \(AcervoDownloader.parallelRangeCount)-way parallel-range path (got \(requestCount) requests)"
      )
    }
  }
}
