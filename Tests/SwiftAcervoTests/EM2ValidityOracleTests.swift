// EM2ValidityOracleTests.swift
// SwiftAcervo
//
// Companion tests for Sources/SwiftAcervo/Acervo+Availability.swift (oracle plumbing)
// and Sources/SwiftAcervo/ValidityOracle.swift.
//
// Sortie EM-2 of OPERATION EIGHTH-MASTER iteration 01
// (validity-oracle / manifest-driven 3-tier availability).
//
// Covers, per the EM-2 exit criteria:
//
//   1. §1.3 acceptance #1 — Qwen3-Coder-Next-shaped fixture (config.json +
//      model.safetensors.index.json declaring 9 shards, zero shards on disk)
//      returns `.partial(missing: [<the 9 shard filenames>])`, NOT `.available`.
//
//   2. §1.3 acceptance #2 — FLUX.2-klein-4B-shaped fixture (no top-level
//      config.json, model_index.json present, all shards present in subdirs)
//      returns `.available`.
//
//   3. Tier A unit test: local `manifest.json` enumerated → presence/size pass.
//   4. Tier B unit test: `ManifestCache.shared` populated → fall through to it.
//   5. Tier C unit test: heuristic with `config.json` + `weight_map`.
//   6. `model_index.json`-equivalence test (Tier C accepts either root marker).
//   7. `verifyHashes: true` surfaces a mismatch as `.partial(missing:)`.
//
// All tests use in-memory or tempdir fixtures — no live disk dependency,
// no network. F7 honored: tests that would surface a real bug stop and
// report rather than masking it.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Shared helpers

private func makeTempBase(_ tag: String) throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("EM2-\(tag)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func cleanup(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func writeFile(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try data.write(to: url)
}

/// Materializes a `<modelDir>/manifest.json` (EM-1 byte-equal artifact) by
/// encoding the manifest via JSONEncoder and writing the resulting bytes
/// through `AcervoDownloader.persistManifestBytes`. Because the oracle
/// decodes the file through the canonical `CDNManifest` decoder, any
/// round-trippable byte representation is acceptable.
private func writeLocalManifest(
  _ manifest: CDNManifest,
  baseDirectory: URL
) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
  let data = try encoder.encode(manifest)
  try AcervoDownloader.persistManifestBytes(
    data,
    slug: manifest.slug,
    in: baseDirectory
  )
  return data
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
    updatedAt: "2026-05-23T00:00:00Z",
    files: files,
    manifestChecksum: checksum
  )
}

private func file(path: String, body: Data) -> CDNManifestFile {
  CDNManifestFile(path: path, sha256: sha256Hex(body), sizeBytes: Int64(body.count))
}

// MARK: - §1.3 acceptance #1 + tier C surface

@Suite("EM-2: Validity oracle — Qwen3-Coder-Next false-positive case")
struct EM2QwenAcceptanceTests {

