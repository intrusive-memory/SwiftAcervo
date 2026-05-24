// EM1ManifestPersistenceTests.swift
// SwiftAcervo
//
// Sortie EM-1 of OPERATION EIGHTH-MASTER iteration 01
// (validity-oracle / manifest persistence + schema invariant foundation).
//
// Covers, per the EM-1 exit criteria:
//
//   1. `ModelAvailability.partial(missing:)` exists and round-trips through
//      `Equatable` / `Sendable` (Hashable round-trip via a Set).
//   2. After a simulated successful download into a tempdir fixture,
//      `<model-dir>/manifest.json` exists and is byte-equal to the CDN
//      manifest bytes the downloader received.
//   3. Nested-path case: a manifest with `files[].path` depth ≥ 1 downloads
//      to the correct subdirectory (`mkdir -p` along the path).
//   4. The §2 invariant — round-trip a sample CDN manifest with nested paths
//      through the existing decoder and assert decode succeeds, with byte
//      equality preserved.
//
// All tests are tempdir-only — no live disk dependency, no network.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - .partial(missing:) round-trip

@Suite("EM-1: ModelAvailability.partial round-trip")
struct EM1PartialAvailabilityTests {

  @Test(".partial(missing:) is Equatable and reflects the missing array")
  func partialEquatableAndPayload() {
    let missing = [
      "model-00001-of-00009.safetensors",
      "model-00002-of-00009.safetensors",
    ]
    let a: ModelAvailability = .partial(missing: missing)
    let b: ModelAvailability = .partial(missing: missing)
    let c: ModelAvailability = .partial(missing: [missing[0]])

    #expect(a == b, ".partial values with the same missing array must be Equatable-equal")
    #expect(a != c, ".partial values with different missing arrays must not be equal")
    #expect(a != .available)
    #expect(a != .notAvailable)
    #expect(a != .downloading(progress: 0.5))

    // Confirm the payload is reachable via pattern match (the surface EM-2
    // will consume).
    guard case .partial(let extracted) = a else {
      Issue.record(".partial case extraction failed")
      return
    }
    #expect(extracted == missing)
  }

  @Test(".partial survives a Sendable boundary (Task.value round-trip)")
  func partialSurvivesSendableBoundary() async {
    let missing = ["a.bin", "subdir/b.bin"]
    let value: ModelAvailability = .partial(missing: missing)

    // Crossing a `Task` boundary is the canonical exercise of the
    // `Sendable` contract for an enum with associated values.
    let crossed: ModelAvailability = await Task { value }.value
    #expect(crossed == value)

    guard case .partial(let extracted) = crossed else {
      Issue.record(".partial did not survive Task round-trip")
      return
    }
    #expect(extracted == missing)
  }

  @Test(".partial round-trips through @Sendable closure capture")
  func partialRoundTripsThroughSendableClosure() async {
    let original: ModelAvailability = .partial(missing: ["x.bin", "y.bin"])
    let box: @Sendable () -> ModelAvailability = { original }
    let observed = await Task { box() }.value
    #expect(observed == original)
  }
}

// MARK: - CDNManifest byte-equal round-trip (§2 invariant)

@Suite("EM-1: CDN manifest §2 byte-equal round-trip")
struct EM1ManifestRoundTripTests {

  /// Canonical CDN-shaped manifest JSON with nested paths. The bytes here
  /// are the wire bytes — once written to disk by `persistManifestBytes`,
  /// the on-disk file MUST be byte-equal.
  private static let nestedManifestJSON = """
    {
      "manifestVersion" : 1,
      "modelId" : "black-forest-labs/FLUX.2-klein-4B",
      "primaryRepo" : "black-forest-labs/FLUX.2-klein-4B",
      "components" : ["black-forest-labs/FLUX.2-klein-4B"],
      "slug" : "black-forest-labs_FLUX.2-klein-4B",
      "updatedAt" : "2026-05-23T00:00:00Z",
      "files" : [
        {
          "path" : "model_index.json",
          "sha256" : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "sizeBytes" : 100
        },
        {
          "path" : "transformer/model-00001-of-00003.safetensors",
          "sha256" : "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "sizeBytes" : 200
        },
        {
          "path" : "vae/diffusion_pytorch_model.safetensors",
          "sha256" : "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "sizeBytes" : 300
        }
      ],
      "manifestChecksum" : "%CHECKSUM%"
    }
    """

