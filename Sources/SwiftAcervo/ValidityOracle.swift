// ValidityOracle.swift
// SwiftAcervo
//
// EM-2: Manifest-driven validity oracle. Replaces the presence-only
// `config.json` check with a three-tier algorithm:
//
//   Tier A — Local `manifest.json` (REQUIREMENTS §2 byte-equal artifact)
//     exists at `<model-dir>/manifest.json`. Verify every entry in
//     `files` exists on disk at the recorded size. If `verifyHashes`
//     is true, additionally stream-SHA-256 each file and compare to the
//     manifest's recorded hash; any mismatch is treated as effectively
//     missing.
//
//   Tier B — No local `manifest.json`. Consult the in-memory CDN
//     manifest cache (`ManifestCache.shared`) populated by the
//     slug-registry work (`availability(slug:url:)` /
//     `ensureAvailable(slug:url:)`). When present, apply the same
//     presence-and-size pass as Tier A.
//
//   Tier C — No manifest reachable at all. Last-resort heuristic:
//     `model_index.json` OR `config.json` present at the model root,
//     AND every file enumerated in `model.safetensors.index.json`'s
//     `weight_map` values is on disk. (Sizes are not declared in
//     `safetensors.index.json` so this tier is presence-only by
//     design.)
//
// The oracle returns one of:
//   - `.available`  — every required file is on disk (and, if
//     `verifyHashes`, all hashes match).
//   - `.partial(missing: [String])` — Tier A or Tier B had a manifest
//     but at least one declared file is missing / wrong-size /
//     wrong-hash. The array is the list of manifest-relative POSIX
//     paths the oracle expected.
//   - `.notAvailable` — no manifest reachable AND the heuristic
//     fallback could not confirm the model.
//
// Hash verification (`verifyHashes: true`) is opt-in because computing
// SHA-256 over 22 GB+ models is multi-minute work; the size-only pass
// is the default for interactive UI use.

import CryptoKit
import Foundation

/// Internal helper that implements EM-2's three-tier manifest-driven
/// validity oracle.
enum ValidityOracle {

  /// The result of one oracle evaluation. Mapped directly to
  /// `ModelAvailability` by the public API:
  ///
  ///   - `.available`    → `.available`
  ///   - `.partial(_)`   → `.partial(missing:)`
  ///   - `.indeterminate` → caller decides (`.notAvailable` in the
  ///     legacy code path; some callers may treat indeterminate as
  ///     "skip the fast path and try downloading anyway").
  enum Verdict: Equatable {
    /// Every file the oracle could enumerate is on disk at the
    /// recorded size (and, when requested, hash).
    case available
    /// The oracle had a manifest (Tier A or Tier B) but at least one
    /// declared file is missing or its size/hash does not match.
    /// `missing` preserves the manifest's declaration order.
    case partial(missing: [String])
    /// No manifest is reachable AND the Tier-C heuristic could not
    /// produce a "yes". Callers map this to `.notAvailable`.
    case indeterminate
  }

  /// Runs the full three-tier oracle for `modelId` against
  /// `baseDirectory`.
  ///
  /// `baseDirectory` is the shared-models root (e.g. the value of
  /// `Acervo.sharedModelsDirectory`); the model's on-disk directory is
  /// derived as `baseDirectory / slugify(modelId)`.
  ///
  /// Tier order:
  ///   - Tier A: local `<modelDir>/manifest.json` (EM-1 byte-equal
  ///     artifact). Legacy `.acervo-manifest.json` is consulted as a
  ///     transitional fallback for pre-EM-1 downloads.
  ///   - Tier B: in-memory `ManifestCache.shared` (async actor read).
  ///   - Tier C: `config.json` OR `model_index.json` + `weight_map`
  ///     heuristic.
  ///
  /// When `verifyHashes` is true, after the Tier-A / Tier-B
  /// presence-and-size pass succeeds the oracle stream-SHA-256 each
  /// declared file and treats any mismatch as effectively missing.
  /// This is multi-minute work on multi-gigabyte models; the default
  /// is `false`.
  static func evaluate(
    modelId: String,
    in baseDirectory: URL,
    verifyHashes: Bool = false
  ) async -> Verdict {
    let slug = Acervo.slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)

    // Tier A: local <model-dir>/manifest.json (REQUIREMENTS §2 invariant)
    // with the legacy `.acervo-manifest.json` cache as a transitional
    // fallback for pre-EM-1 models.
    if let manifest = loadLocalManifestEitherShape(
      modelId: modelId,
      modelDir: modelDir,
      baseDirectory: baseDirectory
    ) {
      return verdict(
        for: manifest,
        modelDir: modelDir,
        verifyHashes: verifyHashes
      )
    }

    // Tier B: in-memory CDN manifest cache from the slug-registry work.
    if let cached = await ManifestCache.shared.manifest(slug: modelId, url: nil) {
      return verdict(
        for: cached,
        modelDir: modelDir,
        verifyHashes: verifyHashes
      )
    }

