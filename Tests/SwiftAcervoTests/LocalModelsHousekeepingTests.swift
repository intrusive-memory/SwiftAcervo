// LocalModelsHousekeepingTests.swift
// SwiftAcervo
//
// Companion tests for Sources/SwiftAcervo/Acervo+Discovery.swift (EM-3 housekeeping:
// validity-marker filter + gcEmptyModelDirectories).
//
// Originally authored in Sortie EM-3 of OPERATION EIGHTH-MASTER iteration 01
// (validity-oracle / localModels housekeeping + remaining §1.3 acceptance).
// Renamed in Sortie S10 of OPERATION DRAWER DIVIDERS to drop the mission-tag prefix.
//
// Covers, per the EM-3 exit criteria:
//
//   1. §1.3 acceptance #3 — after `Acervo.ensureAvailable(...)` against a
//      fixture model, `<model-dir>/manifest.json` exists and is byte-equal
//      to the CDN manifest the model came from. Exercises the EM-1 write
//      path through the full public API.
//
//   2. §1.3 acceptance #4 — `Acervo.listModels()` returns exactly the
//      11 real models (equivalent fixture shape) when 8 empty-directory
//      stubs are also present in the same base directory.
//
//   3. §1.3 acceptance #5 (partial) — `Acervo.gcEmptyModelDirectories()`
//      removes only the empty stubs and leaves real model directories
//      untouched. GC acceptance is the remaining part of #5.
//
// All tests use in-memory or tempdir fixtures — no live disk dependency,
// no network. F7 honored: tests STOP and report PARTIAL if a real
// production bug is surfaced rather than masking it.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Shared helpers

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func makeTempBase(_ tag: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("EM3-\(tag)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func cleanup(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

/// Writes `data` to `url`, creating parent directories as needed.
private func writeFile(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
}

/// Creates a minimal "real" model directory with a `config.json` marker.
/// Returns the model directory URL.
private func makeRealModelDir(slug: String, in base: URL) throws -> URL {
  let modelDir = base.appendingPathComponent(slug)
  try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
  try Data("{\"model_type\":\"test\"}".utf8).write(
    to: modelDir.appendingPathComponent("config.json"))
  return modelDir
}

/// Creates an empty stub directory (no validity markers) to simulate a
/// cancelled download.
private func makeStubDir(slug: String, in base: URL) throws -> URL {
  let stubDir = base.appendingPathComponent(slug)
  try FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
  return stubDir
}

// MARK: - §1.3 acceptance #4 — listModels() excludes empty stubs

@Suite("listModels() filters empty-stub directories")
struct ListModelsFilterTests {

  /// §1.3 acceptance #4 (verbatim from REQUIREMENTS):
  /// `await Acervo.localModels()` does not include the eight empty directories
  /// on the audit machine.
  ///
  /// Fixture: 11 real model directories (each carrying at least one validity
  /// marker) + 8 empty-stub directories (none of the three markers). The 11
  /// real models use `config.json`; a second test below also exercises
  /// `model_index.json` and `manifest.json` as alternative markers.
  @Test("listModels: 11 real models + 8 empty stubs → returns exactly 11 real models")
  func listModels_excludesEmptyStubs_returnsOnlyRealModels() throws {
    let base = try makeTempBase("listModels-audit")
    defer { cleanup(base) }

    // 11 real model directories — shape mirrors the 2026-05-20 audit.
    // Slugs must contain an underscore so reverse-slugification succeeds.
    let realSlugs = [
      "mlx-community_Qwen2.5-7B-Instruct-4bit",
      "mlx-community_Llama-3.2-3B-Instruct-4bit",
      "mlx-community_Phi-3.5-mini-instruct-4bit",
      "mlx-community_gemma-2-9b-it-4bit",
      "mlx-community_Mistral-7B-Instruct-v0.3-4bit",
      "black-forest-labs_FLUX.2-klein-4B",
      "black-forest-labs_FLUX.2-klein-9B",
      "PixArt-alpha_PixArt-Sigma-XL-2-1024-MS",
      "mlx-community_Qwen3-4B-4bit",
      "mlx-community_Qwen3-8B-4bit",
      "mlx-community_Qwen3-14B-4bit",
    ]
    precondition(realSlugs.count == 11, "fixture must have exactly 11 real models")

    var expectedIds: Set<String> = []
    for slug in realSlugs {
      _ = try makeRealModelDir(slug: slug, in: base)
      // Compute the model ID from the slug (reverse slugify at first underscore).
      guard let underscoreIdx = slug.firstIndex(of: "_") else {
        Issue.record("Slug \(slug) has no underscore — test fixture error")
        return
      }
      let org = String(slug[slug.startIndex..<underscoreIdx])
      let repo = String(slug[slug.index(after: underscoreIdx)...])
      expectedIds.insert("\(org)/\(repo)")
    }

    // 8 empty-stub directories (shape of the 2026-05-20 audit's cancelled downloads).
    let stubSlugs = [
      "mlx-community_stub-download-01",
      "mlx-community_stub-download-02",
      "mlx-community_stub-download-03",
      "mlx-community_stub-download-04",
      "mlx-community_stub-download-05",
      "mlx-community_stub-download-06",
      "mlx-community_stub-download-07",
      "mlx-community_stub-download-08",
    ]
    precondition(stubSlugs.count == 8, "fixture must have exactly 8 empty stubs")
    for slug in stubSlugs {
      _ = try makeStubDir(slug: slug, in: base)
    }

    let models = try Acervo.listModels(in: base)
    let resultIds = Set(models.map(\.id))

    #expect(
      models.count == 11,
      "listModels must return exactly 11 real models, got \(models.count)"
    )
    #expect(
      resultIds == expectedIds,
      "returned model IDs do not match the expected 11 real model IDs"
    )

    // Verify none of the stub slugs leaked into the result.
    for slug in stubSlugs {
      guard let underscoreIdx = slug.firstIndex(of: "_") else { continue }
      let org = String(slug[slug.startIndex..<underscoreIdx])
      let repo = String(slug[slug.index(after: underscoreIdx)...])
      let stubId = "\(org)/\(repo)"
      #expect(
        !resultIds.contains(stubId),
        "stub model \(stubId) must not appear in listModels output"
      )
    }
  }

  @Test("listModels: directory with model_index.json (no config.json) → included")
  func listModels_includesModelIndexDirectory() throws {
    let base = try makeTempBase("listModels-modelindex")
    defer { cleanup(base) }

    // model_index.json only — the FLUX.2 diffusers pattern.
    let slug = "diffusers-org_pipeline-model"
    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{\"_class_name\":\"DiffusionPipeline\"}".utf8).write(
      to: modelDir.appendingPathComponent("model_index.json"))

    let models = try Acervo.listModels(in: base)
    #expect(models.count == 1, "directory with model_index.json must be included")
    #expect(models.first?.id == "diffusers-org/pipeline-model")
  }

  @Test("listModels: directory with manifest.json only → included")
  func listModels_includesManifestOnlyDirectory() throws {
    let base = try makeTempBase("listModels-manifestonly")
    defer { cleanup(base) }

    // A directory with only manifest.json (post-EM-1 pattern for partial downloads
    // where the manifest was persisted but weights are not yet present).
    let slug = "test-org_manifest-only"
    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    // Write a minimal (but plausible) manifest.json. The oracle test only needs
    // the file to exist at `manifest.json` — content validity is not checked here.
    let placeholder = Data("{\"manifestVersion\":1}".utf8)
    try placeholder.write(to: modelDir.appendingPathComponent(AcervoDownloader.manifestFilename))

    let models = try Acervo.listModels(in: base)
    #expect(models.count == 1, "directory with manifest.json only must be included")
    #expect(models.first?.id == "test-org/manifest-only")
  }

  @Test("listModels: empty-stub directory (no markers) → excluded")
  func listModels_excludesEmptyStub() throws {
    let base = try makeTempBase("listModels-emptystub")
    defer { cleanup(base) }

    // One real model and one empty stub.
    _ = try makeRealModelDir(slug: "real-org_real-model", in: base)
    _ = try makeStubDir(slug: "stub-org_stub-model", in: base)

    let models = try Acervo.listModels(in: base)
    #expect(models.count == 1, "empty stub must be excluded; only real model returned")
    #expect(models.first?.id == "real-org/real-model")
  }
}

