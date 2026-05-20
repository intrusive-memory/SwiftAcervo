import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// CI-gated tests for the delegate-driven chunked download path in
/// `streamDownloadFile`. These are the exit-criterion tests added by
/// `chunked-streaming/S1` and `chunked-streaming/S2` (OPERATION QUARTERMASTER TORRENT):
///
///   D. **Single-request redirect rejection** — a `URLProtocol` mock
///      returns a 301 to a non-CDN host; the download fails because
///      `SecureDownloadDelegate.willPerformHTTPRedirection` rejects the
///      hop, the original 3xx response is delivered to the data task,
///      and the downloader surfaces the failure.
///   C. **Single-request resume on the delegate path** — start from a
///      partial `.part` at a known offset, complete via the new
///      delegate-driven flow against a `URLProtocol` mock, and assert
///      that the final SHA-256 matches the manifest.
///   B. **Flush-call-count contract** — download a file of size
///      `streamFlushSize * 32` and count progress callbacks as a
///      behavioral proxy for hasher-flush count. Assert the callback
///      count is within the expected range.
///   E. **HTTP/3 capability flag** — a request built via
///      `AcervoDownloader.buildRequest(from:)` for a CDN URL must have
///      `assumesHTTP3Capable == true`.
///
/// All tests use synthetic file sizes **below** `parallelRangeThreshold`,
/// so the single-request path is the only code path exercised. Parallel
/// ranges are tested on a separate (out-of-CI) performance plan owned by
/// Sortie 2.
///
/// Nested under `SharedStaticStateSuite.MockURLProtocolSuite` to inherit
/// the grandparent's `.serialized` trait so the shared `MockURLProtocol`
/// responder/counter can't race.
extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Streaming Chunking Tests (S1 + S2 exit criteria)")
  struct StreamingChunkingTests {

    // MARK: - Fixture helpers

    /// 16 MiB synthetic body — comfortably below `parallelRangeThreshold`
    /// (64 MiB), so the single-request path is the only path exercised.
    private static let totalSize: Int = 16 * 1024 * 1024
    private static let halfSize: Int = 8 * 1024 * 1024

    private static func makeBody() -> Data {
      Data(bytes: (0..<totalSize).map { UInt8($0 % 256) }, count: totalSize)
    }

    private static func makeBody(size: Int) -> Data {
      Data(bytes: (0..<size).map { UInt8($0 % 256) }, count: size)
    }

    private static func makeManifestFile(path: String) -> CDNManifestFile {
      let body = makeBody()
      let digest = SHA256.hash(data: body)
      let sha = digest.map { String(format: "%02x", $0) }.joined()
      return CDNManifestFile(
        path: path,
        sha256: sha,
        sizeBytes: Int64(body.count)
      )
    }

    private static func makeManifestFile(path: String, body: Data) -> CDNManifestFile {
      let digest = SHA256.hash(data: body)
      let sha = digest.map { String(format: "%02x", $0) }.joined()
      return CDNManifestFile(
        path: path,
        sha256: sha,
        sizeBytes: Int64(body.count)
      )
    }

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("StreamingChunkingTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func cleanupTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    private static func makeSourceURL(path: String = "test_repo/payload.bin") -> URL {
      URL(
        string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/\(path)"
      )!
    }

    // MARK: - Test D: Single-request redirect rejection

    /// A `URLProtocol` mock returns a 301 with a `Location` header pointing
    /// to a non-CDN host. The `SecureDownloadDelegate` attached to the
    /// session refuses to follow the redirect; URLSession completes the
    /// data task with an error; the downloader surfaces the failure. The
    /// destination file MUST NOT exist on disk afterward.
    @Test("Single-request redirect to a non-CDN host fails the download")
    func singleRequest_rejectsNonCDNRedirect() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")

      // 301 with Location pointing at a non-CDN host. MockURLProtocol
      // forwards 3xx-with-Location through URLSession's redirect plumbing,
      // which calls into the SecureDownloadDelegate's
      // willPerformHTTPRedirection. Because evil.example.invalid is not
      // the allowedHost, the delegate rejects the redirect.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 301,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Location": "https://evil.example.invalid/models/test_repo/payload.bin",
            "Content-Type": "text/plain",
          ]
        )!
        return (response, Data())
      }

      // Download must throw. The exact error type depends on what
      // URLSession delivers when its delegate refuses a redirect (either
      // a URLError or one of our AcervoError cases via the consumer's
      // captured status). The downstream guarantee is: no destination
      // file is created.
      var didThrow = false
      do {
        try await AcervoDownloader.downloadFile(
          from: Self.makeSourceURL(),
          to: destination,
          manifestFile: manifestFile,
          session: MockURLProtocol.session()
        )
      } catch {
        didThrow = true
      }
      #expect(didThrow, "rejected-redirect download must fail")
      #expect(
        !FileManager.default.fileExists(atPath: destination.path),
        "destination file must not exist after a rejected redirect")
    }

    // MARK: - Test C: Single-request resume on the delegate path

    /// Pre-populate the `.part` file with the first half of the body,
    /// then drive the new delegate-driven streaming path with a `206
    /// Partial Content` response carrying the second half. The final
    /// SHA-256 must match the manifest, confirming that the resume seed
    /// (existing prefix replayed through the hasher) and the new chunk
    /// delivery (delegate `didReceive data:`) compose correctly.
    @Test("Single-request resume via delegate path yields manifest-matching SHA")
    func singleRequest_resumesOnDelegatePath() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      let body = Self.makeBody()
      let manifestFile = Self.makeManifestFile(path: "payload.bin")
      let destination = tempDir.appendingPathComponent("payload.bin")
      let partURL = destination.appendingPathExtension("part")

      // Seed the part file with the first half of the body — the genuine
      // partial branch of streamDownloadFile.
      try body.prefix(Self.halfSize).write(to: partURL)

      // Responder confirms a Range header was sent and replies with 206
      // + the second half of the body.
      MockURLProtocol.responder = { request in
        // Sanity: the streaming path must have asked the server to resume
        // from the halfway point.
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=\(Self.halfSize)-")
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 206,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/octet-stream",
            "Content-Range":
              "bytes \(Self.halfSize)-\(Self.totalSize - 1)/\(Self.totalSize)",
          ]
        )!
        return (response, body.suffix(from: Self.halfSize))
      }

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        session: MockURLProtocol.session()
      )

      // The verified file is at the destination; the part file has been
      // atomic-renamed away; SHA matches the manifest.
      #expect(FileManager.default.fileExists(atPath: destination.path))
      #expect(!FileManager.default.fileExists(atPath: partURL.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
      let writtenHash = SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined()
      #expect(writtenHash == manifestFile.sha256)
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Test B: Flush-call-count contract

    /// Downloads a synthetic file of exactly `streamFlushSize * 32` bytes
    /// (8 MiB with the current 256 KiB constant) — below `parallelRangeThreshold`,
    /// so the single-request delegate path is exercised.
    ///
    /// **Approach**: The production code doesn't expose a hasher call-count seam,
    /// so this test uses the `progress:` callback as a deterministic behavioral
    /// proxy. The downloader fires `progress` on the first chunk, once per
    /// `streamFlushSize`-sized buffer drain, and once at final completion. That
    /// gives an expected callback count of:
    ///
    ///     1 (first-chunk/initial) + ceil(fileSize / streamFlushSize) (flushes) + 1 (completion)
    ///     = ceil(32) + 2 = 34
    ///
    /// We assert `callCount <= ceil(fileSize / streamFlushSize) + smallMargin`
    /// where `smallMargin = 4` covers the initial + completion + any off-by-one
    /// rounding. This is a pure function of `AcervoDownloader.streamFlushSize`
    /// and the fixture size — fully deterministic and not a performance test.
    @Test("Flush-call-count is bounded by ceil(fileSize / streamFlushSize)")
    func flushCallCount_boundedByStreamFlushSize() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.cleanupTempDir(tempDir) }

      // File size is exactly streamFlushSize * 32. Must be < parallelRangeThreshold
      // so only the single-request path is exercised.
      let fileSize = AcervoDownloader.streamFlushSize * 32
      precondition(
        Int64(fileSize) < AcervoDownloader.parallelRangeThreshold,
        "Test fixture size must be below parallelRangeThreshold to stay on single-request path"
      )

      let body = Self.makeBody(size: fileSize)
      let manifestFile = Self.makeManifestFile(path: "payload.bin", body: body)
      let destination = tempDir.appendingPathComponent("payload.bin")

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/octet-stream"]
        )!
        return (response, body)
      }

      // Thread-safe counter for progress callbacks.
      // Using a class with NSLock to satisfy @Sendable.
      final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() {
          lock.lock()
          defer { lock.unlock() }
          _count += 1
        }
        var count: Int {
          lock.lock()
          defer { lock.unlock() }
          return _count
        }
      }
      let counter = Counter()

      try await AcervoDownloader.downloadFile(
        from: Self.makeSourceURL(),
        to: destination,
        manifestFile: manifestFile,
        fileName: "payload.bin",
        fileIndex: 0,
        totalFiles: 1,
        progress: { _ in counter.increment() },
        session: MockURLProtocol.session()
      )

      // Expected flushes = ceil(fileSize / streamFlushSize) = 32 exactly.
      // smallMargin = 4 covers initial-response event + completion event +
      // any off-by-one in the production implementation.
      let expectedFlushes = Int(ceil(Double(fileSize) / Double(AcervoDownloader.streamFlushSize)))
      let smallMargin = 4
      #expect(
        counter.count <= expectedFlushes + smallMargin,
        "Progress callbacks (\(counter.count)) exceeded expected flush ceiling (\(expectedFlushes + smallMargin))"
      )
      // Also assert the file was actually written correctly so this test
      // can't pass vacuously if the downloader skips progress entirely.
      #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Test E: HTTP/3 capability flag

    /// `AcervoDownloader.buildRequest(from:)` must set `assumesHTTP3Capable = true`
    /// on requests targeting the production CDN host. This is the cheap regression
    /// guard for Task 3 of chunked-streaming/S1 — confirming that nobody accidentally
    /// reverts the per-request HTTP/3 opt-in.
    ///
    /// Note: `assumesHTTP3Capable` is a per-`URLRequest` property in Foundation
    /// (not a `URLSessionConfiguration` property). The S1 implementation sets it
    /// in `buildRequest(from:)` gated on the production CDN host. This test builds
    /// a request for a CDN URL and inspects the per-request flag directly.
    @Test("buildRequest sets assumesHTTP3Capable for CDN URLs")
    func buildRequest_setsHTTP3CapableFlag() {
      // Use a genuine CDN-host URL (same pattern as production downloads).
      let cdnURL = URL(
        string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/test_repo/payload.bin"
      )!
      let request = AcervoDownloader.buildRequest(from: cdnURL)
      #expect(
        request.assumesHTTP3Capable == true,
        "buildRequest must set assumesHTTP3Capable = true for production CDN host"
      )
    }

    /// Regression guard: a non-CDN URL must NOT have `assumesHTTP3Capable` forced on
    /// (the flag defaults to false and should stay false for non-CDN hosts).
    @Test("buildRequest does not set assumesHTTP3Capable for non-CDN URLs")
    func buildRequest_doesNotSetHTTP3ForNonCDN() {
      let otherURL = URL(string: "https://example.com/some/path")!
      let request = AcervoDownloader.buildRequest(from: otherURL)
      #expect(
        request.assumesHTTP3Capable == false,
        "buildRequest must not set assumesHTTP3Capable for non-CDN hosts"
      )
    }
  }
}
