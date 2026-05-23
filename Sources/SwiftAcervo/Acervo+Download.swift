// Acervo+Download.swift
// SwiftAcervo
//
// Legacy model download orchestration: accepts a model ID and a list of
// requested files, manages the directory creation, excludes from backup,
// and delegates the manifest fetch and per-file integrity verification
// to AcervoDownloader.
//
// This file is the public download API surface — a thin orchestration layer
// that computes paths, validates input, and wires together:
//   - Manifest fetch (via AcervoDownloader)
//   - Per-file download + integrity check (via AcervoDownloader)
//   - Telemetry lifecycle (start/complete events for reporters)
//
// Two variants live here together because they share the same contract
// ("fetch and verify files via the CDN") and participate in the same
// download deduplication registry when called through the higher-level
// `ensureAvailable(...)` façade:
//
//   §9 — download(_:files:progress:telemetry:)         public, repo-keyed (async)
//        download(_:files:progress:in:telemetry:)      internal, test-support with custom baseDirectory

import Foundation

// MARK: - Download API

extension Acervo {

  /// Downloads specific files for a model from the CDN.
  ///
  /// Validates the model ID format, fetches the CDN manifest, creates
  /// the model directory if needed, and downloads each file with
  /// per-file SHA-256 verification. Files that already exist at the
  /// destination and match the manifest size are skipped unless
  /// `force` is `true`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format
  ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - files: An array of file names or relative paths within the model
  ///     (e.g., `["config.json", "speech_tokenizer/config.json"]`).
  ///   - force: When `true`, re-downloads files even if they already exist.
  ///     Defaults to `false`.
  ///   - progress: An optional callback invoked periodically with download
  ///     progress. Must be `@Sendable` for Swift 6 strict concurrency.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   `AcervoError.directoryCreationFailed` if the model directory cannot be
  ///   created, manifest errors if the CDN manifest is invalid, or
  ///   download/verification errors from `AcervoDownloader`.
  ///
  /// ```swift
  /// try await Acervo.download(
  ///     "mlx-community/Qwen2.5-7B-Instruct-4bit",
  ///     files: ["config.json", "tokenizer.json"],
  ///     progress: { p in print("Progress: \(p.overallProgress)") }
  /// )
  /// ```
  public static func download(
    _ modelId: String,
    files: [String],
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await download(
      modelId,
      files: files,
      force: force,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Downloads specific files for a model to the specified base directory.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - files: An array of file names or relative paths within the model.
  ///   - force: When `true`, re-downloads files even if they already exist.
  ///   - progress: An optional progress callback.
  ///   - baseDirectory: The base directory to use instead of `sharedModelsDirectory`.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   or download/manifest-related errors from `AcervoDownloader`.
  static func download(
    _ modelId: String,
    files: [String],
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    // Validate model ID format (must contain exactly one "/")
    let slashCount = modelId.filter { $0 == "/" }.count
    guard slashCount == 1 else {
      throw AcervoError.invalidModelId(modelId)
    }

    // Lifecycle: snapshot wall-clock start and offline mode so the duration
    // measurement reflects the entire download operation including manifest
    // fetch and integrity verification. Payload construction is skipped when
    // no reporter is attached (hot-path discipline per requirements §5).
    let startTime = Date()
    if let telemetry {
      let offlineSnapshot = Acervo.isOfflineModeActive
      let requestedSnapshot = files
      await telemetry.capture(
        .downloadOperationStart(
          modelID: modelId,
          requestedFiles: requestedSnapshot,
          offlineMode: offlineSnapshot
        )
      )
    }

    // Compute destination directory
    let destination = baseDirectory.appendingPathComponent(slugify(modelId))

    // Create directory if needed
    try AcervoDownloader.ensureDirectory(at: destination, telemetry: telemetry)

    // Exclude model directory from iCloud backup — Apple requires that
    // large re-downloadable content must not be backed up.
    excludeFromBackup(baseDirectory)
    excludeFromBackup(destination)

    // Manifest-driven download with per-file integrity verification.
    // `session` is a test-only injection seam: when nil, AcervoDownloader's
    // default (`SecureDownloadSession.shared`) is used; when set, the
    // injected session intercepts both manifest and file requests.
    if let session {
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: files,
        destination: destination,
        force: force,
        progress: progress,
        session: session,
        telemetry: telemetry
      )
    } else {
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: files,
        destination: destination,
        force: force,
        progress: progress,
        telemetry: telemetry
      )
    }

    // Lifecycle: emit completion on the success path. `totalBytes` is reported
    // as 0 at this layer; consumers needing an exact byte total should sum
    // `componentDownloadComplete.actualBytes` events (those carry the
    // per-file ground truth from the integrity-verified stream).
    if let telemetry {
      let durationSeconds = Date().timeIntervalSince(startTime)
      await telemetry.capture(
        .downloadOperationComplete(
          modelID: modelId,
          totalBytes: 0,
          durationSeconds: durationSeconds
        )
      )
    }
  }
}
