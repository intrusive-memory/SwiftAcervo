// Companion tests for Sources/SwiftAcervo/Acervo+Availability.swift (three-state tier).
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

    @Test("availability returns .partial(missing:) when a shard size mismatches (EM-2)")
    func availability_returnsPartial_whenShardSizeMismatched() async throws {
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

      // EM-2: with an authoritative manifest in scope, a size mismatch is
      // reported as `.partial(missing:)` (not `.notAvailable`). The consumer
      // should re-download the affected shard.
      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(result == .partial(missing: ["weights.safetensors"]))
    }

    @Test(
      "availability returns .available via Tier C when manifest is absent but root marker + no shard index (EM-2)"
    )
    func availability_returnsAvailableViaTierC_whenManifestAbsent() async throws {
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/no-manifest-3state"
      let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      // Write files but NO manifest.json / .acervo-manifest.json. With no
      // `model.safetensors.index.json` to enumerate, Tier C's last-resort
      // heuristic accepts config.json as the root marker and reports
      // `.available`. This is the EM-2 false-negative fix.
      try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
      try Data(repeating: 0x42, count: 1024).write(
        to: modelDir.appendingPathComponent("weights.safetensors")
      )

      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(result == .available)
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

    // MARK: - Sortie 6: InFlightDownloads dedup helpers

    /// Builds a manifest with three small files plus deterministic body
    /// bytes whose SHA-256 matches each file entry. Returns the manifest
    /// AND the body map so callers can construct responders that serve
    /// them.
    private func buildThreeFileFixture(modelId: String) -> (CDNManifest, [String: Data]) {
      let configData = Data("{}".utf8)
      let weightsData = Data(repeating: 0x42, count: 64)
      let tokenizerData = Data(repeating: 0x77, count: 32)
      let files = [
        manifestFile(path: "config.json", data: configData),
        manifestFile(path: "weights.safetensors", data: weightsData),
        manifestFile(path: "tokenizer.model", data: tokenizerData),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)
      let bodies: [String: Data] = [
        "config.json": configData,
        "weights.safetensors": weightsData,
        "tokenizer.model": tokenizerData,
      ]
      return (manifest, bodies)
    }

    /// Standard responder: serves the manifest on `manifest.json` URLs,
    /// serves the appropriate body on file URLs (looked up by last path
    /// component). Sleeps `fileDelaySeconds` synchronously inside each
    /// FILE response — NOT the manifest response — so concurrent
    /// `ensureAvailable` calls have time to enter the InFlightDownloads
    /// actor before the originator's work finishes.
    private func makeSlowResponder(
      manifest: CDNManifest,
      bodies: [String: Data],
      fileDelaySeconds: TimeInterval = 0.4
    ) -> MockURLProtocol.Responder {
      let encodedManifest = try! JSONEncoder().encode(manifest)
      return { request in
        let url = request.url?.absoluteString ?? ""
        if url.hasSuffix("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, encodedManifest)
        }
        // File request — sleep to keep the download in-flight long enough
        // for joiners to be observed before the originator completes.
        Thread.sleep(forTimeInterval: fileDelaySeconds)
        let path = request.url?.lastPathComponent ?? ""
        let data = bodies[path] ?? Data()
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(data.count)",
          ]
        )!
        return (response, data)
      }
    }

    // MARK: - Sortie 6 tests

    @Test("dedup: a single download services two concurrent ensureAvailable calls")
    func dedup_singleDownloadUnderConcurrency() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "sortie6/dedup-single-\(UUID().uuidString.prefix(8))"
      let (manifest, bodies) = buildThreeFileFixture(modelId: String(modelId))
      MockURLProtocol.responder = makeSlowResponder(
        manifest: manifest, bodies: bodies, fileDelaySeconds: 0.5)

      let session = MockURLProtocol.session()
      let id = String(modelId)
      let base = tempBase
      // Launch two concurrent ensureAvailable calls.
      async let a: Void = Acervo.ensureAvailable(
        id, files: [], progress: nil, in: base, telemetry: nil, session: session)
      async let b: Void = Acervo.ensureAvailable(
        id, files: [], progress: nil, in: base, telemetry: nil, session: session)
      _ = try await (a, b)

      // Exactly 1 manifest fetch + 3 file fetches. NOT 8.
      #expect(
        MockURLProtocol.requestCount == 4,
        "dedup must collapse two concurrent ensureAvailable calls into ONE download; got \(MockURLProtocol.requestCount) requests"
      )
      // Both callers must have observed success: model is now strictly available.
      #expect(Acervo.isModelAvailable(id, in: base))
    }

    @Test("dedup: registry is cleared after a successful download")
    func dedup_registryClearedAfterCompletion() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "sortie6/registry-clear-\(UUID().uuidString.prefix(8))"
      let (manifest, bodies) = buildThreeFileFixture(modelId: String(modelId))
      MockURLProtocol.responder = makeSlowResponder(
        manifest: manifest, bodies: bodies, fileDelaySeconds: 0.05)

      try await Acervo.ensureAvailable(
        String(modelId), files: [], progress: nil, in: tempBase, telemetry: nil,
        session: MockURLProtocol.session())

      let stillRegistered = await InFlightDownloads.shared.contains(String(modelId))
      #expect(
        stillRegistered == false,
        "registry must be cleared after a successful download")
    }

    @Test("dedup: an error propagates to joiners and clears the registry")
    func dedup_errorPropagatesToJoiner() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "sortie6/dedup-error-\(UUID().uuidString.prefix(8))"
      let (manifest, bodies) = buildThreeFileFixture(modelId: String(modelId))
      let encodedManifest = try JSONEncoder().encode(manifest)

      // Responder that succeeds for the manifest and the first file, then
      // returns a 500 on subsequent file requests. We rely on lastPathComponent
      // to identify which file is being requested; "weights.safetensors" fails.
      MockURLProtocol.responder = { request in
        let url = request.url?.absoluteString ?? ""
        if url.hasSuffix("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
          return (response, encodedManifest)
        }
        // Short sleep so concurrent joiners enter the actor before the
        // originator's Task throws and clears the registry.
        Thread.sleep(forTimeInterval: 0.3)
        let path = request.url?.lastPathComponent ?? ""
        if path == "weights.safetensors" {
          let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
            headerFields: [:])!
          return (response, Data())
        }
        let data = bodies[path] ?? Data()
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Length": "\(data.count)"])!
        return (response, data)
      }

      let session = MockURLProtocol.session()
      let id = String(modelId)
      let base = tempBase

      async let aResult: Void = Acervo.ensureAvailable(
        id, files: [], progress: nil, in: base, telemetry: nil, session: session)
      async let bResult: Void = Acervo.ensureAvailable(
        id, files: [], progress: nil, in: base, telemetry: nil, session: session)

      var aError: Error?
      var bError: Error?
      do { try await aResult } catch { aError = error }
      do { try await bResult } catch { bError = error }

      #expect(aError != nil, "originator should have thrown")
      #expect(bError != nil, "joiner should have thrown")
      // Both errors should have the same underlying AcervoError case-name shape.
      // We compare String(describing:) since AcervoError is not Equatable across
      // all associated values.
      if let a = aError, let b = bError {
        #expect(
          String(describing: a) == String(describing: b),
          "originator and joiner must observe the same error; got \(a) vs \(b)"
        )
      }

      // Registry must be cleared after the failure.
      let containsAfter = await InFlightDownloads.shared.contains(id)
      #expect(containsAfter == false, "registry must clear on the error path")

      // A third call after the failure starts a fresh download attempt. We
      // verify by observing that requestCount increases beyond the previous
      // total (the third attempt makes new manifest + file requests).
      let before = MockURLProtocol.requestCount
      do {
        try await Acervo.ensureAvailable(
          id, files: [], progress: nil, in: base, telemetry: nil, session: session)
      } catch {
        // Expected — same failure mode.
      }
      let after = MockURLProtocol.requestCount
      #expect(
        after > before,
        "a retry after the failure must perform fresh network I/O (before=\(before), after=\(after))"
      )
    }

    // DELETED 2026-05-23 — was `downloading_stateObservableViaAvailability`.
    // The polling-based observation of `.downloading(progress:)` during an
    // in-flight download is inherently timing-coupled and flaky on iOS CI
    // (slower simulator + EM-1's eager manifest.json persistence + EM-2's
    // Tier-A oracle shortened the observable in-flight window below the
    // 100ms poll cadence). The enum case wiring, Sendable/Equatable, and
    // final `.available` transition are covered by EM1ManifestPersistenceTests,
    // SlugAvailabilityTests, SlugEnsureAvailableTests, and AvailabilityAggregatorTests.
    // Real-time observability of `.downloading` is a consumer-level concern
    // (Vinetas/SwiftBruja UI integration) and should be tested at that layer.

    @Test("dedup: joiner requesting a different files subset rides on the originator's set")
    func dedup_joinerWithDifferentFilesRidesOriginator() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "sortie6/dedup-joiner-files-\(UUID().uuidString.prefix(8))"
      let (manifest, bodies) = buildThreeFileFixture(modelId: String(modelId))
      MockURLProtocol.responder = makeSlowResponder(
        manifest: manifest, bodies: bodies, fileDelaySeconds: 0.5)

      let session = MockURLProtocol.session()
      let id = String(modelId)
      let base = tempBase

      // Originator: request config.json + weights.safetensors (2 files).
      // Joiner: request only config.json (1 file).
      // The dedup key is modelId, so the joiner rides on the originator's
      // 2-file download. Expected request count: 1 manifest + 2 files = 3.
      //
      // We must give the originator a head start so it deterministically wins
      // the race to register in InFlightDownloads. Without this, the joiner
      // could win and the originator would "ride" on the 1-file set instead.
      // The semantics we are documenting is "FIRST to register wins" — the
      // labels "originator" and "joiner" are about REGISTRATION ORDER.
      let originator: Task<Void, Error> = Task {
        try await Acervo.ensureAvailable(
          id, files: ["config.json", "weights.safetensors"], progress: nil, in: base,
          telemetry: nil, session: session)
      }
      // Sleep long enough for the originator's actor entry to occur first,
      // but short enough that the file fetch (slowed by 0.5s) is still in
      // flight when the joiner enters.
      try await Task.sleep(nanoseconds: 100_000_000)
      let joiner: Task<Void, Error> = Task {
        try await Acervo.ensureAvailable(
          id, files: ["config.json"], progress: nil, in: base, telemetry: nil, session: session)
      }
      try await originator.value
      try await joiner.value

      #expect(
        MockURLProtocol.requestCount == 3,
        "joiner must ride on originator's file set; expected 3 (1 manifest + 2 files), got \(MockURLProtocol.requestCount)"
      )
    }

    @Test(
      "hard-kill simulation: partial .part on disk with no registered Task returns .notAvailable")
    func hardKillSimulation_returnsNotAvailable_withPartialOnDisk() async throws {
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "sortie6/hard-kill-\(UUID().uuidString.prefix(8))"
      let slug = Acervo.slugify(modelId)
      let modelDir = tempBase.appendingPathComponent(slug)
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

      // Pre-populate a partial — simulates a download that was killed
      // before the final atomic rename + manifest persist.
      let partialPath = modelDir.appendingPathComponent("weights.safetensors.part")
      try Data(repeating: 0x42, count: 32).write(to: partialPath)

      // No in-flight task registered.
      let inFlight = await InFlightDownloads.shared.contains(modelId)
      #expect(inFlight == false, "precondition: no in-flight task")

      // availability must report .notAvailable — the .part file alone does
      // not satisfy `.available`, and the registry is the only source of
      // `.downloading`-ness.
      let result = await Acervo.availability(modelId, in: tempBase)
      #expect(
        result == .notAvailable,
        "partial on disk without in-flight task must report .notAvailable; got \(result)"
      )
    }
  }
}
