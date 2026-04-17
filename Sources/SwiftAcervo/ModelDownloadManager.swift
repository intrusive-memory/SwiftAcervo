// ModelDownloadManager.swift
// SwiftAcervo
//
// Actor-based orchestrator for multi-model download operations.
//
// ModelDownloadManager is a higher-level wrapper over the single-model
// `Acervo` static API and the per-model-locking `AcervoManager` actor.
// It coordinates downloads of multiple models in sequence, aggregates
// progress as cumulative bytes across the entire batch, and provides
// a disk-space validation pre-flight check.
//
// Usage:
//
//     import SwiftAcervo
//
//     // Pre-flight: confirm total bytes with the user before downloading.
//     let totalBytes = try await ModelDownloadManager.shared.validateCanDownload([
//         "mlx-community/Qwen2.5-7B-Instruct-4bit",
//         "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
//     ])
//
//     // Download, aggregating progress across all models.
//     try await ModelDownloadManager.shared.ensureModelsAvailable(
//         [
//             "mlx-community/Qwen2.5-7B-Instruct-4bit",
//             "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
//         ]
//     ) { progress in
//         print("\(progress.model): \(Int(progress.fraction * 100))%")
//     }
//
// Error semantics: catches `AcervoError`, logs diagnostic context, then
// re-throws the error unchanged. Consuming libraries can catch
// `AcervoError` and wrap to their own domain-specific error types.

import Foundation
import OSLog

/// Aggregated progress information for a multi-model download operation.
///
/// Reports cumulative byte counts across every model in the requested batch,
/// along with the currently-active model and file. This allows UI consumers
/// to render a single progress bar for the entire download operation without
/// having to manage per-model state themselves.
///
/// ```swift
/// try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { progress in
///     // progress.fraction is cumulative across all models, 0.0 -> 1.0
///     // progress.bytesDownloaded grows monotonically toward progress.bytesTotal
/// }
/// ```
public struct ModelDownloadProgress: Sendable {

  /// The model ID currently being downloaded (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  public let model: String

  /// Cumulative download progress across the entire batch, clamped to 0.0...1.0.
  ///
  /// Computed as `bytesDownloaded / bytesTotal`. Reaches 1.0 only after every
  /// requested model has finished downloading.
  public let fraction: Double

  /// Cumulative bytes downloaded across every model in the batch so far.
  public let bytesDownloaded: Int64

  /// Cumulative total bytes for every model in the batch.
  ///
  /// Summed from each model's CDN manifest `files[].sizeBytes`. Populated
  /// incrementally as each model's manifest is fetched, so this value may
  /// grow across progress callbacks for the first progress update on each
  /// model.
  public let bytesTotal: Int64

  /// The file within `model` that is currently being downloaded
  /// (e.g., "model.safetensors" or "speech_tokenizer/config.json").
  public let currentFileName: String

  /// Creates a new aggregated progress instance.
  ///
  /// - Parameters:
  ///   - model: The model ID currently being downloaded.
  ///   - fraction: Cumulative fraction (0.0 to 1.0) across the entire batch.
  ///   - bytesDownloaded: Cumulative bytes downloaded so far.
  ///   - bytesTotal: Cumulative total bytes for the entire batch.
  ///   - currentFileName: The file currently being downloaded within `model`.
  public init(
    model: String,
    fraction: Double,
    bytesDownloaded: Int64,
    bytesTotal: Int64,
    currentFileName: String
  ) {
    self.model = model
    self.fraction = fraction
    self.bytesDownloaded = bytesDownloaded
    self.bytesTotal = bytesTotal
    self.currentFileName = currentFileName
  }
}

/// Actor-based orchestrator for multi-model download operations.
///
/// `ModelDownloadManager` wraps the single-model `Acervo` API with
/// batch-level orchestration: it sequences downloads across multiple
/// models, aggregates byte-accurate progress, and provides a
/// disk-space validation pre-flight hook.
///
/// Use the shared singleton for all call sites:
///
/// ```swift
/// try await ModelDownloadManager.shared.ensureModelsAvailable(modelIds) { p in
///     updateUI(p)
/// }
/// ```
///
/// Thread safety is provided by actor isolation. Concurrent calls to
/// `ensureModelsAvailable(_:progress:)` from different tasks are serialized
/// in the order the actor dispatches them.
public actor ModelDownloadManager {

  /// The shared singleton instance.
  public static let shared = ModelDownloadManager()

  /// Logger for orchestration-level diagnostics.
  private let logger = Logger(
    subsystem: "com.intrusive-memory.SwiftAcervo",
    category: "ModelDownloadManager"
  )

  /// Private initializer to enforce singleton usage.
  private init() {}
}