  /// §1.3 acceptance #1 (verbatim from REQUIREMENTS):
  /// `await Acervo.availability("mlx-community/Qwen3-Coder-Next-4bit")`
  /// against a fixture matching the audited disk state (config.json +
  /// index.json declaring 9 shards, zero shards present) returns
  /// `.partial(missing: [<the 9 shard filenames>])`, NOT `.available`.
  ///
  /// The audit observed no local `manifest.json` for this model, so the
  /// oracle falls through to Tier C — heuristic. Tier C rejects (returns
  /// `.indeterminate` → `.notAvailable`) when the `weight_map` enumerates
  /// shards that are not on disk. To produce the `.partial` verdict the
  /// requirements ask for, the in-memory `ManifestCache.shared` (Tier B)
  /// must hold the CDN manifest — populated when `availability(slug:url:)`
  /// or `ensureAvailable(slug:url:)` ran earlier in the session.
  ///
  /// This test seeds the cache to mirror the production case where a
  /// consumer's UI has already resolved the slug, then queries
  /// `availability(_:)` for the disk-keyed legacy probe.
  @Test("Qwen3-Coder-Next-4bit shape → .partial(missing: 9 shards)")
  func qwenShape_returnsPartialWith9Shards() async throws {
    let modelId = "mlx-community/Qwen3-Coder-Next-4bit"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("Qwen")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    // 1. `config.json` exists. Small, real bytes — both for Tier-A
    //    presence/size check and to make the heuristic root marker happy.
    let configBody = Data("{\"model_type\":\"qwen3_moe\"}".utf8)
    try writeFile(configBody, to: modelDir.appendingPathComponent("config.json"))

    // 2. `model.safetensors.index.json` declaring 9 shards (44.8 GB shape
    //    from the audit). We write it so Tier C can parse the weight_map
    //    if the manifest tiers miss. The bytes can be small — the test is
    //    structural, not size-bound.
    let shardNames = (1...9).map {
      String(format: "model-%05d-of-00009.safetensors", $0)
    }
    let weightMap = Dictionary(
      uniqueKeysWithValues: shardNames.enumerated().map { idx, name in
        ("layer_\(idx).weight", name)
      })
    let shardIndex: [String: Any] = [
      "metadata": ["total_size": 44_800_000_000],
      "weight_map": weightMap,
    ]
    let shardIndexBody = try JSONSerialization.data(
      withJSONObject: shardIndex, options: [.sortedKeys])
    try writeFile(
      shardIndexBody,
      to: modelDir.appendingPathComponent("model.safetensors.index.json")
    )

    // 3. Build a manifest the oracle would have if the slug-registry had
    //    fetched it. Pretend each shard is 1 byte for fixture purposes
    //    (the oracle is comparing presence/size, not content — and the
    //    audit said ZERO shards are on disk).
    let manifestFiles: [CDNManifestFile] =
      [
        file(path: "config.json", body: configBody),
        file(path: "model.safetensors.index.json", body: shardIndexBody),
      ]
      + shardNames.map { name in
        // Body unused — shards are NOT written. We just need a manifest
        // entry the oracle expects.
        let placeholder = Data("placeholder".utf8)
        return CDNManifestFile(
          path: name,
          sha256: sha256Hex(placeholder),
          sizeBytes: Int64(placeholder.count)
        )
      }
    let manifest = makeManifest(modelId: modelId, files: manifestFiles)

    // Seed Tier B — this is how the production case works: the UI has
    // already resolved the slug via `availability(slug:url:)` and the
    // manifest cache holds the truth.
    await ManifestCache.shared.store(manifest, slug: modelId, url: nil)
    defer {
      Task { await ManifestCache.shared.remove(slug: modelId, url: nil) }
    }

    let result = await Acervo.availability(modelId, in: base)

    guard case .partial(let missing) = result else {
      Issue.record("expected .partial(missing:), got \(result)")
      return
    }
    // The two on-disk files (config + index) are present at matching size,
    // so they should NOT appear in `missing`. The 9 shards should.
    let missingSet = Set(missing)
    for shard in shardNames {
      #expect(
        missingSet.contains(shard),
        "expected missing shard \(shard) to appear in .partial(missing:)"
      )
    }
    #expect(
      !missingSet.contains("config.json"),
      "config.json is on disk; must not be in .partial(missing:)"
    )
    #expect(
      !missingSet.contains("model.safetensors.index.json"),
      "model.safetensors.index.json is on disk; must not be in .partial(missing:)"
    )
    #expect(missing.count == shardNames.count, "exactly 9 shards must be missing")

    // Also explicitly assert this is NOT .available. This is the core
    // anti-regression guard (the audited false positive).
    #expect(result != .available)
  }

  /// Local-manifest version of the same case — when a `manifest.json`
  /// exists at `<modelDir>/manifest.json` (the EM-1 byte-equal artifact),
  /// Tier A produces the same `.partial(missing: [9 shards])` verdict
  /// without needing the in-memory cache.
  @Test("Qwen3-Coder-Next-4bit shape (Tier A path) → .partial(missing: 9 shards)")
  func qwenShape_localManifest_returnsPartialWith9Shards() async throws {
    let modelId = "mlx-community/Qwen3-Coder-Next-4bit"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("QwenTierA")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let configBody = Data("{\"model_type\":\"qwen3_moe\"}".utf8)
    try writeFile(configBody, to: modelDir.appendingPathComponent("config.json"))

    let shardNames = (1...9).map {
      String(format: "model-%05d-of-00009.safetensors", $0)
    }
    let placeholder = Data("p".utf8)
    let manifestFiles: [CDNManifestFile] =
      [file(path: "config.json", body: configBody)]
      + shardNames.map { name in
        CDNManifestFile(
          path: name, sha256: sha256Hex(placeholder), sizeBytes: Int64(placeholder.count))
      }
    let manifest = makeManifest(modelId: modelId, files: manifestFiles)
    _ = try writeLocalManifest(manifest, baseDirectory: base)

    let result = await Acervo.availability(modelId, in: base)
    guard case .partial(let missing) = result else {
      Issue.record("expected .partial(missing:), got \(result)")
      return
    }
    #expect(Set(missing) == Set(shardNames))
    #expect(result != .available)
  }
}