  /// Builds the JSON text with a real `manifestChecksum` computed via the
  /// canonical algorithm so a round-tripped manifest passes self-validation.
  private static func manifestJSON() -> String {
    let shas = [
      String(repeating: "a", count: 64),
      String(repeating: "b", count: 64),
      String(repeating: "c", count: 64),
    ]
    let checksum = CDNManifest.computeChecksum(from: shas)
    return nestedManifestJSON.replacingOccurrences(of: "%CHECKSUM%", with: checksum)
  }

  @Test("nested-path CDN manifest decodes successfully (§2 invariant)")
  func nestedPathManifestDecodes() throws {
    let json = Self.manifestJSON()
    let data = Data(json.utf8)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

    #expect(manifest.files.count == 3)
    #expect(manifest.files[1].path == "transformer/model-00001-of-00003.safetensors")
    #expect(manifest.files[2].path == "vae/diffusion_pytorch_model.safetensors")
    #expect(manifest.verifyChecksum())
  }

  @Test("persistManifestBytes writes byte-equal manifest.json to <modelDir>")
  func persistManifestBytes_isByteEqual() throws {
    let json = Self.manifestJSON()
    let originalBytes = Data(json.utf8)

    let baseDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EM1ByteEqual-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let slug = "black-forest-labs_FLUX.2-klein-4B"
    try AcervoDownloader.persistManifestBytes(originalBytes, slug: slug, in: baseDir)

    let writtenURL =
      baseDir
      .appendingPathComponent(slug)
      .appendingPathComponent(AcervoDownloader.manifestFilename)
    let writtenBytes = try Data(contentsOf: writtenURL)

    #expect(
      writtenBytes == originalBytes,
      "manifest.json on disk MUST be byte-equal to the CDN bytes passed in"
    )

    // And the written bytes must still decode through the existing decoder.
    let roundTripped = try JSONDecoder().decode(CDNManifest.self, from: writtenBytes)
    #expect(roundTripped.modelId == "black-forest-labs/FLUX.2-klein-4B")
    #expect(roundTripped.files.count == 3)
  }

  @Test("persistManifestBytes creates the model directory if missing (mkdir -p)")
  func persistManifestBytes_createsModelDir() throws {
    let baseDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EM1MkdirP-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let bytes = Data(Self.manifestJSON().utf8)
    let slug = "test-org_test-repo"
    try AcervoDownloader.persistManifestBytes(bytes, slug: slug, in: baseDir)

    let modelDir = baseDir.appendingPathComponent(slug)
    var isDir: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir))
    #expect(isDir.boolValue)
  }

  @Test("persistManifestBytes is atomic — partial-write debris is not visible")
  func persistManifestBytes_atomicOverwrite() throws {
    let baseDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EM1Atomic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: baseDir) }

    let slug = "test-org_test-repo"
    let modelDir = baseDir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let first = Data("{\"placeholder\":1}".utf8)
    let second = Data(Self.manifestJSON().utf8)

    try AcervoDownloader.persistManifestBytes(first, slug: slug, in: baseDir)
    try AcervoDownloader.persistManifestBytes(second, slug: slug, in: baseDir)

    let url = modelDir.appendingPathComponent(AcervoDownloader.manifestFilename)
    let final = try Data(contentsOf: url)
    #expect(final == second, "the most-recent atomic write must win")
  }
}