// MARK: - §1.3 acceptance #5 — gcEmptyModelDirectories() acceptance

@Suite("gcEmptyModelDirectories() acceptance")
struct GCEmptyModelDirectoriesTests {

  @Test("gcEmptyModelDirectories: removes only empty stubs, leaves real models untouched")
  func gc_removesStubsLeavesRealModels() throws {
    let base = try makeTempBase("gc-stubs")
    defer { cleanup(base) }

    // 3 real model directories.
    let realSlugs = [
      "mlx-community_ModelA",
      "mlx-community_ModelB",
      "mlx-community_ModelC",
    ]
    var realDirs: [URL] = []
    for slug in realSlugs {
      realDirs.append(try makeRealModelDir(slug: slug, in: base))
    }

    // 3 empty-stub directories.
    let stubSlugs = [
      "mlx-community_Stub1",
      "mlx-community_Stub2",
      "mlx-community_Stub3",
    ]
    var stubDirs: [URL] = []
    for slug in stubSlugs {
      stubDirs.append(try makeStubDir(slug: slug, in: base))
    }

    // Confirm pre-conditions: 6 directories total.
    let pre = try FileManager.default.contentsOfDirectory(
      at: base, includingPropertiesForKeys: nil)
    #expect(pre.count == 6, "pre-condition: 6 directories expected before GC")

    let removed = try Acervo.gcEmptyModelDirectories(in: base)

    // Exactly 3 stubs must have been removed.
    #expect(
      removed.count == 3,
      "expected 3 removed; got \(removed.count)"
    )
    let removedLastComponents = Set(removed.map(\.lastPathComponent))
    for slug in stubSlugs {
      #expect(
        removedLastComponents.contains(slug),
        "stub \(slug) must be in the removed list"
      )
    }

    // Real model directories must still exist on disk.
    let fm = FileManager.default
    for realDir in realDirs {
      #expect(
        fm.fileExists(atPath: realDir.path),
        "real model directory \(realDir.lastPathComponent) must remain untouched"
      )
    }

    // Stub directories must no longer exist on disk.
    for stubDir in stubDirs {
      #expect(
        !fm.fileExists(atPath: stubDir.path),
        "stub directory \(stubDir.lastPathComponent) must be removed from disk"
      )
    }

    // Post-condition: only 3 directories remain.
    let post = try FileManager.default.contentsOfDirectory(
      at: base, includingPropertiesForKeys: nil)
    #expect(post.count == 3, "post-GC: only 3 real model directories must remain")
  }

  @Test("gcEmptyModelDirectories: directory with model_index.json is NOT removed")
  func gc_keepsModelIndexDirectory() throws {
    let base = try makeTempBase("gc-modelindex")
    defer { cleanup(base) }

    // Directory with model_index.json (diffusers pattern) — must be retained.
    let slug = "diffusers-org_pipeline"
    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{\"_class_name\":\"DiffusionPipeline\"}".utf8).write(
      to: modelDir.appendingPathComponent("model_index.json"))

    let removed = try Acervo.gcEmptyModelDirectories(in: base)
    #expect(removed.isEmpty, "directory with model_index.json must not be removed by GC")
    #expect(FileManager.default.fileExists(atPath: modelDir.path))
  }

  @Test("gcEmptyModelDirectories: directory with manifest.json only is NOT removed")
  func gc_keepsManifestOnlyDirectory() throws {
    let base = try makeTempBase("gc-manifestonly")
    defer { cleanup(base) }

    // Directory with manifest.json only — the EM-1 artifact; must be retained
    // because the manifest indicates the download was at least started legitimately.
    let slug = "test-org_partial-download"
    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{\"manifestVersion\":1}".utf8).write(
      to: modelDir.appendingPathComponent(AcervoDownloader.manifestFilename))

    let removed = try Acervo.gcEmptyModelDirectories(in: base)
    #expect(removed.isEmpty, "directory with manifest.json must not be removed by GC")
    #expect(FileManager.default.fileExists(atPath: modelDir.path))
  }

  @Test("gcEmptyModelDirectories: empty base directory returns empty array without error")
  func gc_emptyBase_returnsEmpty() throws {
    let base = try makeTempBase("gc-emptybase")
    defer { cleanup(base) }

    let removed = try Acervo.gcEmptyModelDirectories(in: base)
    #expect(removed.isEmpty)
  }

  @Test("gcEmptyModelDirectories: nonexistent base directory returns empty array without error")
  func gc_nonexistentBase_returnsEmpty() throws {
    let nonexistent = FileManager.default.temporaryDirectory
      .appendingPathComponent("EM3-gc-nonexistent-\(UUID().uuidString)")
    // Do NOT create the directory.

    let removed = try Acervo.gcEmptyModelDirectories(in: nonexistent)
    #expect(removed.isEmpty)
  }

  @Test("gcEmptyModelDirectories: 11 real + 8 stubs mirrors the 2026-05-20 audit shape")
  func gc_auditShape_removes8Stubs_leaves11Real() throws {
    let base = try makeTempBase("gc-audit-shape")
    defer { cleanup(base) }

    let realSlugs = [
      "mlx-community_Qwen2.5-7B-Instruct-4bit",
      "mlx-community_Llama-3.2-3B-Instruct-4bit",
      "mlx-community_Phi-3.5-mini-instruct-4bit",
      "mlx-community_gemma-2-9b-it-4bit",
      "mlx-community_Mistral-7B-Instruct-v0.3-4bit",
      "black-forest-labs_FLUX.2-klein-4B",
      "black-forest-labs_FLUX.2-klein-9B",
      "PixArt-alpha_PixArt-Sigma-XL-2-1024-MS",
      "mlx-community_Qwen3-4B-4bit",
      "mlx-community_Qwen3-8B-4bit",
      "mlx-community_Qwen3-14B-4bit",
    ]
    for slug in realSlugs {
      _ = try makeRealModelDir(slug: slug, in: base)
    }

    let stubSlugs = [
      "mlx-community_stub-download-01",
      "mlx-community_stub-download-02",
      "mlx-community_stub-download-03",
      "mlx-community_stub-download-04",
      "mlx-community_stub-download-05",
      "mlx-community_stub-download-06",
      "mlx-community_stub-download-07",
      "mlx-community_stub-download-08",
    ]
    for slug in stubSlugs {
      _ = try makeStubDir(slug: slug, in: base)
    }

    let removed = try Acervo.gcEmptyModelDirectories(in: base)
    #expect(removed.count == 8, "exactly 8 stubs must be removed")

    // All 11 real model directories must still be on disk.
    for slug in realSlugs {
      let url = base.appendingPathComponent(slug)
      #expect(
        FileManager.default.fileExists(atPath: url.path),
        "real model dir \(slug) must survive GC"
      )
    }

    // No stubs remain.
    for slug in stubSlugs {
      let url = base.appendingPathComponent(slug)
      #expect(
        !FileManager.default.fileExists(atPath: url.path),
        "stub \(slug) must be removed by GC"
      )
    }
  }
}

