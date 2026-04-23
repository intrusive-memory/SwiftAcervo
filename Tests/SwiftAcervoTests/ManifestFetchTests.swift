import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {

  /// Tests for the public `Acervo.fetchManifest` API (both the modelId and
  /// `forComponent:` forms) and the underlying `session:`-injectable
  /// `AcervoDownloader.downloadManifest`. Nested under `MockURLProtocolSuite`
  /// so it inherits the parent's `.serialized` trait and cannot race with any
  /// other `MockURLProtocol`-using test.
  @Suite("Manifest Fetch Tests")
  struct ManifestFetchTests {

    // MARK: - Helpers

    /// Returns (modelId, componentId) — both scoped by the same UUID suffix
    /// so parallel test sharding doesn't collide on registry IDs.
    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "fetch-manifest-test/repo-\(uid)",
        componentId: "fetch-manifest-test-comp-\(uid)"
      )
    }

    private static func makeBareDescriptor(id: String, repoId: String) -> ComponentDescriptor {
      ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Fetch Manifest Test",
        repoId: repoId,
        minimumMemoryBytes: 0
      )
    }

    /// Builds a valid 2-file manifest for the given `modelId`.
    private static func makeManifest(modelId: String) -> CDNManifest {
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

    private static func makeResponder(
      returning manifest: CDNManifest
    ) throws -> @Sendable (URLRequest) -> (HTTPURLResponse, Data) {
      let encoded = try JSONEncoder().encode(manifest)
      return { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }
    }

    // MARK: - Underlying downloader

    @Test("downloadManifest(session:) parses a stubbed manifest cleanly")
    func downloadManifestWithMockSession() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, _) = Self.uniqueIds()
      let manifest = Self.makeManifest(modelId: modelId)
      MockURLProtocol.responder = try Self.makeResponder(returning: manifest)

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

    // MARK: - fetchManifest(for:) — modelId form

    @Test("fetchManifest(for:) returns a stubbed manifest for the given modelId")
    func fetchManifestForModelIdReturnsManifest() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, _) = Self.uniqueIds()
      let manifest = Self.makeManifest(modelId: modelId)
      MockURLProtocol.responder = try Self.makeResponder(returning: manifest)

      let fetched = try await Acervo.fetchManifest(
        for: modelId,
        session: MockURLProtocol.session()
      )

      #expect(fetched.modelId == modelId)
      #expect(fetched.files.count == 2)
      #expect(fetched.files.map(\.path) == ["config.json", "weights.bin"])
      #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("fetchManifest(for:) throws manifestModelIdMismatch when the CDN returns the wrong model")
    func fetchManifestForModelIdMismatchThrows() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (requestedModelId, _) = Self.uniqueIds()
      let wrongModelId = "other/repo-\(UUID().uuidString.prefix(8))"

      // The server (bug or misconfig) returns a manifest whose modelId
      // does not match the requested modelId.
      let badManifest = Self.makeManifest(modelId: wrongModelId)
      MockURLProtocol.responder = try Self.makeResponder(returning: badManifest)

      do {
        _ = try await Acervo.fetchManifest(
          for: requestedModelId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected manifestModelIdMismatch to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestModelIdMismatch(let expected, let actual):
          #expect(expected == requestedModelId)
          #expect(actual == wrongModelId)
        default:
          Issue.record("expected .manifestModelIdMismatch, got \(error)")
        }
      }
    }

    // MARK: - fetchManifest(forComponent:) — registry form

    @Test("fetchManifest(forComponent:) looks up repoId via the registry and returns the manifest")
    func fetchManifestForComponentReturnsManifest() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let descriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(descriptor)
      defer { Acervo.unregister(componentId) }

      // Responder returns a manifest whose modelId matches the component's repoId.
      let manifest = Self.makeManifest(modelId: modelId)
      MockURLProtocol.responder = try Self.makeResponder(returning: manifest)

      let fetched = try await Acervo.fetchManifest(
        forComponent: componentId,
        session: MockURLProtocol.session()
      )

      #expect(fetched.modelId == modelId)
      #expect(fetched.files.count == 2)
      #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("fetchManifest(forComponent:) throws componentNotRegistered for an unknown id without hitting the network")
    func fetchManifestForComponentUnknownThrows() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // Stub a responder so if we *do* reach the network, we'd fail loudly
      // with an unexpected request count — but the registry lookup should fail first.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
        return (response, Data())
      }

      let unknownId = "never-registered-\(UUID().uuidString.prefix(8))"

      do {
        _ = try await Acervo.fetchManifest(
          forComponent: unknownId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected componentNotRegistered to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .componentNotRegistered(let id):
          #expect(id == unknownId)
        default:
          Issue.record("expected .componentNotRegistered, got \(error)")
        }
      }

      // Critically: no HTTP request was made for the registry miss.
      #expect(MockURLProtocol.requestCount == 0)
    }
  }
}
