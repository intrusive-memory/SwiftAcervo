import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Local-first resolution: when a complete local copy (or a persisted
  /// manifest) exists, no code path may touch the CDN. These tests simulate a
  /// dead CDN — expired domain, DNS failure — by leaving
  /// `MockURLProtocol.responder` nil, which fails every request with
  /// `URLError(.resourceUnavailable)`. Nested under `MockURLProtocolSuite`
  /// so they inherit `.serialized` and cannot race on the shared static
  /// responder or the process-wide `ManifestCache.shared`.
  @Suite("Local-First Resolution Tests")
  struct LocalFirstResolutionTests {

    // MARK: - Helpers

    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "localfirst-test/repo-\(uid)",
        componentId: "localfirst-comp-\(uid)"
      )
    }

    private static func makeBareDescriptor(id: String, repoId: String) -> ComponentDescriptor {
      ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "LocalFirst Test",
        repoId: repoId,
        minimumMemoryBytes: 0
      )
    }

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalFirstResolutionTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func removeTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    /// Builds a manifest with two zero-byte files so presence-by-size checks
    /// pass against empty files on disk.
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
        updatedAt: "2026-08-12T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    /// Writes the manifest to `<base>/<slug>/manifest.json` — the file a
    /// completed download persists — and creates every declared file on disk
    /// at its recorded size.
    private static func writeLocalModel(
      _ manifest: CDNManifest,
      modelId: String,
      in baseDirectory: URL
    ) throws {
      let modelDir = baseDirectory.appendingPathComponent(Acervo.slugify(modelId))
      let fm = FileManager.default
      try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
      try JSONEncoder().encode(manifest).write(
        to: modelDir.appendingPathComponent(AcervoDownloader.manifestFilename))
      for file in manifest.files {
        let fileURL = modelDir.appendingPathComponent(file.path)
        try fm.createDirectory(
          at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: Int(file.sizeBytes)).write(to: fileURL)
      }
    }

    // MARK: - Hydration

    @Test("hydrateComponent resolves from the local manifest with zero network calls")
    func hydrationIsLocalFirst() async throws {
      MockURLProtocol.reset()  // nil responder == every request fails (dead CDN)
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      Acervo.register(Self.makeBareDescriptor(id: componentId, repoId: modelId))
      defer { Acervo.unregister(componentId) }

      try Self.writeLocalModel(Self.makeTwoFileManifest(modelId: modelId), modelId: modelId, in: tempDir)

      try await Acervo.hydrateComponent(
        componentId, session: MockURLProtocol.session(), in: tempDir)

      let hydrated = try #require(ComponentRegistry.shared.component(componentId))
      #expect(hydrated.isHydrated == true)
      #expect(hydrated.files.count == 2)
      #expect(MockURLProtocol.requestCount == 0)
    }

    @Test("ensureComponentReady succeeds end-to-end with a dead CDN when the model is local")
    func ensureComponentReadyWorksOffCDN() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      Acervo.register(Self.makeBareDescriptor(id: componentId, repoId: modelId))
      defer { Acervo.unregister(componentId) }

      try Self.writeLocalModel(Self.makeTwoFileManifest(modelId: modelId), modelId: modelId, in: tempDir)

      // Bare descriptor + complete local copy + unreachable CDN → must succeed.
      try await Acervo.ensureComponentReady(
        componentId, in: tempDir, session: MockURLProtocol.session())

      #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
      #expect(MockURLProtocol.requestCount == 0)
    }

    @Test("hydrateComponent still falls back to the CDN when no local manifest exists")
    func hydrationFallsBackToCDN() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, componentId) = Self.uniqueIds()
      Acervo.register(Self.makeBareDescriptor(id: componentId, repoId: modelId))
      defer { Acervo.unregister(componentId) }

      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      let encoded = try JSONEncoder().encode(manifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"])!
        return (response, encoded)
      }

      try await Acervo.hydrateComponent(
        componentId, session: MockURLProtocol.session(), in: tempDir)

      #expect(ComponentRegistry.shared.component(componentId)?.isHydrated == true)
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - Slug manifest disk persistence

    @Test("persisted slug manifest round-trips through disk and survives corruption checks")
    func slugManifestDiskRoundTrip() throws {
      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, _) = Self.uniqueIds()
      let manifest = Self.makeTwoFileManifest(modelId: modelId)
      let url = URL(string: "https://cdn.test/\(Acervo.slugify(modelId))/manifest.json")!

      #expect(ManifestCache.loadFromDisk(slug: modelId, url: url, in: tempDir) == nil)

      ManifestCache.persistToDisk(
        try JSONEncoder().encode(manifest), slug: modelId, url: url, in: tempDir)
      let loaded = try #require(ManifestCache.loadFromDisk(slug: modelId, url: url, in: tempDir))
      #expect(loaded.modelId == modelId)
      #expect(loaded.files.count == 2)

      // A different URL is a different key.
      let otherURL = URL(string: "https://other.test/manifest.json")!
      #expect(ManifestCache.loadFromDisk(slug: modelId, url: otherURL, in: tempDir) == nil)

      // Corrupt bytes → nil, and the corrupt file is deleted.
      let fileURL = ManifestCache.diskCacheURL(slug: modelId, url: url, in: tempDir)
      try Data("not json".utf8).write(to: fileURL)
      #expect(ManifestCache.loadFromDisk(slug: modelId, url: url, in: tempDir) == nil)
      #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)

      ManifestCache.persistToDisk(
        try JSONEncoder().encode(manifest), slug: modelId, url: url, in: tempDir)
      ManifestCache.removeFromDisk(slug: modelId, url: url, in: tempDir)
      #expect(ManifestCache.loadFromDisk(slug: modelId, url: url, in: tempDir) == nil)
    }

    @Test("ensureAvailable(slug:) succeeds with a dead CDN from the persisted manifest")
    func slugEnsureAvailableWorksOffCDN() async throws {
      MockURLProtocol.reset()  // dead CDN
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, _) = Self.uniqueIds()
      let slug = "localfirst-slug-\(UUID().uuidString.prefix(8))"
      let manifestURL = URL(string: "https://cdn.test/\(slug)/manifest.json")!

      // The component's model is fully on disk from a prior download…
      let componentManifest = Self.makeTwoFileManifest(modelId: modelId)
      try Self.writeLocalModel(componentManifest, modelId: modelId, in: tempDir)

      // …and the slug manifest was persisted on a prior (online) launch.
      let slugManifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: slug,
        slug: slug,
        updatedAt: "2026-08-12T00:00:00Z",
        files: [],
        manifestChecksum: CDNManifest.computeChecksum(from: []),
        primaryRepo: modelId,
        components: [modelId]
      )
      ManifestCache.persistToDisk(
        try JSONEncoder().encode(slugManifest), slug: slug, url: manifestURL, in: tempDir)
      // Drop the in-memory entry so the disk copy is what satisfies the call.
      await ManifestCache.shared.remove(slug: slug, url: manifestURL)

      try await Acervo.ensureAvailable(
        slug: slug,
        url: manifestURL,
        files: [],
        in: tempDir,
        session: MockURLProtocol.session()
      )

      #expect(MockURLProtocol.requestCount == 0)
    }

    @Test("deleteModel(slug:) works with a dead CDN and clears the persisted manifest")
    func deleteModelWorksOffCDN() async throws {
      MockURLProtocol.reset()  // dead CDN
      defer { MockURLProtocol.reset() }

      let tempDir = try Self.makeTempDir()
      defer { Self.removeTempDir(tempDir) }

      let (modelId, _) = Self.uniqueIds()
      let slug = "localfirst-del-\(UUID().uuidString.prefix(8))"
      let manifestURL = URL(string: "https://cdn.test/\(slug)/manifest.json")!

      let componentManifest = Self.makeTwoFileManifest(modelId: modelId)
      try Self.writeLocalModel(componentManifest, modelId: modelId, in: tempDir)

      let slugManifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: slug,
        slug: slug,
        updatedAt: "2026-08-12T00:00:00Z",
        files: [],
        manifestChecksum: CDNManifest.computeChecksum(from: []),
        primaryRepo: modelId,
        components: [modelId]
      )
      ManifestCache.persistToDisk(
        try JSONEncoder().encode(slugManifest), slug: slug, url: manifestURL, in: tempDir)
      await ManifestCache.shared.remove(slug: slug, url: manifestURL)

      try await Acervo.deleteModel(
        slug: slug, url: manifestURL, in: tempDir, session: MockURLProtocol.session())

      let modelDir = tempDir.appendingPathComponent(Acervo.slugify(modelId))
      #expect(FileManager.default.fileExists(atPath: modelDir.path) == false)
      #expect(ManifestCache.loadFromDisk(slug: slug, url: manifestURL, in: tempDir) == nil)
      #expect(MockURLProtocol.requestCount == 0)
    }
  }
}