// MARK: - Disk Space Validation

extension ModelDownloadManager {

  /// Returns the total number of bytes that would need to be downloaded to
  /// make every model in `modelIds` available locally.
  ///
  /// Fetches and validates the CDN manifest for each model, then sums
  /// `manifest.files[].sizeBytes` across all models. Models that are
  /// already present locally are still counted — the returned value
  /// reflects the total size of the requested models as declared on the
  /// CDN, not the incremental bytes still to transfer. This matches the
  /// intended use case of a UI pre-flight check ("This will require X GB
  /// of disk space").
  ///
  /// Manifest fetches are performed sequentially. Each request is bounded
  /// by the CDN round-trip time; on a typical connection this is O(100ms)
  /// per model.
  ///
  /// - Parameter modelIds: An array of model identifiers in "org/repo" format.
  /// - Returns: The total bytes needed across every requested model.
  /// - Throws: `AcervoError.manifestDownloadFailed`,
  ///   `AcervoError.manifestDecodingFailed`,
  ///   `AcervoError.manifestIntegrityFailed`,
  ///   `AcervoError.manifestVersionUnsupported`,
  ///   `AcervoError.manifestModelIdMismatch`, or
  ///   `AcervoError.networkError` if any manifest cannot be fetched or
  ///   validated. The error is re-thrown unchanged.
  ///
  /// ```swift
  /// let bytes = try await ModelDownloadManager.shared.validateCanDownload([
  ///     "mlx-community/Qwen2.5-7B-Instruct-4bit",
  ///     "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
  /// ])
  /// print("Will download \(bytes / (1024 * 1024)) MB")
  /// ```
  public func validateCanDownload(
    _ modelIds: [String]
  ) async throws -> Int64 {
    var totalBytes: Int64 = 0

    for modelId in modelIds {
      let manifest: CDNManifest
      do {
        manifest = try await AcervoDownloader.downloadManifest(for: modelId)
      } catch let error as AcervoError {
        logger.error(
          "validateCanDownload: manifest fetch failed for \(modelId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        throw error
      }

      let modelBytes = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
      totalBytes += modelBytes
    }

    return totalBytes
  }
}

// MARK: - Multi-Model Download Orchestration

extension ModelDownloadManager {

