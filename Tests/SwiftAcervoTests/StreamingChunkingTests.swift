import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// CI-gated tests for the delegate-driven chunked download path in
/// `streamDownloadFile`. These are the exit-criterion tests added by
/// `chunked-streaming/S1` (OPERATION QUARTERMASTER TORRENT):
///
///   1. **Single-request redirect rejection** — a `URLProtocol` mock
///      returns a 301 to a non-CDN host; the download fails because
///      `SecureDownloadDelegate.willPerformHTTPRedirection` rejects the
///      hop, the original 3xx response is delivered to the data task,
///      and the downloader surfaces the failure.
///   2. **Single-request resume on the delegate path** — start from a
///      partial `.part` at a known offset, complete via the new
///      delegate-driven flow against a `URLProtocol` mock, and assert
///      that the final SHA-256 matches the manifest.
///
/// Both tests use a synthetic file size **below** `parallelRangeThreshold`,
/// so the single-request path is the only code path exercised. Parallel
/// ranges are tested on a separate (out-of-CI) performance plan owned by
/// Sortie 2.
///
/// Nested under `SharedStaticStateSuite.MockURLProtocolSuite` to inherit
/// the grandparent's `.serialized` trait so the shared `MockURLProtocol`
/// responder/counter can't race.
extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Streaming Chunking Tests (S1 exit criteria)")
  struct StreamingChunkingTests {

    // MARK: - Fixture helpers

    /// 16 MiB synthetic body — comfortably below `parallelRangeThreshold`
    /// (64 MiB), so the single-request path is the only path exercised.
    private static let totalSize: Int = 16 * 1024 * 1024
    private static let halfSize: Int = 8 * 1024 * 1024

    private static func makeBody() -> Data {
      Data(bytes: (0..<totalSize).map { UInt8($0 % 256) }, count: totalSize)
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

    // MARK: - Test 1: Single-request redirect rejection

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

    // MARK: - Test 2: Single-request resume on the delegate path

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
  }
}