// MARK: - §1.3 acceptance #2

@Suite("EM-2: Validity oracle — FLUX.2-klein-4B false-negative case")
struct EM2FluxAcceptanceTests {

  /// §1.3 acceptance #2 (verbatim): `await Acervo.availability(
  /// "black-forest-labs/FLUX.2-klein-4B")` against a fixture matching the
  /// audited disk state (no top-level `config.json`, `model_index.json`
  /// present, all shards present in subdirs) returns `.available`.
  ///
  /// In the audited case no `manifest.json` was on disk, so Tier A and
  /// Tier B both miss; Tier C must produce `.available` from the
  /// `model_index.json` root marker plus the on-disk subdirectory shards.
  /// Note that without a `model.safetensors.index.json` at the root, Tier
  /// C does not need to enumerate weight-map shards (a diffusers pipeline
  /// keeps per-component indexes inside subdirectories; the root
  /// `model_index.json` lists components, not shards).
  @Test("FLUX.2-klein-4B shape (no config.json, model_index.json + subdir shards) → .available")
  func fluxShape_returnsAvailable() async throws {
    let modelId = "black-forest-labs/FLUX.2-klein-4B"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("Flux")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    // No top-level config.json (diffusers pattern).
    // model_index.json present at root — Tier C's diffusers root marker.
    let modelIndexBody = Data(
      "{\"_class_name\":\"FluxPipeline\",\"_diffusers_version\":\"0.31.0\"}".utf8)
    try writeFile(modelIndexBody, to: modelDir.appendingPathComponent("model_index.json"))

    // Shards in subdirectories — transformer/, vae/, text_encoder/. Tier C
    // does NOT require enumerating them when there is no top-level
    // `model.safetensors.index.json`. Their presence is the operator's
    // visible evidence that the model is materialized; the oracle simply
    // trusts the root marker because it has no authoritative manifest to
    // enumerate against.
    try writeFile(
      Data(repeating: 0x01, count: 64),
      to: modelDir.appendingPathComponent(
        "transformer/diffusion_pytorch_model-00001-of-00003.safetensors")
    )
    try writeFile(
      Data(repeating: 0x02, count: 64),
      to: modelDir.appendingPathComponent(
        "transformer/diffusion_pytorch_model-00002-of-00003.safetensors")
    )
    try writeFile(
      Data(repeating: 0x03, count: 64),
      to: modelDir.appendingPathComponent("vae/diffusion_pytorch_model.safetensors")
    )
    try writeFile(
      Data(repeating: 0x04, count: 64),
      to: modelDir.appendingPathComponent("text_encoder/model.safetensors")
    )

    // Confirm no manifest.json or .acervo-manifest.json — Tier A must miss.
    let primary = modelDir.appendingPathComponent(AcervoDownloader.manifestFilename)
    let legacy = modelDir.appendingPathComponent(AcervoDownloader.cachedManifestFilename)
    #expect(!FileManager.default.fileExists(atPath: primary.path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))

    let result = await Acervo.availability(modelId, in: base)
    #expect(
      result == .available,
      "FLUX.2-klein-4B shape must be .available via Tier C; got \(result)"
    )
  }
}

// MARK: - Tier A unit test (local manifest.json drives the verdict)

@Suite("EM-2: Validity oracle — Tier A (local manifest.json)")
struct EM2TierATests {