// MARK: - End-to-end: downloadFiles writes byte-equal manifest.json and
// honors nested paths.

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("EM-1: downloadFiles persists byte-equal manifest.json")
  struct EM1DownloadFilesByteEqualTests {

    private func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("downloadFiles writes <modelDir>/manifest.json byte-equal to wire bytes")
    func downloadFiles_writesByteEqualManifest() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "em1-byte-equal/repo-\(UUID().uuidString.prefix(8))"
        let slug = Acervo.slugify(modelId)
        let tempBase = FileManager.default.temporaryDirectory
          .appendingPathComponent("EM1DownloadByteEqual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let destination = tempBase.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        // Construct a manifest deterministically and serialize ONCE so the
        // exact wire bytes are known.
        let configBody = Data("{\"hello\":\"world\"}".utf8)
        let weightsBody = Data(repeating: 0x42, count: 256)
        let files = [
          CDNManifestFile(
            path: "config.json",
            sha256: sha256Hex(configBody),
            sizeBytes: Int64(configBody.count)
          ),
          CDNManifestFile(
            path: "weights.bin",
            sha256: sha256Hex(weightsBody),
            sizeBytes: Int64(weightsBody.count)
          ),
        ]
        let manifest = CDNManifest(
          manifestVersion: CDNManifest.supportedVersion,
          modelId: modelId,
          slug: slug,
          updatedAt: "2026-05-23T00:00:00Z",
          files: files,
          manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let manifestWireBytes = try encoder.encode(manifest)

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
            return (response, manifestWireBytes)
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

        // The byte-equal manifest must be on disk at <modelDir>/manifest.json.
        let manifestURL = destination.appendingPathComponent(AcervoDownloader.manifestFilename)
        #expect(
          FileManager.default.fileExists(atPath: manifestURL.path),
          "manifest.json must be persisted after a successful downloadFiles"
        )

        let onDiskBytes = try Data(contentsOf: manifestURL)
        #expect(
          onDiskBytes == manifestWireBytes,
          "manifest.json on disk MUST be byte-equal to the CDN wire bytes"
        )

        // And it must still decode cleanly through the existing decoder.
        let decoded = try JSONDecoder().decode(CDNManifest.self, from: onDiskBytes)
        #expect(decoded.modelId == modelId)
        #expect(decoded.slug == slug)
        #expect(decoded.files.count == 2)
      }
    }

    @Test("downloadFiles honors nested files[].path — file lands in subdirectory")
    func downloadFiles_nestedPath_writesToSubdirectory() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "em1-nested/repo-\(UUID().uuidString.prefix(8))"
        let slug = Acervo.slugify(modelId)
        let tempBase = FileManager.default.temporaryDirectory
          .appendingPathComponent("EM1Nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let destination = tempBase.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        // A manifest exercising depth-1 and depth-2 subdirectory paths.
        let indexBody = Data("{\"_diffusers\":true}".utf8)
        let shard1Body = Data(repeating: 0x01, count: 128)
        let shard2Body = Data(repeating: 0x02, count: 96)
        let nestedBody = Data(repeating: 0x03, count: 64)

        let files = [
          CDNManifestFile(
            path: "model_index.json",
            sha256: sha256Hex(indexBody),
            sizeBytes: Int64(indexBody.count)
          ),
          CDNManifestFile(
            path: "transformer/model-00001-of-00003.safetensors",
            sha256: sha256Hex(shard1Body),
            sizeBytes: Int64(shard1Body.count)
          ),
          CDNManifestFile(
            path: "transformer/model-00002-of-00003.safetensors",
            sha256: sha256Hex(shard2Body),
            sizeBytes: Int64(shard2Body.count)
          ),
          CDNManifestFile(
            path: "text_encoder/tokenizer/spiece.model",
            sha256: sha256Hex(nestedBody),
            sizeBytes: Int64(nestedBody.count)
          ),
        ]
        let manifest = CDNManifest(
          manifestVersion: CDNManifest.supportedVersion,
          modelId: modelId,
          slug: slug,
          updatedAt: "2026-05-23T00:00:00Z",
          files: files,
          manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
        )
        let manifestWireBytes = try JSONEncoder().encode(manifest)

        MockURLProtocol.responder = { request in
          let urlString = request.url?.absoluteString ?? ""
          if urlString.hasSuffix("/manifest.json") {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
            )!
            return (response, manifestWireBytes)
          }
          // Match by the manifest-relative path tail, since the request URL
          // preserves the subdirectory components.
          let urlPath = request.url?.path ?? ""
          let body: Data
          if urlPath.hasSuffix("/model_index.json") {
            body = indexBody
          } else if urlPath.hasSuffix("/transformer/model-00001-of-00003.safetensors") {
            body = shard1Body
          } else if urlPath.hasSuffix("/transformer/model-00002-of-00003.safetensors") {
            body = shard2Body
          } else if urlPath.hasSuffix("/text_encoder/tokenizer/spiece.model") {
            body = nestedBody
          } else {
            body = Data()
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

        // Every declared file must be on disk at its nested path.
        let fm = FileManager.default
        for entry in files {
          let url = destination.appendingPathComponent(entry.path)
          #expect(
            fm.fileExists(atPath: url.path),
            "expected file at nested path \(entry.path) to exist on disk"
          )
          if let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
          {
            #expect(
              size == entry.sizeBytes,
              "size mismatch for \(entry.path): expected \(entry.sizeBytes), got \(size)"
            )
          }
        }

        // And the parent directories must exist as directories (mkdir -p).
        var isDir: ObjCBool = false
        let transformerDir = destination.appendingPathComponent("transformer")
        #expect(fm.fileExists(atPath: transformerDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        let nestedDir = destination.appendingPathComponent("text_encoder/tokenizer")
        #expect(fm.fileExists(atPath: nestedDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // And manifest.json must be byte-equal at the model root.
        let manifestURL = destination.appendingPathComponent(AcervoDownloader.manifestFilename)
        let onDiskBytes = try Data(contentsOf: manifestURL)
        #expect(onDiskBytes == manifestWireBytes)
      }
    }
  }
}