    // Tier C: heuristic — config.json OR model_index.json present, AND
    // every shard enumerated in `model.safetensors.index.json` on disk.
    return heuristicVerdict(modelDir: modelDir)
  }

  /// Synchronous variant of `evaluate(modelId:in:verifyHashes:)` that
  /// skips Tier B (the `async` in-memory `ManifestCache.shared` read).
  ///
  /// Used by `Acervo.isModelAvailable(_:in:)` — a synchronous helper
  /// invoked from `ensureAvailable`'s fast-path and many existing
  /// tests. Crossing an actor boundary from synchronous code requires
  /// a semaphore bridge that risks deadlock inside an actor's executor,
  /// so we deliberately omit Tier B here. Async callers should use
  /// `evaluate(modelId:in:verifyHashes:)` for full three-tier coverage.
  static func evaluateSynchronous(
    modelId: String,
    in baseDirectory: URL,
    verifyHashes: Bool = false
  ) -> Verdict {
    let slug = Acervo.slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)

    if let manifest = loadLocalManifestEitherShape(
      modelId: modelId,
      modelDir: modelDir,
      baseDirectory: baseDirectory
    ) {
      return verdict(
        for: manifest,
        modelDir: modelDir,
        verifyHashes: verifyHashes
      )
    }
    return heuristicVerdict(modelDir: modelDir)
  }

  // MARK: - Tier A / Tier B common path

  /// Computes the verdict for a known manifest. Shared by Tier A and
  /// Tier B; they differ only in where the manifest comes from.
  ///
  /// The presence-and-size pass collects every missing file (preserving
  /// the manifest's declaration order), not just the first. This lets
  /// the consumer surface the full gap in one UI tick.
  ///
  /// When `verifyHashes` is true and all files passed presence/size,
  /// each file is stream-hashed and any mismatch is appended to the
  /// missing list (treated as effectively absent: the consumer's
  /// recovery is the same — re-download).
  private static func verdict(
    for manifest: CDNManifest,
    modelDir: URL,
    verifyHashes: Bool
  ) -> Verdict {
    var missing: [String] = []
    for file in manifest.files {
      if !IntegrityVerification.fileMatchesManifestEntry(file, in: modelDir) {
        missing.append(file.path)
      }
    }
    guard missing.isEmpty else {
      return .partial(missing: missing)
    }

    if verifyHashes {
      for file in manifest.files {
        let url = modelDir.appendingPathComponent(file.path)
        // Streaming SHA-256 via CryptoKit + FileHandle chunked reads;
        // shares `IntegrityVerification.sha256(of:)` so the algorithm
        // matches what the downloader uses.
        guard let actual = try? IntegrityVerification.sha256(of: url) else {
          missing.append(file.path)
          continue
        }
        if actual != file.sha256 {
          missing.append(file.path)
        }
      }
      if !missing.isEmpty {
        return .partial(missing: missing)
      }
    }

    return .available
  }

  /// Loads `<modelDir>/manifest.json` if present and decodable. The
  /// EM-1 byte-equal artifact is preferred; if it is absent we fall
  /// back to the legacy `.acervo-manifest.json` self-validating cache
  /// (read via `AcervoDownloader.loadCachedManifest`) so pre-EM-1
  /// downloads do not regress.
  ///
  /// Returns `nil` only when neither artifact yields a decodable
  /// manifest; in that case Tier A passes through to Tier B/C.
  static func loadLocalManifestEitherShape(
    modelId: String,
    modelDir: URL,
    baseDirectory: URL
  ) -> CDNManifest? {
    let primary = modelDir.appendingPathComponent(AcervoDownloader.manifestFilename)
    if let data = try? Data(contentsOf: primary),
      let manifest = try? JSONDecoder().decode(CDNManifest.self, from: data)
    {
      return manifest
    }
    // Legacy fallback — the EM-1 plan notes the hidden cache file is
    // retained for backward compatibility.
    return AcervoDownloader.loadCachedManifest(for: modelId, in: baseDirectory)
  }

  // MARK: - Tier C: presence-only heuristic

  /// Heuristic verdict when no manifest is reachable.
  ///
  /// `model_index.json` (diffusers pipelines) OR `config.json`
  /// (transformers / MLX) must be at the model root. The check then
  /// depends on the detected layout:
  ///
  ///   • **Root `model.safetensors.index.json` present** (non-diffusers or
  ///     diffusers with an unusual root index): every shard declared in its
  ///     `weight_map` must be on disk.
  ///
  ///   • **Diffusers layout** (`model_index.json` present AND no root shard
  ///     index): enumerate component subdirs that carry their own
  ///     `model.safetensors.index.json` (e.g. `transformer/`, `vae/`,
  ///     `text_encoder/`). For each such subdir, every declared shard must
  ///     be on disk. If any shard is absent, or the subdir index is empty /
  ///     malformed, returns `.indeterminate` (R5: never `.available` when
  ///     completeness cannot be positively confirmed).
  ///
  ///   • **Non-diffusers, no root shard index**: root marker alone is
  ///     sufficient (single-safetensors-file models, MLX 4-bit packs, etc.).
  ///
  /// Sizes are not declared in shard index files, so this tier is
  /// presence-only by design. Tier C is intentionally NOT a path to
  /// `.partial` because without a manifest the oracle has no authoritative
  /// "should be there" list to enumerate.
  private static func heuristicVerdict(modelDir: URL) -> Verdict {
    let fm = FileManager.default

    // Root-marker check: either `model_index.json` (diffusers) or
    // `config.json` (transformers / MLX) must be present.
    let modelIndexURL = modelDir.appendingPathComponent("model_index.json")
    let configURL = modelDir.appendingPathComponent("config.json")
    let hasDiffusersMarker = fm.fileExists(atPath: modelIndexURL.path)
    let hasRootMarker =
      hasDiffusersMarker || fm.fileExists(atPath: configURL.path)
    guard hasRootMarker else { return .indeterminate }

    // Layout-sensitive weight-map check.
    //
    // When `model.safetensors.index.json` is present at the root, every
    // shard it enumerates must be on disk (same for both layouts).
    //
    // When it is NOT present, the detected layout drives the next check:
    //   • Diffusers (`model_index.json` present, no root shard index) →
    //     descend into component subdirs (C2 · R5).
    //   • Non-diffusers (root marker = config.json only, no root shard
    //     index) → root marker alone is sufficient.
    let shardIndexURL = modelDir.appendingPathComponent("model.safetensors.index.json")
    let hasRootShardIndex = fm.fileExists(atPath: shardIndexURL.path)

    if hasDiffusersMarker && !hasRootShardIndex {
      // Diffusers / multi-folder layout: verify component-subdir shards.
      return heuristicVerdictForDiffusers(modelDir: modelDir)
    }

    guard hasRootShardIndex else {
      // Non-diffusers, no root shard index: root marker is sufficient.
      return .available
    }

    // Root `model.safetensors.index.json` present — every shard must be on disk.
    // `weight_map` MUST be present + non-empty when the index file is
    // present; an empty / malformed index is treated as indeterminate
    // (we can't confirm anything from it).
    let shards = parseWeightMapShards(at: shardIndexURL)
    guard !shards.isEmpty else {
      return .indeterminate
    }
    for shard in shards {
      let shardURL = modelDir.appendingPathComponent(shard)
      if !fm.fileExists(atPath: shardURL.path) {
        return .indeterminate
      }
    }
    return .available
  }

  /// Heuristic verdict for the diffusers / multi-folder layout:
  /// `model_index.json` present AND no root `model.safetensors.index.json`.
  ///
  /// Enumerates all immediate subdirectories of `modelDir` that carry their
  /// own `model.safetensors.index.json`. For each such subdir, every shard
  /// declared in `weight_map` must exist on disk; otherwise returns
  /// `.indeterminate` (R5: never `.available` when completeness cannot be
  /// positively confirmed).
  ///
  /// If no subdirectory carries a shard index, the `model_index.json` root
  /// marker is taken as sufficient and `.available` is returned — this
  /// preserves backward compatibility with diffusers fixtures that store
  /// shards without a per-component shard index file.
  private static func heuristicVerdictForDiffusers(modelDir: URL) -> Verdict {
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(
      at: modelDir,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: .skipsHiddenFiles
    ) else {
      // Cannot read the directory → cannot confirm completeness.
      return .indeterminate
    }
    for entry in contents {
      // Consider only subdirectories.
      guard
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true
      else {
        continue
      }
      let subdirShardIndex = entry.appendingPathComponent("model.safetensors.index.json")
      guard fm.fileExists(atPath: subdirShardIndex.path) else { continue }
      // This component subdir carries its own shard index — verify every
      // declared shard is present on disk.
      let shards = parseWeightMapShards(at: subdirShardIndex)
      guard !shards.isEmpty else {
        // Index present but empty or malformed → cannot confirm completeness.
        return .indeterminate
      }
      for shard in shards {
        let shardURL = entry.appendingPathComponent(shard)
        if !fm.fileExists(atPath: shardURL.path) {
          return .indeterminate
        }
      }
    }
    // All indexed subdirs (if any) passed — or no indexed subdirs were found.
    return .available
  }

  /// Extracts the unique set of shard filenames from
  /// `model.safetensors.index.json`'s `weight_map`.
  ///
  /// HuggingFace's shard index format is:
  /// ```
  /// { "metadata": {...}, "weight_map": { "<layer_name>": "<shard>.safetensors", ... } }
  /// ```
  /// The values are repeated many times (one entry per layer); the
  /// helper deduplicates and returns them in deterministic order
  /// (sorted) so downstream missing-list rendering stays stable.
  private static func parseWeightMapShards(at url: URL) -> [String] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let weightMap = json["weight_map"] as? [String: Any]
    else {
      return []
    }
    var seen = Set<String>()
    for value in weightMap.values {
      if let shard = value as? String, !shard.isEmpty {
        seen.insert(shard)
      }
    }
    return seen.sorted()
  }
}
