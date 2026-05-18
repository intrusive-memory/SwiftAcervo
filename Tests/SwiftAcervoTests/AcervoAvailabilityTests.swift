import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for Acervo availability checks:
/// - `isModelAvailable()` — strict, manifest-driven (Sortie 4+).
/// - `isModelConfigPresent()` — legacy loose check, escape hatch only.
/// - `modelFileExists()` — file-level presence probe.
///
/// These tests synthesize temporary directories that mimic the SharedModels
/// structure so file-presence detection can be validated without touching
/// real model storage. The strict `isModelAvailable` tests also synthesize
/// `.acervo-manifest.json` files that self-validate against a freshly
/// computed `manifestChecksum`.
struct AcervoAvailabilityTests {

  // MARK: - Test Helpers

  /// Creates a temporary base directory for testing.
  private func makeTempBase() throws -> URL {
    let tempBase = FileManager.default.temporaryDirectory
      .appendingPathComponent("AcervoAvailabilityTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempBase,
      withIntermediateDirectories: true
    )
    return tempBase
  }

  /// Removes a temporary directory.
  private func removeTempBase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  /// SHA-256 of `data` as a lowercase hex string.
  private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Composes a single `CDNManifestFile` from a relative path and a data blob.
  private func manifestFile(path: String, data: Data) -> CDNManifestFile {
    CDNManifestFile(
      path: path,
      sha256: sha256Hex(data),
      sizeBytes: Int64(data.count)
    )
  }

  /// Builds a self-consistent `CDNManifest` for the given model and files.
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
  /// declared bytes (or a caller-supplied override for "truncated"/"missing"
  /// scenarios) and persists `.acervo-manifest.json` via the production
  /// `AcervoDownloader.persistManifest` API so the test exercises the same
  /// code path the downloader uses.
  ///
  /// `bodies` maps `path -> Data`. Paths in the manifest that are absent
  /// from `bodies` are simply not written (i.e., manifest declares the file
  /// but it is missing on disk).
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

  // MARK: - isModelAvailable (strict)

  @Test("isModelAvailable returns false when no manifest is cached")
  func isModelAvailable_returnsFalse_whenNoManifestCached() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/config-only"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

    // config.json present but no .acervo-manifest.json — strict check must
    // return false.
    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == false)
  }

  @Test("isModelAvailable returns true when manifest cached and all files size-match")
  func isModelAvailable_returnsTrue_whenManifestCachedAndAllFilesSizeMatch() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/all-present"
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

    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == true)
  }

  @Test("isModelAvailable returns false when a shard size mismatches")
  func isModelAvailable_returnsFalse_whenShardSizeMismatched() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/truncated-shard"
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

    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == false)
  }

  @Test("isModelAvailable returns false when a manifest-declared file is missing on disk")
  func isModelAvailable_returnsFalse_whenManifestFileMissing() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/missing-file"
    let configData = Data("{}".utf8)
    let weightsData = Data(repeating: 0x42, count: 1024)
    let files = [
      manifestFile(path: "config.json", data: configData),
      manifestFile(path: "weights.safetensors", data: weightsData),
    ]
    let manifest = makeManifest(modelId: modelId, files: files)

    // Materialize config.json but NOT weights.safetensors.
    try materializeModel(
      modelId: modelId,
      in: tempBase,
      manifest: manifest,
      bodies: [
        "config.json": configData
      ]
    )

    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == false)
  }

  @Test("isModelAvailable returns false when manifest is absent even if data files exist")
  func isModelAvailable_returnsFalse_whenManifestAbsent() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/no-manifest"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    // Write a full plausible file set but DO NOT persist a manifest.
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
    try Data(repeating: 0x42, count: 1024).write(
      to: modelDir.appendingPathComponent("weights.safetensors")
    )

    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == false)
  }

  // MARK: - isModelConfigPresent (legacy loose check)

  @Test("isModelConfigPresent returns true when config.json exists")
  func isModelConfigPresent_returnsTrue_whenConfigJsonExists() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/config-only-loose"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

    #expect(Acervo.isModelConfigPresent(modelId, in: tempBase) == true)
  }

  @Test("isModelConfigPresent returns false when config.json is missing")
  func isModelConfigPresent_returnsFalse_whenConfigJsonMissing() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/empty-dir"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    #expect(Acervo.isModelConfigPresent(modelId, in: tempBase) == false)
  }

  @Test("isModelConfigPresent returns false for invalid model ID")
  func isModelConfigPresent_returnsFalse_forInvalidModelId() {
    #expect(Acervo.isModelConfigPresent("no-slash") == false)
  }

  // MARK: - modelFileExists

  @Test("modelFileExists returns false for nonexistent model")
  func modelFileExistsNonexistent() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let result = Acervo.modelFileExists(
      "nonexistent-org/nonexistent-model",
      fileName: "config.json",
      in: tempBase
    )
    #expect(result == false)
  }

  @Test("modelFileExists returns true for root-level file")
  func modelFileExistsRootFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/root-file"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("tokenizer.json"))

    #expect(Acervo.modelFileExists(modelId, fileName: "tokenizer.json", in: tempBase) == true)
  }

  @Test("modelFileExists returns false for missing root-level file")
  func modelFileExistsMissingRootFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/missing-file"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    #expect(Acervo.modelFileExists(modelId, fileName: "nonexistent.json", in: tempBase) == false)
  }

  @Test("modelFileExists returns true for subdirectory file")
  func modelFileExistsSubdirectoryFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/subdir-file"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    let subdirURL = modelDir.appendingPathComponent("speech_tokenizer")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: subdirURL.appendingPathComponent("config.json"))

    #expect(
      Acervo.modelFileExists(modelId, fileName: "speech_tokenizer/config.json", in: tempBase)
        == true)
  }

  @Test("modelFileExists returns false for missing subdirectory file")
  func modelFileExistsMissingSubdirFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/missing-subdir"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    #expect(
      Acervo.modelFileExists(modelId, fileName: "speech_tokenizer/config.json", in: tempBase)
        == false)
  }

  @Test("modelFileExists returns false for invalid model ID")
  func modelFileExistsInvalidId() {
    #expect(Acervo.modelFileExists("invalid", fileName: "config.json") == false)
  }
}

