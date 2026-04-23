import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {

  /// Tests for `Acervo.hydrateComponent`. Nested under `MockURLProtocolSuite`
  /// so it inherits the parent's `.serialized` trait and cannot race with
  /// other tests that mutate `MockURLProtocol`'s shared static storage.
  @Suite("Hydrate Component Tests")
  struct HydrateComponentTests {

    // MARK: - Helpers

    /// Returns (modelId, componentId) — both scoped by the same UUID suffix
    /// so parallel test sharding doesn't collide on registry IDs.
    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "hydrate-test/repo-\(uid)",
        componentId: "hydrate-test-comp-\(uid)"
      )
    }

    private static func makeBareDescriptor(id: String, repoId: String) -> ComponentDescriptor {
      ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Hydrate Test",
        repoId: repoId,
        minimumMemoryBytes: 0
      )
    }

    /// Builds a valid manifest with three files for the given modelId.
    private static func makeThreeFileManifest(modelId: String) -> CDNManifest {
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "0000000000000000000000000000000000000000000000000000000000000001",
          sizeBytes: 16
        ),
        CDNManifestFile(
          path: "tokenizer.json",
          sha256: "0000000000000000000000000000000000000000000000000000000000000002",
          sizeBytes: 1024
        ),
        CDNManifestFile(
          path: "model.safetensors",
          sha256: "0000000000000000000000000000000000000000000000000000000000000003",
          sizeBytes: 4096
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

    // MARK: - Test A: Basic hydration round trip

    // OPERATION TRIPWIRE GAUNTLET Sortie 2 — proof-of-use for
    // `withIsolatedComponentRegistry` in Tests/SwiftAcervoTests/Support/ComponentRegistryIsolation.swift.
    // The explicit `defer { Acervo.unregister(componentId) }` pattern used by
    // the other tests in this suite is here replaced by the snapshot/restore
    // helper, which survives early throws and leaves the registry in exactly
    // the state it found it in. Using `Self.uniqueIds()` satisfies the
    // "HydrateComponentTests.uniqueIds" migration requirement.
    @Test("hydrateComponent populates the registry from a stubbed manifest")
    func hydrateComponentPopulatesRegistry() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedComponentRegistry {
        let (modelId, componentId) = Self.uniqueIds()
        let descriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
        Acervo.register(descriptor)

        // Sanity: bare descriptor reports needing hydration.
        #expect(Acervo.component(componentId)?.isHydrated == false)

        let manifest = Self.makeThreeFileManifest(modelId: modelId)
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

        try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())

        let hydrated = try #require(ComponentRegistry.shared.component(componentId))
        #expect(hydrated.isHydrated == true)
        #expect(hydrated.files.count == 3)
        #expect(
          hydrated.files.map(\.relativePath) == [
            "config.json",
            "tokenizer.json",
            "model.safetensors",
          ])
        #expect(hydrated.estimatedSizeBytes == 16 + 1024 + 4096)
        #expect(MockURLProtocol.requestCount == 1)
      }
    }

    // MARK: - Test B: Concurrent single-flight

    @Test("Concurrent hydrateComponent calls coalesce into one network fetch")
    func concurrentHydrationCoalesces() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let (modelId, componentId) = Self.uniqueIds()
      let descriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(descriptor)
      defer { Acervo.unregister(componentId) }

      let manifest = Self.makeThreeFileManifest(modelId: modelId)
      let encoded = try JSONEncoder().encode(manifest)

      // Responder with an artificial delay so both dispatched tasks overlap
      // before either completes. We sleep on a detached Task (responder must
      // be @Sendable & sync), but the URLProtocol machinery handles the async
      // bridging — here we simulate by emitting immediately but dispatching
      // all 10 tasks before even the first one resumes past `await`.
      MockURLProtocol.responder = { request in
        // Block the responder thread briefly; this keeps the "fetch" open long
        // enough for the coalescer to see all concurrent callers awaiting it.
        Thread.sleep(forTimeInterval: 0.1)
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      let session = MockURLProtocol.session()

      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 {
          group.addTask {
            try await Acervo.hydrateComponent(componentId, session: session)
          }
        }
        try await group.waitForAll()
      }

      #expect(MockURLProtocol.requestCount == 1)
      let hydrated = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydrated.isHydrated == true)
      #expect(hydrated.files.count == 3)
    }

    // MARK: - Test C: Non-registered ID throws

    @Test("hydrateComponent throws componentNotRegistered for an unknown ID")
    func hydrateUnknownComponentThrows() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // Stub a responder so if we *do* reach the network, we'd fail loudly
      // with an unexpected request count — but the lookup should fail first.
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

      await #expect(throws: AcervoError.self) {
        try await Acervo.hydrateComponent(unknownId, session: MockURLProtocol.session())
      }

      // Verify the specific case.
      do {
        try await Acervo.hydrateComponent(unknownId, session: MockURLProtocol.session())
        Issue.record("expected componentNotRegistered to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .componentNotRegistered(let id):
          #expect(id == unknownId)
        default:
          Issue.record("expected .componentNotRegistered, got \(error)")
        }
      }

      // No network call was made for the registry miss.
      #expect(MockURLProtocol.requestCount == 0)
    }
  }
}
