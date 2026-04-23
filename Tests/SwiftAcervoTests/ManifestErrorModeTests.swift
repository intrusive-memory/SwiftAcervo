import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {

  /// Manifest error-mode tests: decoding failures, integrity mismatches, and
  /// unsupported versions. Each test exercises a different failure path in
  /// `Acervo.fetchManifest(for:session:)` and `AcervoDownloader.downloadManifest`.
  ///
  /// Nested under `MockURLProtocolSuite` so it inherits the parent's `.serialized`
  /// trait and cannot race with any other `MockURLProtocol`-using test.
  @Suite("Manifest Error Mode Tests")
  struct ManifestErrorModeTests {

    // MARK: - Helpers

    private static func uniqueModelId() -> String {
      let uid = UUID().uuidString.prefix(8)
      return "manifest-error-test/repo-\(uid)"
    }

    /// Builds a valid 2-file manifest for the given `modelId`.
    private static func makeValidManifest(modelId: String) -> CDNManifest {
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
      let slug = modelId.replacingOccurrences(of: "/", with: "_")
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    // MARK: - Test 1: Malformed JSON

    @Test("Malformed JSON body throws manifestDecodingFailed")
    func malformedJsonThrowsDecodingFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()

      // Stub a responder that returns invalid JSON.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data("not json".utf8))
      }

      do {
        _ = try await Acervo.fetchManifest(
          for: modelId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected manifestDecodingFailed to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestDecodingFailed:
          // Success: the error is the expected case.
          #expect(true)
        default:
          Issue.record("expected .manifestDecodingFailed, got \(error)")
        }
      }
    }

    // MARK: - Test 2: Integrity mismatch (bad checksum-of-checksums)

    @Test("Bad checksum-of-checksums throws manifestIntegrityFailed with both fields populated")
    func badChecksumThrowsIntegrityFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()

      // Create a manifest with valid structure but a wrong manifestChecksum.
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
      let slug = modelId.replacingOccurrences(of: "/", with: "_")

      // Compute the correct checksum, then intentionally use a wrong one.
      let correctChecksum = CDNManifest.computeChecksum(from: files.map(\.sha256))
      let wrongChecksum = String(repeating: "f", count: 64)  // All F's, definitely wrong.

      let badManifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: wrongChecksum
      )

      // Encode the manifest and stub it.
      let encoded = try JSONEncoder().encode(badManifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      do {
        _ = try await Acervo.fetchManifest(
          for: modelId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected manifestIntegrityFailed to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestIntegrityFailed(let expected, let actual):
          // Both fields must be populated with non-empty hex strings.
          #expect(!expected.isEmpty, "expected field must be non-empty")
          #expect(!actual.isEmpty, "actual field must be non-empty")
          // The expected is the manifest's declared checksum (wrong), actual is the computed (correct).
          #expect(expected == wrongChecksum)
          #expect(actual == correctChecksum)
        default:
          Issue.record("expected .manifestIntegrityFailed, got \(error)")
        }
      }
    }

    // MARK: - Test 3: Unsupported version (too new)

    @Test("manifestVersion = supportedVersion + 1 throws manifestVersionUnsupported")
    func tooNewVersionThrowsUnsupported() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()

      // Create a manifest with a future (unsupported) version.
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "0000000000000000000000000000000000000000000000000000000000000001",
          sizeBytes: 16
        ),
      ]
      let slug = modelId.replacingOccurrences(of: "/", with: "_")

      let futureVersionManifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion + 1,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )

      let encoded = try JSONEncoder().encode(futureVersionManifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      do {
        _ = try await Acervo.fetchManifest(
          for: modelId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected manifestVersionUnsupported to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestVersionUnsupported(let version):
          #expect(version == CDNManifest.supportedVersion + 1)
        default:
          Issue.record("expected .manifestVersionUnsupported, got \(error)")
        }
      }
    }

    // MARK: - Test 4: Boundary test — manifestVersion = 0

    @Test("manifestVersion = 0 throws manifestVersionUnsupported (boundary test)")
    func zeroVersionThrowsUnsupported() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()

      // Create a manifest with version 0 (pre-v1, invalid).
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "0000000000000000000000000000000000000000000000000000000000000001",
          sizeBytes: 16
        ),
      ]
      let slug = modelId.replacingOccurrences(of: "/", with: "_")

      let zeroVersionManifest = CDNManifest(
        manifestVersion: 0,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )

      let encoded = try JSONEncoder().encode(zeroVersionManifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      do {
        _ = try await Acervo.fetchManifest(
          for: modelId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected manifestVersionUnsupported to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestVersionUnsupported(let version):
          #expect(version == 0)
        default:
          Issue.record("expected .manifestVersionUnsupported, got \(error)")
        }
      }
    }
  }
}
