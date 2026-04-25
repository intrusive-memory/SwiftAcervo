import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Sortie 1 smoke test: verifies that `session:` is threaded through the
/// file-download path so a `MockURLProtocol`-backed session can intercept
/// the streaming request and deliver a canned body.
///
/// Nested under `MockURLProtocolSuite` so it inherits `.serialized` — the
/// mock's static storage is not safe to race against sibling suites.
extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Download Session Injection")
  struct DownloadSessionInjection {

    @Test("streamDownloadFile uses the injected session and roundtrips the body")
    func injectedSessionRoundtripsBody() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // Stubbed body and its SHA-256 / size, used to build a manifest entry
      // the verification path will accept.
      let body = Data("sortie-1-injection-smoke-test-payload".utf8)
      let digest = SHA256.hash(data: body)
      let expectedSHA = digest.map { String(format: "%02x", $0) }.joined()
      let expectedSize = Int64(body.count)

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(body.count)",
          ]
        )!
        return (response, body)
      }

      let mockSession = MockURLProtocol.session()

      let sourceURL = URL(
        string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/test_repo/sortie1.bin"
      )!
      let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("DownloadSessionInjectionTests-\(UUID().uuidString)")
      let destination = tempDir.appendingPathComponent("sortie1.bin")
      defer { try? FileManager.default.removeItem(at: tempDir) }

      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

      let manifestFile = CDNManifestFile(
        path: "sortie1.bin",
        sha256: expectedSHA,
        sizeBytes: expectedSize
      )

      // Call the lowest public (via @testable) entry point that ultimately
      // invokes `streamDownloadFile`, now that `session:` is threaded through.
      try await AcervoDownloader.downloadFile(
        from: sourceURL,
        to: destination,
        manifestFile: manifestFile,
        session: mockSession
      )

      // The mock should have seen at least one request, and the file on disk
      // should match the stubbed body byte-for-byte.
      #expect(MockURLProtocol.requestCount >= 1)
      #expect(FileManager.default.fileExists(atPath: destination.path))
      let written = try Data(contentsOf: destination)
      #expect(written == body)
    }
  }
}