  /// Ensures every model in `modelIds` is downloaded and available locally,
  /// reporting aggregated progress across the entire batch.
  ///
  /// For each model ID, this method calls `Acervo.ensureAvailable(_:files:progress:)`
  /// with an empty files array, which downloads all files in the model's CDN
  /// manifest (if the model is not already present). Models that are already
  /// available locally are skipped — their byte totals are counted toward
  /// the aggregate total and credited as fully downloaded immediately.
  ///
  /// Progress reporting aggregates bytes across every model in the batch:
  ///
  /// - `bytesTotal` is the cumulative sum of all models' manifest file sizes.
  /// - `bytesDownloaded` is the cumulative sum of all bytes transferred so far,
  ///   including bytes credited for already-local models.
  /// - `fraction` is `bytesDownloaded / bytesTotal`, clamped to 0.0...1.0.
  ///
  /// To produce a stable cumulative `bytesTotal` from the first callback, this
  /// method fetches and validates every model's manifest before starting any
  /// downloads. This is the same cost as the manifest fetch that
  /// `Acervo.ensureAvailable` would incur during download setup, but it runs
  /// up-front so progress reporting is consistent.
  ///
  /// Downloads are performed sequentially, one model at a time. Within a single
  /// model, `AcervoDownloader` may parallelize individual file downloads. Per-model
  /// locking inside `Acervo` ensures that concurrent calls to
  /// `ensureModelsAvailable` do not race on the same model.
  ///
  /// Errors from the underlying `Acervo` API (`AcervoError`) are logged with
  /// diagnostic context (the offending model ID) and then re-thrown unchanged.
  /// Downloads for subsequent models in the batch are not attempted after a
  /// failure.
  ///
  /// - Parameters:
  ///   - modelIds: An array of model identifiers in "org/repo" format.
  ///   - progress: A `@Sendable` closure invoked with cumulative progress
  ///     updates for the entire batch. Called on the actor's executor.
  /// - Throws: Any `AcervoError` thrown by manifest fetch, directory creation,
  ///   network failure, size mismatch, or integrity verification, re-thrown
  ///   unchanged. `AcervoError.invalidModelId` if any ID is malformed.
  ///
  /// ```swift
  /// try await ModelDownloadManager.shared.ensureModelsAvailable(
  ///     ["mlx-community/Qwen2.5-7B-Instruct-4bit"]
  /// ) { progress in
  ///     print("\(progress.model) — \(progress.currentFileName): \(progress.fraction)")
  /// }
  /// ```
  public func ensureModelsAvailable(
    _ modelIds: [String],
    progress: @escaping @Sendable (ModelDownloadProgress) -> Void
  ) async throws {
    // No-op for empty input.
    guard !modelIds.isEmpty else {
      return
    }

    // Step 1: Fetch every manifest so we know the cumulative `bytesTotal`
    // before the first progress callback fires. This is the same cost as
    // the manifest fetch `Acervo.ensureAvailable` does during download
    // setup — we simply front-load it.
    //
    // Keep a per-model size map so we can report progress in terms of
    // prior-models-completed-bytes + current-model-partial-bytes.
    var modelSizes: [String: Int64] = [:]
    var totalBytes: Int64 = 0

    for modelId in modelIds {
      let manifest: CDNManifest
      do {
        manifest = try await AcervoDownloader.downloadManifest(for: modelId)
      } catch let error as AcervoError {
        logger.error(
          "ensureModelsAvailable: manifest fetch failed for \(modelId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        throw error
      }

      let modelBytes = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
      modelSizes[modelId] = modelBytes
      totalBytes += modelBytes
    }

    // Step 2: Download each model in sequence. Within each model, the
    // Acervo progress callback reports a per-model fraction via
    // `overallProgress` (clamped to 0.0...1.0 for that model). We convert
    // that to cumulative bytes by multiplying by the model's size and
    // adding the bytes already credited to prior models.
    var bytesCompletedPriorModels: Int64 = 0

    for modelId in modelIds {
      let modelBytes = modelSizes[modelId] ?? 0
      let priorBytes = bytesCompletedPriorModels
      let aggregateTotal = totalBytes

      // Bridge the single-model Acervo progress callback to our aggregated
      // batch-level callback. Capture by value so the closure is Sendable.
      let bridged: @Sendable (AcervoDownloadProgress) -> Void = { inner in
        // Per-model fraction, 0.0...1.0. `overallProgress` already respects
        // the byte-accurate override set by `AcervoDownloader.downloadFiles()`.
        let modelFraction = inner.overallProgress
        let modelBytesDone = Int64(Double(modelBytes) * modelFraction)
        let cumulativeBytes = priorBytes + modelBytesDone

        let cumulativeFraction: Double
        if aggregateTotal > 0 {
          cumulativeFraction = min(
            max(Double(cumulativeBytes) / Double(aggregateTotal), 0.0),
            1.0
          )
        } else {
          cumulativeFraction = 0.0
        }

        progress(
          ModelDownloadProgress(
            model: modelId,
            fraction: cumulativeFraction,
            bytesDownloaded: cumulativeBytes,
            bytesTotal: aggregateTotal,
            currentFileName: inner.fileName
          ))
      }

      do {
        // Empty files array -> download all files in the manifest.
        try await Acervo.ensureAvailable(modelId, files: [], progress: bridged)
      } catch let error as AcervoError {
        logger.error(
          "ensureModelsAvailable: download failed for \(modelId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        throw error
      }

      // Credit this model's full byte count toward the prior-models total
      // and emit a final 100%-of-this-model progress event so the caller
      // sees a clean transition between models (important when the next
      // model's first chunk hasn't fired yet, or when a model was already
      // local and `Acervo.ensureAvailable` returned without invoking the
      // progress callback at all).
      bytesCompletedPriorModels += modelBytes

      let finalCumulativeFraction: Double
      if totalBytes > 0 {
        finalCumulativeFraction = min(
          max(Double(bytesCompletedPriorModels) / Double(totalBytes), 0.0),
          1.0
        )
      } else {
        finalCumulativeFraction = 0.0
      }

      progress(
        ModelDownloadProgress(
          model: modelId,
          fraction: finalCumulativeFraction,
          bytesDownloaded: bytesCompletedPriorModels,
          bytesTotal: totalBytes,
          currentFileName: ""
        ))
    }
  }
}