// MARK: - §1.3 acceptance #3 — post-ensureAvailable manifest is byte-equal

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// §1.3 acceptance #3 (verbatim from REQUIREMENTS):
  /// After a successful `Acervo.ensureAvailable(...)` of any model,
  /// `<model-dir>/manifest.json` exists and is byte-equal to the CDN manifest.
  ///
  /// This test closes the loop on EM-1's write path through the full public API
  /// `Acervo.ensureAvailable(_:files:progress:)` rather than testing
  /// `AcervoDownloader.downloadFiles` directly.
  ///
  /// The `MockURLProtocol` intercepts the manifest request and file requests
  /// so no network calls are made.
  @Suite("post-ensureAvailable manifest persistence (§1.3 acceptance #3)")
  struct EnsureAvailableManifestTests {

    private func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("ensureAvailable: <model-dir>/manifest.json is byte-equal to CDN manifest wire bytes")
    func ensureAvailable_manifestIsByteEqualToCDNWireBytes() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        // Use a unique model ID to avoid interference with other tests.
        let modelId = "em3-acceptance3/repo-\(UUID().uuidString.prefix(8))"
        let slug = Acervo.slugify(modelId)

        let tempBase = FileManager.default.temporaryDirectory
          .appendingPathComponent("EM3Acceptance3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Build a CDN manifest with two files. Compute SHA-256 of known bodies so
        // the downloader's per-file integrity check passes.
        let configBody = Data("{\"model_type\":\"em3\"}".utf8)
        let weightsBody = Data(repeating: 0x5A, count: 128)

        let files = [
          CDNManifestFile(
            path: "config.json",
            sha256: sha256Hex(configBody),
            sizeBytes: Int64(configBody.count)
          ),
          CDNManifestFile(
            path: "model.safetensors",
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
        // Serialize ONCE; this is the "CDN wire bytes" that ensureAvailable receives.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let manifestWireBytes = try encoder.encode(manifest)

        // Install MockURLProtocol responder.
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
          // File request — match by last path component.
          let path = request.url?.lastPathComponent ?? ""
          let body: Data
          switch path {
          case "config.json": body = configBody
          case "model.safetensors": body = weightsBody
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

        // Call the FULL PUBLIC API — ensureAvailable(modelId, files:progress:session:).
        // This exercises the complete chain:
        //   Acervo.ensureAvailable → download → downloadFiles → persistManifestBytes
        try await Acervo.ensureAvailable(
          modelId,
          files: [],
          progress: nil,
          in: tempBase,
          telemetry: nil,
          session: MockURLProtocol.session()
        )

        // §1.3 acceptance #3 assertion: manifest.json must exist at <model-dir>.
        let modelDir = tempBase.appendingPathComponent(slug)
        let manifestURL = modelDir.appendingPathComponent(AcervoDownloader.manifestFilename)
        #expect(
          FileManager.default.fileExists(atPath: manifestURL.path),
          "manifest.json must be persisted after ensureAvailable completes successfully"
        )

        // Byte-equality: the file on disk must be identical to the wire bytes
        // returned by MockURLProtocol (i.e., what the CDN would have sent).
        let onDiskBytes = try Data(contentsOf: manifestURL)
        #expect(
          onDiskBytes == manifestWireBytes,
          "manifest.json on disk must be byte-equal to the CDN wire bytes"
        )

        // Belt-and-suspenders: the written bytes decode back to the same model ID.
        let decoded = try JSONDecoder().decode(CDNManifest.self, from: onDiskBytes)
        #expect(decoded.modelId == modelId)
        #expect(decoded.files.count == 2)
      }
    }

    @Test("ensureAvailable: no re-download on second call; manifest.json remains byte-equal")
    func ensureAvailable_noRedownloadOnSecondCall_manifestRemains() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "em3-acceptance3/fast-path-\(UUID().uuidString.prefix(8))"
        let slug = Acervo.slugify(modelId)

        let tempBase = FileManager.default.temporaryDirectory
          .appendingPathComponent("EM3FastPath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let configBody = Data("{\"model_type\":\"fast\"}".utf8)
        let files = [
          CDNManifestFile(
            path: "config.json",
            sha256: sha256Hex(configBody),
            sizeBytes: Int64(configBody.count)
          )
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
          if urlString.hasSuffix("/manifest.json") {
            let response = HTTPURLResponse(
              url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"])!
            return (response, manifestWireBytes)
          }
          let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"])!
          return (response, configBody)
        }

        // First call downloads the model and writes manifest.json.
        try await Acervo.ensureAvailable(
          modelId, files: [], progress: nil,
          in: tempBase, telemetry: nil, session: MockURLProtocol.session())

        let manifestURL = tempBase.appendingPathComponent(slug)
          .appendingPathComponent(AcervoDownloader.manifestFilename)
        let firstBytes = try Data(contentsOf: manifestURL)
        #expect(firstBytes == manifestWireBytes, "first call: manifest.json must be byte-equal")

        let requestsAfterFirst = MockURLProtocol.requestCount

        // Second call should fast-path (model is available); no new requests.
        try await Acervo.ensureAvailable(
          modelId, files: [], progress: nil,
          in: tempBase, telemetry: nil, session: MockURLProtocol.session())

        #expect(
          MockURLProtocol.requestCount == requestsAfterFirst,
          "second call should not make additional network requests (fast path)"
        )

        // manifest.json is still the same bytes.
        let secondBytes = try Data(contentsOf: manifestURL)
        #expect(
          secondBytes == manifestWireBytes, "manifest.json must remain byte-equal after second call"
        )
      }
    }
  }
}
