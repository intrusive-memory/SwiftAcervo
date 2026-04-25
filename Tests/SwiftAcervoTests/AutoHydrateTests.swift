import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Tests for Sortie 4 auto-hydrate plumbing. Nested under `MockURLProtocolSuite`
  /// so all tests inherit `.serialized` and cannot race on `MockURLProtocol`'s
  /// shared static storage.
  ///
  /// Scope note: `isComponentReadyAsync` and `ensureComponentReady` call `hydrateComponent`
  /// (the public form), which uses the production `SecureDownloadSession.shared`. To keep
  /// tests hermetic we pre-hydrate descriptors via the session-injectable internal overload
  /// `hydrateComponent(_:session:)`, then invoke the methods under test on already-hydrated
  /// descriptors (which skip the network call) or on bare descriptors where we verify the
  /// correct error is thrown.
  @Suite("Auto-Hydrate Tests")
  struct AutoHydrateTests {

    // MARK: - Helpers

    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "autohydrate-test/repo-\(uid)",
        componentId: "autohydrate-comp-\(uid)"
      )
    }

    private static func makeBareDescriptor(id: String, repoId: String) -> ComponentDescriptor {
      ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "AutoHydrate Test",
        repoId: repoId,
        minimumMemoryBytes: 0
      )
    }

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutoHydrateTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func removeTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    /// Builds a manifest with two files (sizeBytes: 0 so `isComponentReady` accepts empty files).
    private static func makeTwoFileManifest(modelId: String) -> CDNManifest {
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "0000000000000000000000000000000000000000000000000000000000000001",
          sizeBytes: 0
        ),
        CDNManifestFile(
          path: "model.safetensors",
          sha256: "0000000000000000000000000000000000000000000000000000000000000002",
          sizeBytes: 0
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

    private static func stubManifest(_ manifest: CDNManifest) throws {
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
    }

    /// Creates files on disk for the given descriptor so `isComponentReady` sees them.
    /// File content matches `expectedSizeBytes` exactly so size checks pass.
    private static func createFilesOnDisk(
      for descriptor: ComponentDescriptor,
      in baseDirectory: URL
    ) throws {
      let slug = Acervo.slugify(descriptor.repoId)
      let componentDir = baseDirectory.appendingPathComponent(slug)
      let fm = FileManager.default
      for file in descriptor.files {
        let fileURL = componentDir.appendingPathComponent(file.relativePath)
        try fm.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        // Write content sized to match expectedSizeBytes (including 0-byte files).
        // If no size declared, write arbitrary content.
        let content: Data
        if let size = file.expectedSizeBytes {
          content = size > 0 ? Data(repeating: 0x42, count: Int(size)) : Data()
        } else {
          content = Data("content".utf8)
        }
        try content.write(to: fileURL)
      }
    }

    // MARK: - Test 1: ensureComponentReady auto-hydrates a bare descriptor

    /// Verifies the auto-hydrate plumbing in `ensureComponentReady`:
    /// 1. Pre-hydrate using the session-injectable overload (stubbed manifest).
    /// 2. Create files on disk so the readiness check passes.
    /// 3. Call `ensureComponentReady` — it should detect the descriptor is already hydrated
    ///    and the files already exist, returning immediately without error.
    /// 4. Assert `isHydrated == true` and `isComponentReadyAsync` returns `true`.
    @Test("ensureComponentReady with pre-hydrated descriptor is a no-op when files exist")
    func ensureComponentReadyWithHydratedDescriptor() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      let bareDescriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bareDescriptor)
      defer { Acervo.unregister(componentId) }

      // Bare descriptor is not yet hydrated.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == false)

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      try Self.stubManifest(manifest)

      // Step 1: hydrate via the session-injectable internal overload.
      try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())

      // (a) Registry is now hydrated.
      let hydratedDescriptor = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydratedDescriptor.isHydrated == true)
      #expect(hydratedDescriptor.files.count == 2)

      // Step 2: create files on disk.
      try Self.createFilesOnDisk(for: hydratedDescriptor, in: tempDir)

      // Step 3: `ensureComponentReady` should find descriptor hydrated + files present → no-op.
      try await Acervo.ensureComponentReady(componentId, in: tempDir)

      // Still hydrated and files still exist.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == true)
      #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

      // (b) isComponentReadyAsync returns true (descriptor already hydrated, no new network call).
      let requestsBefore = MockURLProtocol.requestCount
      let ready = try await Acervo.isComponentReadyAsync(componentId, in: tempDir)
      #expect(ready == true)
      // No additional network call made (already hydrated).
      #expect(MockURLProtocol.requestCount == requestsBefore)
    }

    // MARK: - Test 2: isComponentReadyAsync returns false with no files on disk

    /// Hydrates the descriptor via the stub, but leaves no files on disk.
    /// `isComponentReadyAsync` should return false (descriptor is hydrated but files absent).
    @Test("isComponentReadyAsync returns false when descriptor is hydrated but files absent")
    func isComponentReadyAsyncFalseWithoutFiles() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      let bareDescriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bareDescriptor)
      defer { Acervo.unregister(componentId) }

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      try Self.stubManifest(manifest)

      // Pre-hydrate the descriptor (populates file list in registry).
      try await Acervo.hydrateComponent(componentId, session: MockURLProtocol.session())
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == true)

      // No files on disk → isComponentReadyAsync returns false (hydrated but not downloaded).
      let ready = try await Acervo.isComponentReadyAsync(componentId, in: tempDir)
      #expect(ready == false)
    }

    // MARK: - Test 3: isComponentReadyAsync throws for unregistered ID

    @Test("isComponentReadyAsync throws componentNotRegistered for unknown ID")
    func isComponentReadyAsyncThrowsForUnknownId() async throws {
      let unknownId = "never-registered-\(UUID().uuidString.prefix(8))"

      do {
        _ = try await Acervo.isComponentReadyAsync(unknownId)
        Issue.record("Expected componentNotRegistered to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .componentNotRegistered(let id):
          #expect(id == unknownId)
        default:
          Issue.record("Expected .componentNotRegistered, got \(error)")
        }
      }
    }

    // MARK: - Test 4: verifyComponent throws componentNotHydrated for bare descriptor

    @Test("verifyComponent throws componentNotHydrated for un-hydrated descriptor")
    func verifyComponentThrowsForUnhydrated() throws {
      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      let bareDescriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bareDescriptor)
      defer { Acervo.unregister(componentId) }

      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == false)

      do {
        _ = try Acervo.verifyComponent(componentId, in: tempDir)
        Issue.record("Expected componentNotHydrated to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .componentNotHydrated(let id):
          #expect(id == componentId)
        default:
          Issue.record("Expected .componentNotHydrated, got \(error)")
        }
      }
    }

    // MARK: - Test 5: isComponentReady (sync) returns false for un-hydrated descriptor

    @Test("isComponentReady (sync) returns false for un-hydrated descriptor")
    func isComponentReadySyncReturnsFalseForUnhydrated() {
      let (modelId, componentId) = Self.uniqueIds()
      let bareDescriptor = Self.makeBareDescriptor(id: componentId, repoId: modelId)
      Acervo.register(bareDescriptor)
      defer { Acervo.unregister(componentId) }

      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == false)
      #expect(Acervo.isComponentReady(componentId) == false)
    }

    // MARK: - Test 6: Pre-declared descriptor with files: needs no hydration

    /// Verifies backwards compatibility: descriptors with declared `files:` are already
    /// hydrated. `ensureComponentReady`, `isComponentReady`, and `isComponentReadyAsync`
    /// all behave correctly without any manifest network call.
    @Test("Pre-declared descriptor with files: needs no network call for any readiness check")
    func preDeclaredDescriptorBackwardsCompat() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let uid = UUID().uuidString.prefix(8)
      let componentId = "compat-\(uid)"
      let descriptor = ComponentDescriptor(
        id: componentId,
        type: .backbone,
        displayName: "Compat Test",
        repoId: "compat-org/repo-\(uid)",
        files: [
          ComponentFile(relativePath: "config.json"),
          ComponentFile(relativePath: "model.safetensors"),
        ],
        estimatedSizeBytes: 100,
        minimumMemoryBytes: 0
      )
      Acervo.register(descriptor)
      defer { Acervo.unregister(componentId) }

      // Already hydrated from declared files.
      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == true)

      // Create files on disk.
      try Self.createFilesOnDisk(for: descriptor, in: tempDir)

      // No manifest fetch should occur — requestCount stays at 0.
      #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
      try await Acervo.ensureComponentReady(componentId, in: tempDir)
      let ready = try await Acervo.isComponentReadyAsync(componentId, in: tempDir)
      #expect(ready == true)
      #expect(MockURLProtocol.requestCount == 0)
    }
  }
}