// MARK: - Manifest Persistence (MockURLProtocol-driven)

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Verifies that `AcervoDownloader.downloadFiles` writes
  /// `.acervo-manifest.json` after a successful end-to-end download, and
  /// that the persisted manifest self-validates. This is the corner stone
  /// for the new strict `Acervo.isModelAvailable(_:)` contract: without
  /// persistence, the strict check has nothing to consult.
  ///
  /// Nested under `MockURLProtocolSuite` (which is `.serialized` via
  /// `SharedStaticStateSuite`) because it mutates the global
  /// `MockURLProtocol.responder`.
  @Suite("Manifest Persistence Tests")
  struct ManifestPersistenceTests {

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

    private func makeManifest(modelId: String, files: [CDNManifestFile]) -> CDNManifest {
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

    @Test("downloadFiles persists .acervo-manifest.json after a successful download")
    func downloadFiles_persistsManifest_onSuccess() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "persist-test/repo-\(UUID().uuidString.prefix(8))"
        let tempBase = FileManager.default.temporaryDirectory
          .appendingPathComponent("AcervoManifestPersist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let slug = Acervo.slugify(modelId)
        let destination = tempBase.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        // Two-file manifest with matching SHA + size for each body.
        let configBody = Data("{}".utf8)
        let weightsBody = Data(repeating: 0x99, count: 1024)
        let files = [
          manifestFile(path: "config.json", data: configBody),
          manifestFile(path: "weights.bin", data: weightsBody),
        ]
        let manifest = makeManifest(modelId: modelId, files: files)
        let manifestData = try JSONEncoder().encode(manifest)

        MockURLProtocol.responder = { request in
          let urlString = request.url?.absoluteString ?? ""
          let path = request.url?.lastPathComponent ?? ""
          if urlString.hasSuffix("/manifest.json") {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
            )!
            return (response, manifestData)
          }
          let body: Data
          switch path {
          case "config.json": body = configBody
          case "weights.bin": body = weightsBody
          default: body = Data()
          }
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
          )!
          return (response, body)
        }

        try await AcervoDownloader.downloadFiles(
          modelId: modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session()
        )

        // The cached manifest must now exist on disk.
        let cachedURL = destination.appendingPathComponent(
          AcervoDownloader.cachedManifestFilename
        )
        #expect(
          FileManager.default.fileExists(atPath: cachedURL.path),
          ".acervo-manifest.json must be persisted after a successful downloadFiles"
        )

        // And it must self-validate.
        let cachedData = try Data(contentsOf: cachedURL)
        let cachedManifest = try JSONDecoder().decode(CDNManifest.self, from: cachedData)
        #expect(
          cachedManifest.verifyChecksum(),
          "Persisted manifest's manifestChecksum must self-validate"
        )
        #expect(cachedManifest.modelId == modelId)

        // And isModelAvailable must now return true via the strict check.
        #expect(
          Acervo.isModelAvailable(modelId, in: tempBase) == true,
          "isModelAvailable must return true after a successful download persists the manifest"
        )
      }
    }
  }
}