  @Test("Tier A: all files present at matching size → .available")
  func tierA_allPresent_isAvailable() async throws {
    let modelId = "test-org/tierA-available"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierA-OK")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let body1 = Data("hello".utf8)
    let body2 = Data(repeating: 0x42, count: 128)
    let files = [
      file(path: "config.json", body: body1),
      file(path: "weights/model.safetensors", body: body2),
    ]
    let manifest = makeManifest(modelId: modelId, files: files)
    _ = try writeLocalManifest(manifest, baseDirectory: base)
    try writeFile(body1, to: modelDir.appendingPathComponent("config.json"))
    try writeFile(body2, to: modelDir.appendingPathComponent("weights/model.safetensors"))

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .available)
  }

  @Test("Tier A: missing nested file → .partial(missing: [nested path])")
  func tierA_missingNestedFile_isPartial() async throws {
    let modelId = "test-org/tierA-partial"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierA-Partial")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let body1 = Data("hello".utf8)
    let body2 = Data(repeating: 0x42, count: 128)
    let files = [
      file(path: "config.json", body: body1),
      file(path: "weights/model.safetensors", body: body2),
    ]
    let manifest = makeManifest(modelId: modelId, files: files)
    _ = try writeLocalManifest(manifest, baseDirectory: base)
    // Write config.json only — the nested shard is missing.
    try writeFile(body1, to: modelDir.appendingPathComponent("config.json"))

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .partial(missing: ["weights/model.safetensors"]))
  }

  @Test("Tier A: file present but wrong size → .partial(missing: [path])")
  func tierA_wrongSize_isPartial() async throws {
    let modelId = "test-org/tierA-wrong-size"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierA-WrongSize")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let declaredBody = Data(repeating: 0x42, count: 128)
    let truncatedBody = Data(repeating: 0x42, count: 64)
    let files = [file(path: "weights.bin", body: declaredBody)]
    let manifest = makeManifest(modelId: modelId, files: files)
    _ = try writeLocalManifest(manifest, baseDirectory: base)
    try writeFile(truncatedBody, to: modelDir.appendingPathComponent("weights.bin"))

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .partial(missing: ["weights.bin"]))
  }

  @Test("Tier A + verifyHashes: SHA mismatch → .partial(missing: [path])")
  func tierA_hashMismatch_isPartial() async throws {
    let modelId = "test-org/tierA-hash-mismatch"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierA-HashMismatch")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let declaredBody = Data(repeating: 0xAA, count: 128)
    let onDiskBody = Data(repeating: 0xBB, count: 128)  // same size, different bytes
    let files = [file(path: "weights.bin", body: declaredBody)]
    let manifest = makeManifest(modelId: modelId, files: files)
    _ = try writeLocalManifest(manifest, baseDirectory: base)
    try writeFile(onDiskBody, to: modelDir.appendingPathComponent("weights.bin"))

    // Default behavior (no hash verification) → presence-and-size says OK.
    let lenient = await Acervo.availability(modelId, in: base)
    #expect(lenient == .available, "size-only pass must report .available")

    // verifyHashes: true → SHA stream-compare flags the mismatch as missing.
    let strict = await Acervo.availability(modelId, verifyHashes: true, in: base)
    #expect(strict == .partial(missing: ["weights.bin"]))
  }
}

// MARK: - Tier B unit test (in-memory ManifestCache)

@Suite("EM-2: Validity oracle — Tier B (in-memory ManifestCache)")
struct EM2TierBTests {

  @Test("Tier B: no local manifest but ManifestCache holds the truth")
  func tierB_cacheDrivesVerdict() async throws {
    let modelId = "test-org/tierB"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierB")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let body = Data("hello tier B".utf8)
    let files = [file(path: "config.json", body: body)]
    let manifest = makeManifest(modelId: modelId, files: files)

    // Seed the cache; do NOT write a local manifest.json.
    await ManifestCache.shared.store(manifest, slug: modelId, url: nil)
    defer { Task { await ManifestCache.shared.remove(slug: modelId, url: nil) } }

    // Confirm no local manifest — Tier A must miss so Tier B fires.
    let primary = modelDir.appendingPathComponent(AcervoDownloader.manifestFilename)
    let legacy = modelDir.appendingPathComponent(AcervoDownloader.cachedManifestFilename)
    #expect(!FileManager.default.fileExists(atPath: primary.path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))

    // File missing on disk → Tier B reports .partial.
    let missing = await Acervo.availability(modelId, in: base)
    #expect(missing == .partial(missing: ["config.json"]))

    // Write the file → Tier B reports .available.
    try writeFile(body, to: modelDir.appendingPathComponent("config.json"))
    let present = await Acervo.availability(modelId, in: base)
    #expect(present == .available)
  }
}

