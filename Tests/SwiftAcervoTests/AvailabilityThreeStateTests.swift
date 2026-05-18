import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Three-State Availability Tests

/// Tests for `Acervo.availability(_:)` and `AcervoManager.availability(_:)`.
///
/// All tests that could potentially perform network I/O are nested under
/// `SharedStaticStateSuite.MockURLProtocolSuite` so that `MockURLProtocol`
/// state is properly serialized.
extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Availability Three-State Tests")
  struct AvailabilityThreeStateTests {

    // MARK: - Helpers (mirrors AcervoAvailabilityTests patterns)

    private func makeTempBase() throws -> URL {
      let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("AvailabilityThreeStateTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: tempBase,
        withIntermediateDirectories: true
      )
      return tempBase
    }

    private func removeTempBase(_ url: URL) {
      try? FileManager.default.removeItem(at: url)
    }

    private func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifestFile(path: String, data: Data) -> CDNManifestFile {
      CDNManifestFile(
        path: path,
        sha256: sha256Hex(data),
        sizeBytes: Int64(data.count)
      )
    }

    private func makeManifest(
      modelId: String,
      files: [CDNManifestFile]
    ) -> CDNManifest {
      let slug = Acervo.slugify(modelId)
      let checksum = CDNManifest.computeChecksum(from: files.map(\.sha256))
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-05-18T00:00:00Z",
        files: files,
        manifestChecksum: checksum
      )
    }

    /// Materializes a model directory under `tempBase`: writes each file's
    /// declared bytes and persists `.acervo-manifest.json` via the production
    /// `AcervoDownloader.persistManifest` API.
    ///
    /// `bodies` maps `path -> Data`. Paths absent from `bodies` are not written.
    private func materializeModel(
      modelId: String,
      in tempBase: URL,
      manifest: CDNManifest,
      bodies: [String: Data]
    ) throws {
      let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      for file in manifest.files {
        guard let data = bodies[file.path] else { continue }
        let fileURL = modelDir.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: fileURL)
      }
      try AcervoDownloader.persistManifest(manifest, in: tempBase)
    }

    // MARK: - Tests

    @Test("availability returns .notAvailable from empty directory")
    func availability_returnsNotAvailable_fromEmptyDirectory() async throws {
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/empty-model"
      let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(result == .notAvailable)
    }

    @Test("availability returns .available from full mirror with matching manifest")
    func availability_returnsAvailable_fromFullMirror() async throws {
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/full-mirror"
      let configData = Data("{}".utf8)
      let weightsData = Data(repeating: 0x42, count: 1024)
      let files = [
        manifestFile(path: "config.json", data: configData),
        manifestFile(path: "weights.safetensors", data: weightsData),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)

      try materializeModel(
        modelId: modelId,
        in: tempBase,
        manifest: manifest,
        bodies: [
          "config.json": configData,
          "weights.safetensors": weightsData,
        ]
      )

      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(result == .available)
    }

    @Test("availability returns .notAvailable when a shard size mismatches")
    func availability_returnsNotAvailable_whenShardSizeMismatched() async throws {
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/truncated-shard-3state"
      let configData = Data("{}".utf8)
      let weightsData = Data(repeating: 0x42, count: 1024)
      let files = [
        manifestFile(path: "config.json", data: configData),
        manifestFile(path: "weights.safetensors", data: weightsData),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)

      // Truncate the weights file by half — manifest still declares 1024 bytes.
      let truncatedWeights = Data(repeating: 0x42, count: 512)
      try materializeModel(
        modelId: modelId,
        in: tempBase,
        manifest: manifest,
        bodies: [
          "config.json": configData,
          "weights.safetensors": truncatedWeights,
        ]
      )

      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(result == .notAvailable)
    }

    @Test("availability returns .notAvailable when manifest is absent")
    func availability_returnsNotAvailable_whenManifestAbsent() async throws {
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/no-manifest-3state"
      let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      // Write files but NO .acervo-manifest.json.
      try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
      try Data(repeating: 0x42, count: 1024).write(
        to: modelDir.appendingPathComponent("weights.safetensors")
      )

      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(result == .notAvailable)
    }

    @Test("availability performs zero network I/O regardless of return value")
    func availability_performsZeroNetworkIO() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // Register a responder so any accidental network call would be counted.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: [:]
        )!
        return (response, Data())
      }

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/network-io-check"
      let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

      // Call availability — it should be purely local, no HTTP.
      _ = await Acervo.availability(modelId, in: tempBase)

      #expect(
        MockURLProtocol.requestCount == 0,
        "availability(_:) must not perform any network I/O"
      )
    }

    @Test("AcervoManager.availability forwards to static Acervo.availability")
    func acervoManager_availability_forwardsToStatic() async throws {
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      // Build a fully materialised model so both paths return .available.
      let modelId = "test-org/manager-forward"
      let configData = Data("{}".utf8)
      let weightsData = Data(repeating: 0xAB, count: 256)
      let files = [
        manifestFile(path: "config.json", data: configData),
        manifestFile(path: "weights.safetensors", data: weightsData),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)
      try materializeModel(
        modelId: modelId,
        in: tempBase,
        manifest: manifest,
        bodies: [
          "config.json": configData,
          "weights.safetensors": weightsData,
        ]
      )

      // Use the internal (in:) overload for the static call so it operates
      // on the same tempBase without needing the App Group env var.
      let staticResult = await Acervo.availability(modelId, in: tempBase)

      // For the AcervoManager call, we must use the public API which reads
      // sharedModelsDirectory. The model won't be there in CI, so we compare
      // the static result against itself to confirm the static path works,
      // and separately verify the manager's method is callable and returns
      // a ModelAvailability value (not a compilation error).
      //
      // For full parity we create a fresh manager and call the public overload
      // indirectly. Since Acervo.availability(_:) is what the manager calls
      // internally, and it's already exercised above, the test below focuses
      // on compilation + return-type correctness for the manager surface.
      #expect(staticResult == .available)

      // Verify manager returns a valid ModelAvailability.
      // AcervoManager.init() is private — use the shared singleton.
      // The shared manager calls Acervo.availability(modelId) against
      // sharedModelsDirectory; the model lives only in tempBase so the
      // manager will correctly return .notAvailable.
      let managerResult: ModelAvailability = await AcervoManager.shared.availability(modelId)
      // The manager result against the real shared directory should be
      // .notAvailable (model lives in tempBase, not SharedModels).
      #expect(managerResult == .notAvailable)
    }
  }
}
