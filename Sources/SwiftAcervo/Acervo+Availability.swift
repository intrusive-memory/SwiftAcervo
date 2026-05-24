// Acervo+Availability.swift
// SwiftAcervo
//
// Combines the legacy cached availability API and the EM-2 three-state
// availability API; both consume `ValidityOracle`.
//
// Both sections are repo-keyed availability semantics — they answer
// "is this model available on disk?" using different levels of
// strictness and fidelity:
//
//   §3 — Legacy / cached availability (synchronous, offline)
//        isModelAvailable(_:)           public  — strict, manifest-driven
//        isModelAvailable(_:in:)        internal — strict, test seam (also
//                                                  called by ensureAvailable)
//        isModelConfigPresent(_:)       public  — loose, config.json probe only
//        isModelConfigPresent(_:in:)    internal — loose, test seam
//        modelFileExists(_:fileName:)   public  — single-file existence probe
//        modelFileExists(_:fileName:in:) internal — test seam
//
//   §20 — Three-state availability (async, EM-2 ValidityOracle)
//        availability(_:verifyHashes:)  public  — full three-tier oracle
//        availability(_:verifyHashes:in:) internal — test seam

import Foundation

// MARK: - Legacy Availability

extension Acervo {

  /// Returns `true` when the model is **fully on disk and usable**, anchored
  /// against its cached CDN manifest.
  ///
  /// The check is strict and offline:
  ///
  /// 1. Load the manifest cached at
  ///    `{sharedModelsDirectory}/{slug}/.acervo-manifest.json`. If the
  ///    cached manifest is missing or fails its self-checksum, the method
  ///    returns `false`.
  /// 2. For every file declared in that manifest, verify the on-disk file
  ///    exists at the recorded byte size. Short-circuits on the first miss.
  ///
  /// This means a model directory containing only `config.json` (without a
  /// manifest cache, or with files smaller than the manifest declares) is
  /// **not** considered available — that state indicates a previous
  /// download that did not run to completion.
  ///
  /// This method never throws and never performs network I/O. For an
  /// "is the file just there?" probe that does not require a manifest, see
  /// `isModelConfigPresent(_:)` (the legacy loose check).
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format (e.g.,
  ///   "mlx-community/Qwen2.5-7B-Instruct-4bit").
  /// - Returns: `true` only if the cached manifest exists, self-validates,
  ///   and every file it declares is on disk at the recorded size.
  ///
  /// ```swift
  /// if Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit") {
  ///     print("Model is ready to use")
  /// }
  /// ```
  public static func isModelAvailable(_ modelId: String) -> Bool {
    isModelAvailable(modelId, in: sharedModelsDirectory)
  }

  /// Strict, manifest-driven availability check against a custom base
  /// directory.
  ///
  /// Internal overload used by tests and by `ensureAvailable(_:in:)`. As
  /// of EM-2 this is intentionally kept STRICTER than the
  /// consumer-facing `availability(_:)` oracle: only Tier A (the EM-1
  /// byte-equal `<modelDir>/manifest.json`, with the legacy
  /// `.acervo-manifest.json` self-validating cache as a transitional
  /// fallback) is consulted. The Tier-C heuristic is deliberately NOT
  /// used here because it can flip `ensureAvailable`'s fast-path
  /// short-circuit on for a model that just had a partial download
  /// failure — the consumer expects the retry to try downloading again,
  /// not to silently accept a `config.json`-only stub as "available".
  ///
  /// `availability(_:)` (the public async read API) DOES use the full
  /// three-tier oracle including Tier C for the spec's false-negative
  /// fix. Consumers that probe with `availability(_:)` will see
  /// `.available` for a `config.json`-only model (Tier C); consumers
  /// that re-invoke `ensureAvailable` after a failure will still see
  /// the strict cached-manifest verdict here and re-attempt the
  /// download.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - baseDirectory: The base directory to check for the model.
  /// - Returns: `true` only when an authoritative local manifest is
  ///   present and every declared file is on disk at the recorded size.
  static func isModelAvailable(_ modelId: String, in baseDirectory: URL) -> Bool {
    let slug = slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    guard
      let manifest = ValidityOracle.loadLocalManifestEitherShape(
        modelId: modelId,
        modelDir: modelDir,
        baseDirectory: baseDirectory
      )
    else {
      return false
    }
    return IntegrityVerification.allManifestFilesPresentBySize(
      manifest: manifest,
      in: modelDir
    )
  }

  /// Returns `true` when the model's `config.json` is present at the model
  /// root.
  ///
  /// **Warning:** Does NOT imply "model is usable." A directory containing
  /// only `config.json` (or a partial download) will satisfy this probe even
  /// though weights, tokenizer, and other declared files may be missing.
  /// Prefer `availability(_:)` or `isModelAvailable(_:)` for production use.
  /// This method exists as an explicit escape hatch for callers that
  /// genuinely only want to probe for `config.json` — for example, legacy
  /// integrations that pre-date the manifest cache.
  ///
  /// Never throws and never performs network I/O.
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format.
  /// - Returns: `true` iff `{sharedModelsDirectory}/{slug}/config.json`
  ///   exists.
  public static func isModelConfigPresent(_ modelId: String) -> Bool {
    guard let dir = try? modelDirectory(for: modelId) else {
      return false
    }
    let configPath = dir.appendingPathComponent("config.json").path
    return FileManager.default.fileExists(atPath: configPath)
  }

  /// Custom-base-directory overload of `isModelConfigPresent(_:)`.
  ///
  /// Internal test seam mirroring the public method's behavior against an
  /// arbitrary base directory.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - baseDirectory: The base directory to check.
  /// - Returns: `true` iff `{baseDirectory}/{slug}/config.json` exists.
  static func isModelConfigPresent(_ modelId: String, in baseDirectory: URL) -> Bool {
    let slug = slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    let configPath = modelDir.appendingPathComponent("config.json").path
    return FileManager.default.fileExists(atPath: configPath)
  }

  /// Checks whether a specific file exists within a model's directory.
  ///
  /// Supports files in subdirectories (e.g., "speech_tokenizer/config.json").
  /// This method never throws. If the model ID is invalid or the model
  /// directory does not exist, it returns `false`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format (e.g., "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16").
  ///   - fileName: The file name or relative path within the model directory
  ///     (e.g., "tokenizer.json" or "speech_tokenizer/config.json").
  /// - Returns: `true` if the file exists at the expected location.
  ///
  /// ```swift
  /// let hasTokenizer = Acervo.modelFileExists(
  ///     "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
  ///     fileName: "speech_tokenizer/config.json"
  /// )
  /// ```
  public static func modelFileExists(_ modelId: String, fileName: String) -> Bool {
    guard let dir = try? modelDirectory(for: modelId) else {
      return false
    }
    let filePath = dir.appendingPathComponent(fileName).path
    return FileManager.default.fileExists(atPath: filePath)
  }

  /// Checks whether a specific file exists within a model's directory,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func modelFileExists(
    _ modelId: String,
    fileName: String,
    in baseDirectory: URL
  ) -> Bool {
    let slug = slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    let filePath = modelDir.appendingPathComponent(fileName).path
    return FileManager.default.fileExists(atPath: filePath)
  }

