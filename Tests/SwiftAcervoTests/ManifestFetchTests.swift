import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {

  /// Tests for the public `Acervo.fetchManifest` API and the `session:`-injectable
  /// `AcervoDownloader.downloadManifest`. Nested under `MockURLProtocolSuite` so
  /// it inherits the parent's `.serialized` trait and cannot race with any other
  /// `MockURLProtocol`-using test.
  @Suite("Manifest Fetch Tests")
  struct ManifestFetchTests {

    @Test("downloadManifest(session:) parses a stubbed manifest cleanly")
    func downloadManifestWithMockSession() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = "test/fixture"
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "0000000000000000000000000000000000000000000000000000000000000001",
          sizeBytes: 16
        ),
        CDNManifestFile(
          path: "weights.bin",
          sha256: "0000000000000000000000000000000000000000000000000000000000000002",
          sizeBytes: 1024
        ),
      ]
      let checksum = CDNManifest.computeChecksum(from: files.map(\.sha256))
      let manifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: "test_fixture",
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: checksum
      )
      let encoded = try JSONEncoder().encode(manifest)

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      let session = MockURLProtocol.session()
      let fetched = try await AcervoDownloader.downloadManifest(
        for: modelId,
        session: session
      )

      #expect(fetched.modelId == modelId)
      #expect(fetched.files.count == 2)
      #expect(fetched.files.map(\.path) == ["config.json", "weights.bin"])
      #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("Acervo.fetchManifest exists as a public callable symbol")
    func fetchManifestIsCallable() {
      // Compile-time check: the symbol exists with the expected signature.
      // We do not invoke it here because it always dispatches to the real CDN.
      let symbol: (String) async throws -> CDNManifest = Acervo.fetchManifest(for:)
      _ = symbol
    }
  }
}