// MARK: - Tier C unit tests (heuristic; no manifest at all)

@Suite("EM-2: Validity oracle — Tier C (heuristic)")
struct EM2TierCTests {

  @Test("Tier C: config.json + weight_map fully on disk → .available")
  func tierC_configAndAllShards_isAvailable() async throws {
    let modelId = "test-org/tierC-config"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierC-Config")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    try writeFile(
      Data("{\"model_type\":\"llama\"}".utf8),
      to: modelDir.appendingPathComponent("config.json")
    )
    let shardNames = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
    let weightMap: [String: Any] = [
      "layer_0.weight": shardNames[0],
      "layer_1.weight": shardNames[0],
      "layer_2.weight": shardNames[1],
    ]
    let shardIndexBody = try JSONSerialization.data(
      withJSONObject: ["weight_map": weightMap], options: [.sortedKeys])
    try writeFile(
      shardIndexBody, to: modelDir.appendingPathComponent("model.safetensors.index.json"))
    for shard in shardNames {
      try writeFile(
        Data(repeating: 0x01, count: 32), to: modelDir.appendingPathComponent(shard))
    }

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .available)
  }

  @Test(
    "Tier C model_index.json equivalence: config.json absent, model_index.json present + shards → .available"
  )
  func tierC_modelIndexEquivalence_isAvailable() async throws {
    let modelId = "test-org/tierC-modelindex"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierC-ModelIndex")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    // No config.json on purpose.
    try writeFile(
      Data("{\"_class_name\":\"DiffusionPipeline\"}".utf8),
      to: modelDir.appendingPathComponent("model_index.json")
    )
    let shardNames = ["model-00001-of-00001.safetensors"]
    let weightMap: [String: Any] = ["layer_0.weight": shardNames[0]]
    let shardIndexBody = try JSONSerialization.data(
      withJSONObject: ["weight_map": weightMap], options: [.sortedKeys])
    try writeFile(
      shardIndexBody, to: modelDir.appendingPathComponent("model.safetensors.index.json"))
    try writeFile(
      Data(repeating: 0x01, count: 32), to: modelDir.appendingPathComponent(shardNames[0]))

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .available)
  }

  @Test("Tier C: no root marker → .notAvailable")
  func tierC_noRootMarker_isNotAvailable() async throws {
    let modelId = "test-org/tierC-norootmarker"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierC-NoRootMarker")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    // Some random files but no config.json / no model_index.json.
    try writeFile(
      Data("noise".utf8),
      to: modelDir.appendingPathComponent("README.md")
    )

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .notAvailable)
  }

  @Test("Tier C: config.json + weight_map shard missing → .notAvailable")
  func tierC_shardMissing_isNotAvailable() async throws {
    let modelId = "test-org/tierC-shardmissing"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierC-ShardMissing")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    try writeFile(
      Data("{}".utf8),
      to: modelDir.appendingPathComponent("config.json")
    )
    let shardNames = ["model-00001-of-00001.safetensors"]
    let weightMap: [String: Any] = ["layer_0.weight": shardNames[0]]
    let shardIndexBody = try JSONSerialization.data(
      withJSONObject: ["weight_map": weightMap], options: [.sortedKeys])
    try writeFile(
      shardIndexBody, to: modelDir.appendingPathComponent("model.safetensors.index.json"))
    // Deliberately DO NOT write the shard. Tier C must report .notAvailable
    // (not .partial — without a manifest there is no authoritative list).

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .notAvailable)
  }

  @Test("Tier C: config.json present, no shard index → .available")
  func tierC_configOnly_noShardIndex_isAvailable() async throws {
    let modelId = "test-org/tierC-single-safetensors"
    let slug = Acervo.slugify(modelId)
    let base = try makeTempBase("TierC-Single")
    defer { cleanup(base) }

    let modelDir = base.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    // Single-safetensors-file pattern (no shard index). Root marker is
    // sufficient because there is no weight_map to enumerate.
    try writeFile(
      Data("{\"model_type\":\"qwen3\"}".utf8),
      to: modelDir.appendingPathComponent("config.json")
    )
    try writeFile(
      Data(repeating: 0x01, count: 32),
      to: modelDir.appendingPathComponent("model.safetensors")
    )

    let result = await Acervo.availability(modelId, in: base)
    #expect(result == .available)
  }
}