  // MARK: - Three-State Availability

  /// Returns the three-state availability of the specified model.
  ///
  /// This is the canonical "is the model usable right now?" surface.
  /// As of EM-2 it routes through the three-tier validity oracle:
  ///
  ///   - Tier A: local byte-equal `<modelDir>/manifest.json` (or, for
  ///     pre-EM-1 downloads, the legacy `.acervo-manifest.json` cache).
  ///   - Tier B: in-memory CDN manifest cache from the slug-registry
  ///     work (populated by `availability(slug:url:)` /
  ///     `ensureAvailable(slug:url:)`).
  ///   - Tier C: heuristic — `config.json` OR `model_index.json`
  ///     present, AND every shard enumerated in
  ///     `model.safetensors.index.json`'s `weight_map` is on disk.
  ///
  /// When the oracle has an authoritative manifest (Tier A or B) but
  /// at least one declared file is missing or wrong-size, the method
  /// returns `.partial(missing: [...])` rather than `.available` or
  /// `.notAvailable`. This is the audited false-positive case
  /// (Qwen3-Coder-Next-4bit with `config.json` + a shard index but
  /// zero shards on disk).
  ///
  /// When the Tier-C heuristic confirms a model without a manifest
  /// (the FLUX.2 false-negative case: `model_index.json` plus all
  /// subdirectory shards present), the method returns `.available`.
  ///
  /// The in-flight download registry is consulted first: a download
  /// in progress always wins over disk state.
  ///
  /// This method never throws and never performs network I/O.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - verifyHashes: When `true`, after the presence-and-size pass
  ///     succeeds the oracle stream-SHA-256 each manifest file and
  ///     treats any mismatch as effectively missing. Default `false`.
  ///     Hash verification streams files in 4 MB chunks via
  ///     `CryptoKit.SHA256` and `FileHandle`, but the wall-clock cost is
  ///     proportional to total bytes on disk — multi-minute on a 22 GB
  ///     model. Reserve for explicit bit-rot audits, not interactive
  ///     UI use.
  /// - Returns: `.available`, `.downloading(progress:)`,
  ///   `.partial(missing: [...])`, or `.notAvailable`.
  public static func availability(
    _ modelId: String,
    verifyHashes: Bool = false
  ) async -> ModelAvailability {
    await availability(
      modelId,
      verifyHashes: verifyHashes,
      in: sharedModelsDirectory
    )
  }

  /// Custom-base-directory overload of `availability(_:verifyHashes:)`.
  ///
  /// Internal test seam mirroring the public method's behavior against
  /// an arbitrary base directory. Not annotated `public` so it does
  /// not widen the API surface.
  static func availability(
    _ modelId: String,
    verifyHashes: Bool = false,
    in baseDirectory: URL
  ) async -> ModelAvailability {
    // Observe the in-flight registry first: a download in progress wins
    // over any partial bytes that may already be on disk. The registry
    // is the sole source of `.downloading`-ness — a `.part` file with
    // no registered Task is treated as one of the oracle verdicts.
    if await InFlightDownloads.shared.contains(modelId) {
      let p = await InFlightDownloads.shared.progress(for: modelId) ?? 0.0
      return .downloading(progress: p)
    }

    let verdict = await ValidityOracle.evaluate(
      modelId: modelId,
      in: baseDirectory,
      verifyHashes: verifyHashes
    )
    switch verdict {
    case .available:
      return .available
    case .partial(let missing):
      return .partial(missing: missing)
    case .indeterminate:
      return .notAvailable
    }
  }
}
