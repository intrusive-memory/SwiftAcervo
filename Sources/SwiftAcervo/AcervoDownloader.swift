// AcervoDownloader.swift
// SwiftAcervo
//
// Internal download infrastructure for fetching model files from the CDN.
//
// AcervoDownloader provides static helpers for constructing CDN
// download URLs, fetching and validating manifests, downloading
// individual files with integrity verification, and orchestrating
// multi-file manifest-driven downloads.
//
// Downloads use a stream-and-hash approach: bytes are written to a
// UUID-named temp file and fed into an incremental SHA-256 hasher
// simultaneously, eliminating the post-download read pass. If the
// streaming path is unavailable, the downloader falls back to the
// legacy download(for:) + verifyAgainstManifest pattern.
//
// CDN URL format:
//   https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/{slug}/{fileName}
//
// All downloads use SecureDownloadSession which rejects redirects
// to non-CDN domains.

import CryptoKit
import Foundation
import OSLog

/// Internal download infrastructure for fetching model files from the CDN.
///
/// All methods are static. This struct is not publicly exposed; consumers
/// use `Acervo.download()` and related public API instead.
struct AcervoDownloader: Sendable {

  /// The base URL for the CDN model repository.
  static let cdnBaseURL = "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models"

  /// Logger for download-related diagnostics.
  private static let logger = Logger(
    subsystem: "com.intrusive-memory.SwiftAcervo",
    category: "AcervoDownloader"
  )

  /// Size of the write buffer used during streaming downloads (4 MB).
  /// Matches `IntegrityVerification.chunkSize` for consistency.
  private static let streamChunkSize = 4_194_304

  /// Maximum number of files downloaded concurrently in `downloadFiles()`.
  ///
  /// This is an internal constant and is intentionally not part of the public API.
  /// Increasing this value improves throughput on fast connections but raises
  /// peak memory usage proportionally (each in-flight file uses one 4 MB buffer).
  private static let maxConcurrentDownloads = 4

  private init() {}
}

// MARK: - Byte Progress Tracker

/// Thread-safe tracker for cumulative byte progress across concurrent file downloads.
///
/// Replaces the former `ProgressCoordinator`, which assigned file indices *inside*
/// async tasks. Because Swift's cooperative thread pool typically runs the most-recently-
/// added task first (LIFO), small config/JSON files added later to the task group often
/// received the highest indices, completed in milliseconds, and pushed `overallProgress`
/// to 1.0 while multi-GB model weights were still downloading.
///
/// `ByteProgressTracker` measures progress as cumulative bytes downloaded across all
/// concurrent files divided by total bytes for the entire operation, giving an accurate
/// signal regardless of file size distribution or task completion order.
private final class ByteProgressTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var fileBytes: [Int: Int64] = [:]
  private let totalAllBytes: Int64

  init(totalAllBytes: Int64) {
    self.totalAllBytes = totalAllBytes
  }

  /// Records the latest cumulative byte count for a file and returns updated overall
  /// progress (0.0–1.0) as `(sum of all file bytes) / totalAllBytes`.
  ///
  /// - Parameters:
  ///   - fileIndex: The manifest-order index of the file being updated.
  ///   - bytes: The cumulative bytes downloaded for this file so far.
  /// - Returns: Overall progress clamped to 0.0…1.0.
  func update(fileIndex: Int, bytes: Int64) -> Double {
    lock.lock()
    defer { lock.unlock() }
    fileBytes[fileIndex] = bytes
    guard totalAllBytes > 0 else { return 0.0 }
    let downloaded = fileBytes.values.reduce(Int64(0), +)
    return min(Double(downloaded) / Double(totalAllBytes), 1.0)
  }
}

// MARK: - URL Construction

extension AcervoDownloader {

  /// Constructs the CDN download URL for a specific file in a model.
  ///
  /// The URL follows the pattern:
  /// `https://{cdn}/models/{slug}/{fileName}`
  ///
  /// Subdirectory files are supported. For example, a `fileName` of
  /// `"speech_tokenizer/config.json"` produces a URL with the subdirectory
  /// path preserved in the URL path.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - fileName: The file name or relative path within the model
  ///     (e.g., "config.json" or "speech_tokenizer/config.json").
  /// - Returns: The fully qualified CDN download URL.
  static func buildURL(modelId: String, fileName: String) -> URL {
    let slug = Acervo.slugify(modelId)
    var url = URL(string: cdnBaseURL)!
      .appendingPathComponent(slug)

    // Handle subdirectory files by appending each path component separately
    let pathComponents = fileName.split(separator: "/").map(String.init)
    for component in pathComponents {
      url = url.appendingPathComponent(component)
    }

    return url
  }

  /// Constructs the CDN URL for a model's manifest.
  ///
  /// - Parameter modelId: A model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  /// - Returns: The URL of `manifest.json` on the CDN.
  static func buildManifestURL(modelId: String) -> URL {
    let slug = Acervo.slugify(modelId)
    return URL(string: cdnBaseURL)!
      .appendingPathComponent(slug)
      .appendingPathComponent("manifest.json")
  }
}

// MARK: - Directory Creation

extension AcervoDownloader {

  /// Ensures that a directory exists at the specified URL, creating it
  /// (along with any intermediate directories) if necessary.
  ///
  /// If the directory already exists, this method does nothing. If creation
  /// fails, an `AcervoError.directoryCreationFailed` error is thrown.
  ///
  /// **Concurrency safety**: This method is safe to call from multiple tasks
  /// simultaneously. `FileManager.createDirectory(withIntermediateDirectories: true)`
  /// is documented to be idempotent when the directory already exists, and the
  /// early-return guard above avoids the syscall in the common already-exists case.
  /// Concurrent calls racing on a not-yet-existing directory may both attempt
  /// `createDirectory`; one will succeed and the other will receive an `EEXIST`
  /// error, which `withIntermediateDirectories: true` silently ignores.
  ///
  /// - Parameter url: The directory URL to ensure exists.
  /// - Throws: `AcervoError.directoryCreationFailed` if the directory
  ///   cannot be created.
  static func ensureDirectory(
    at url: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) throws {
    let fm = FileManager.default

    // Skip if directory already exists
    var isDirectory: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return
    }

    do {
      try fm.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: nil
      )
    } catch {
      // NOTE: ensureDirectory is synchronous; telemetry emit is fire-and-forget via Task.
      // Ordering relative to the throw is not guaranteed, but the event will be captured.
      // ErrorPhase.s3Request handled in S3CDNClient.swift (not reachable from this module).
      if let telemetry {
        Task {
          await telemetry.capture(
            .errorThrown(
              phase: .directoryCreation,
              errorDescription: "Directory creation failed at \(url.path)",
              modelID: nil,
              fileName: nil
            ))
        }
      }
      throw AcervoError.directoryCreationFailed(url.path)
    }
  }
}

// MARK: - Manifest Download

extension AcervoDownloader {

  /// Constructs a `URLRequest` for downloading a file from the CDN.
  ///
  /// - Parameter url: The remote URL to download from.
  /// - Returns: A configured `URLRequest`.
  static func buildRequest(from url: URL) -> URLRequest {
    URLRequest(url: url)
  }

  /// Downloads and validates the CDN manifest for a model.
  ///
  /// This method:
  /// 1. Downloads `manifest.json` from the CDN
  /// 2. Decodes the JSON
  /// 3. Validates the manifest version
  /// 4. Validates the model ID matches the request
  /// 5. Verifies the manifest's checksum-of-checksums
  ///
  /// - Parameters:
  ///   - modelId: The model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - session: The URLSession used to fetch the manifest. Defaults to
  ///     `SecureDownloadSession.shared`, which rejects redirects to non-CDN
  ///     domains. Tests may inject a mock session.
  /// - Returns: The validated manifest.
  /// - Throws: `AcervoError` for download, decoding, or validation failures.
  public static func downloadManifest(
    for modelId: String,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws -> CDNManifest {
    let (manifest, _) = try await downloadManifestWithBytes(
      for: modelId,
      session: session,
      telemetry: telemetry
    )
    return manifest
  }

  /// Same contract as `downloadManifest(for:session:telemetry:)`, but also
  /// returns the *raw wire bytes* that decoded into the validated manifest.
  ///
  /// EM-1 (validity-oracle/manifest-persistence) introduced this variant so
  /// `downloadFiles` can persist the byte-equal CDN manifest to
  /// `<model-dir>/manifest.json` after a successful download. Returning the
  /// decoded `CDNManifest` *and* the bytes side-by-side is the only way to
  /// honor REQUIREMENTS §2's "the local file must be byte-equal to the CDN
  /// manifest" invariant — round-tripping through `JSONEncoder` is not
  /// guaranteed to reproduce the wire bytes (key order, formatting, optional
  /// field omission, etc. all differ across producers).
  static func downloadManifestWithBytes(
    for modelId: String,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws -> (CDNManifest, Data) {
    // Refuse the fetch up front when offline mode is active. This must run
    // BEFORE any URLSession call so callers can rely on the gate to keep the
    // process completely offline (no DNS, no socket, no proxy).
    if Acervo.isOfflineModeActive {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .offlineMode,
            errorDescription: "Manifest download blocked: offline mode is active",
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.offlineModeActive
    }

    let url = buildManifestURL(modelId: modelId)
    let request = buildRequest(from: url)

    // Emit manifest-fetch start before URLSession dispatch. URL string
    // materialization is skipped when no reporter is attached.
    if let telemetry {
      let urlString = url.absoluteString
      await telemetry.capture(
        .manifestFetchStart(modelID: modelId, manifestURL: urlString)
      )
    }

    // Download manifest using the provided session
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: error.localizedDescription,
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.networkError(error)
    }

    // Verify HTTP 200
    if let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode != 200
    {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: "Manifest download failed with HTTP \(httpResponse.statusCode)",
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.manifestDownloadFailed(statusCode: httpResponse.statusCode)
    }

    // Decode JSON
    let manifest: CDNManifest
    do {
      manifest = try JSONDecoder().decode(CDNManifest.self, from: data)
    } catch let error as AcervoError {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDecode,
            errorDescription: error.localizedDescription,
            modelID: modelId,
            fileName: nil
          ))
      }
      throw error
    } catch {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDecode,
            errorDescription: error.localizedDescription,
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.manifestDecodingFailed(error)
    }

    // Validate version
    guard manifest.manifestVersion == CDNManifest.supportedVersion else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestVersionUnsupported,
            errorDescription: "Unsupported manifest version: \(manifest.manifestVersion)",
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.manifestVersionUnsupported(manifest.manifestVersion)
    }

    // Validate model ID matches
    guard manifest.modelId == modelId else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestIntegrity,
            errorDescription:
              "Manifest model ID mismatch: expected \(modelId), got \(manifest.modelId)",
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.manifestModelIdMismatch(
        expected: modelId,
        actual: manifest.modelId
      )
    }

    // Verify manifest integrity (checksum-of-checksums)
    let computedChecksum = CDNManifest.computeChecksum(from: manifest.files.map(\.sha256))
    guard manifest.manifestChecksum == computedChecksum else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestIntegrity,
            errorDescription: "Manifest integrity check failed: checksum mismatch",
            modelID: modelId,
            fileName: nil
          ))
      }
      throw AcervoError.manifestIntegrityFailed(
        expected: manifest.manifestChecksum,
        actual: computedChecksum
      )
    }

    // Emit manifest-fetch complete after the manifest has been fully
    // validated. `manifestVersion` is stringified because the event signature
    // carries it as a String (the underlying field is an Int).
    if let telemetry {
      let totalDeclared = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
      await telemetry.capture(
        .manifestFetchComplete(
          modelID: modelId,
          manifestVersion: String(manifest.manifestVersion),
          fileCount: manifest.files.count,
          totalDeclaredBytes: totalDeclared
        )
      )
    }

    return (manifest, data)
  }
}

// MARK: - Manifest Persistence (Local Cache)

extension AcervoDownloader {

  /// Filename for the locally-cached copy of the CDN manifest, stored at the
  /// root of each model's directory. Hidden (leading dot) to keep it from
  /// appearing in casual listings, but otherwise a regular file.
  ///
  /// EM-1 retains this hidden filename for the legacy self-validating
  /// re-encoded cache. The byte-equal CDN manifest is written separately to
  /// `manifestFilename` (visible `manifest.json`) — see
  /// `persistManifestBytes(_:slug:in:)`.
  static let cachedManifestFilename = ".acervo-manifest.json"

  /// Filename for the byte-equal copy of the CDN manifest, stored at the
  /// root of each model's directory.
  ///
  /// REQUIREMENTS §2 invariant: this file MUST be byte-equal to the CDN
  /// manifest the model came from. The validity oracle (EM-2) reads this
  /// file as the source of truth for which files the model declares.
  /// Consumers can also read it directly with any JSON decoder.
  static let manifestFilename = "manifest.json"

  /// Persists a validated `CDNManifest` to disk inside the model's directory.
  ///
  /// Used after a successful `downloadFiles` run so that the strict
  /// `Acervo.isModelAvailable(_:)` check can subsequently verify every file
  /// in the manifest is on disk at the recorded size without re-fetching the
  /// manifest from the CDN.
  ///
  /// The write is atomic and the JSON is sorted-keys for determinism (helps
  /// reproducibility and is friendly to filesystem snapshot tooling).
  ///
  /// - Parameters:
  ///   - manifest: The validated manifest to persist. Caller is expected to
  ///     have already validated `manifestChecksum` (via `downloadManifest`).
  ///   - baseDirectory: The base shared-models directory. The manifest is
  ///     written to `{baseDirectory}/{slug}/.acervo-manifest.json`.
  /// - Throws: Encoding or atomic-write failures.
  static func persistManifest(
    _ manifest: CDNManifest,
    in baseDirectory: URL
  ) throws {
    let modelDir = baseDirectory.appendingPathComponent(manifest.slug)
    let url = modelDir.appendingPathComponent(cachedManifestFilename)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: url, options: [.atomic])
  }

  /// Persists the raw CDN manifest bytes to `<model-dir>/manifest.json`
  /// atomically.
  ///
  /// REQUIREMENTS §2 invariant: the bytes on disk MUST be byte-equal to the
  /// bytes received from the CDN. Round-tripping through `JSONEncoder` is
  /// NOT acceptable because key order, optional-field omission, and
  /// number-formatting all vary across producers; the only way to honor
  /// byte-equality is to write the exact bytes we read off the wire.
  ///
  /// The write is atomic (`Data.write(to:options: [.atomic])` which uses
  /// `NSData`'s temp-file-plus-rename under the hood — POSIX `rename(2)`
  /// guarantees the destination either points at the old file or the new
  /// file with no in-between state). The parent directory is created
  /// with `mkdir -p` semantics.
  ///
  /// - Parameters:
  ///   - data: The raw CDN manifest bytes, as returned by
  ///     `downloadManifestWithBytes`. Caller is expected to have already
  ///     validated the decoded manifest via that helper.
  ///   - slug: The filesystem slug for the model (e.g., `org_repo`). This
  ///     MUST be the manifest's own `slug` field — the helper takes it as
  ///     an explicit parameter rather than re-deriving from `data` so the
  ///     caller's intent (which slug should own these bytes) is explicit
  ///     and auditable.
  ///   - baseDirectory: The shared-models base directory. The manifest is
  ///     written to `{baseDirectory}/{slug}/manifest.json`.
  /// - Throws: Directory creation or atomic-write failures.
  static func persistManifestBytes(
    _ data: Data,
    slug: String,
    in baseDirectory: URL
  ) throws {
    let modelDir = baseDirectory.appendingPathComponent(slug)
    try ensureDirectory(at: modelDir)
    let url = modelDir.appendingPathComponent(manifestFilename)
    try data.write(to: url, options: [.atomic])
  }

  /// Loads the locally-cached `CDNManifest` for a model, if present and valid.
  ///
  /// Used by `Acervo.isModelAvailable(_:)` to drive the strict on-disk
  /// availability check without a network round-trip. Performs three
  /// validations and returns `nil` on any failure:
  ///
  /// 1. Read the file at `{baseDirectory}/{slug}/.acervo-manifest.json`.
  /// 2. JSON-decode it as `CDNManifest`.
  /// 3. Verify `manifestChecksum` matches the canonical checksum-of-checksums
  ///    of the file SHAs (same algorithm `downloadManifest` enforces against
  ///    fresh manifests).
  ///
  /// On any failure, the cache file is best-effort removed and `nil` is
  /// returned. Never throws — a corrupted manifest cache is a soft miss, not
  /// a hard error.
  ///
  /// - Parameters:
  ///   - modelId: The "org/repo" model identifier whose cached manifest we
  ///     want to load.
  ///   - baseDirectory: The base shared-models directory.
  /// - Returns: The decoded, self-consistent manifest, or `nil`.
  static func loadCachedManifest(
    for modelId: String,
    in baseDirectory: URL
  ) -> CDNManifest? {
    let slug = Acervo.slugify(modelId)
    let url =
      baseDirectory
      .appendingPathComponent(slug)
      .appendingPathComponent(cachedManifestFilename)
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    guard let manifest = try? JSONDecoder().decode(CDNManifest.self, from: data) else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    guard manifest.verifyChecksum() else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return manifest
  }
}

// MARK: - Streaming Download (Stream-and-Hash)

extension AcervoDownloader {

  /// Streams a file from the CDN, computing SHA-256 incrementally as bytes
  /// arrive, then atomically moves the verified temp file to the destination.
  ///
  /// This eliminates the post-download read pass by feeding every byte into
  /// both the temp file and a `SHA256` hasher simultaneously. The temp file
  /// is the destination URL with a `.part` extension appended, colocated with
  /// the final destination on the same volume so the closing `moveItem` is a
  /// guaranteed rename (no cross-volume copy).
  ///
  /// **Resumable behavior:** If a `.part` file already exists at the
  /// destination, this method classifies it by size against the manifest:
  /// - absent → write from offset 0, no `Range` header.
  /// - genuine partial (`0 < size < manifest.sizeBytes`) → send
  ///   `Range: bytes=<size>-`, seek the file handle to `size`, and seed the
  ///   SHA-256 hasher by replaying the existing bytes through it.
  /// - already-complete (`size == manifest.sizeBytes`) → skip the network
  ///   entirely; verify SHA against the part file. On match, rename to
  ///   destination. On mismatch, delete and start fresh.
  /// - oversized (`size > manifest.sizeBytes`) → delete and start fresh.
  ///
  /// Hasher state is reseeded by streaming the existing partial bytes back
  /// through `SHA256.update(data:)` rather than persisted between attempts.
  /// REQUIREMENTS § 7 documents the trade-off (~10 s for a 4 GB part file on
  /// modern SSD). The simplicity benefit of "hasher state lives only inside a
  /// single call" outweighs the one-time replay cost on resume.
  ///
  /// **Failure-path policy:** the part file is KEPT across transient failures
  /// (network/write errors) so a future retry can resume from the same byte
  /// offset. It is DELETED only on validated corruption: size mismatch, SHA
  /// mismatch, or an oversized pre-existing part file.
  ///
  /// - Parameters:
  ///   - request: The configured `URLRequest` targeting the CDN resource.
  ///   - destination: The local file URL where the verified file should end up.
  ///   - manifestFile: The manifest entry for this file (expected size + SHA-256).
  ///   - fileName: The display name for progress reporting.
  ///   - fileIndex: The zero-based index of this file in a multi-file download.
  ///   - totalFiles: The total number of files in the download operation.
  ///   - progress: An optional callback invoked with download progress at
  ///     intervals during streaming.
  ///   - session: The `URLSession` used to perform the streaming request.
  ///     Defaults to `SecureDownloadSession.shared`, which rejects redirects
  ///     to non-CDN domains. Tests may inject a mock session.
  /// - Throws: `AcervoError.downloadFailed` for non-200/206 HTTP responses,
  ///   `AcervoError.downloadSizeMismatch` or `AcervoError.integrityCheckFailed`
  ///   if post-stream verification fails. Re-throws network errors.
  private static func streamDownloadFile(
    request: URLRequest,
    to destination: URL,
    manifestFile: CDNManifestFile,
    fileName: String,
    fileIndex: Int,
    totalFiles: Int,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)?,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    // Refuse the fetch up front when offline mode is active. This runs
    // BEFORE the URLSession streaming call so the gate is unconditional
    // for every file download, regardless of which public entry point
    // (downloadFile, downloadFiles, hydrateComponent, etc.) routed here.
    if Acervo.isOfflineModeActive {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .offlineMode,
            errorDescription: "File download blocked: offline mode is active",
            modelID: nil,
            fileName: fileName
          ))
      }
      throw AcervoError.offlineModeActive
    }

    let fm = FileManager.default
    let totalBytes = manifestFile.sizeBytes

    // Ensure destination's parent directory exists BEFORE constructing the
    // `.part` URL. Subdirectory entries like `speech_tokenizer/config.json`
    // require this ordering or opening the file handle below would fail.
    let parentDirectory = destination.deletingLastPathComponent()
    try ensureDirectory(at: parentDirectory, telemetry: telemetry)

    // Co-locate the partial file with the destination. Same-volume guarantees
    // the final `moveItem` is a rename, not a cross-volume copy. The `.part`
    // suffix is invisible to consumers because the destination directory only
    // exposes the final file path after a successful verify-and-rename.
    let partURL = destination.appendingPathExtension("part")

    // Classify the part file's pre-stream state.
    var bytesWritten: Int64 = 0
    var hasher = SHA256()
    var resumeOffset: Int64 = 0
    var skipNetwork = false

    if let partSize = IntegrityVerification.partialFileSize(at: partURL) {
      if partSize == manifestFile.sizeBytes {
        // Already-complete part file. Verify SHA directly; on match, rename;
        // on mismatch, delete and restart from scratch.
        do {
          let preHash = try IntegrityVerification.sha256(of: partURL)
          if preHash == manifestFile.sha256 {
            // Atomic-rename and report immediate completion. No network I/O.
            if fm.fileExists(atPath: destination.path) {
              try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: partURL, to: destination)
            progress?(
              AcervoDownloadProgress(
                fileName: fileName,
                bytesDownloaded: totalBytes,
                totalBytes: totalBytes,
                fileIndex: fileIndex,
                totalFiles: totalFiles
              ))
            skipNetwork = true
          } else {
            // Validated corruption — delete and restart fresh.
            try? fm.removeItem(at: partURL)
          }
        } catch {
          // Hash computation failed (file read error). Treat as corrupt;
          // delete and restart.
          try? fm.removeItem(at: partURL)
        }
      } else if partSize > manifestFile.sizeBytes {
        // Oversized part file — corrupt or stale manifest size. Validated
        // corruption: delete and restart.
        try? fm.removeItem(at: partURL)
      } else if partSize > 0 {
        // Genuine partial. Replay existing bytes through the hasher and ask
        // the server to resume from `partSize`.
        do {
          let handle = try FileHandle(forReadingFrom: partURL)
          defer { try? handle.close() }
          while true {
            let chunk = handle.readData(ofLength: IntegrityVerification.chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
          }
          resumeOffset = partSize
          bytesWritten = partSize
        } catch {
          // Could not seed the hasher from the existing part file. Treat as
          // corrupt and restart fresh.
          try? fm.removeItem(at: partURL)
          hasher = SHA256()
          resumeOffset = 0
          bytesWritten = 0
        }
      }
      // partSize == 0: file exists but empty. Treat like a fresh start; the
      // open-for-writing path below will reuse the empty file.
    }

    if skipNetwork {
      return
    }

    // Build the effective request, attaching a `Range` header only when we
    // have valid partial bytes to resume from.
    var effectiveRequest = request
    let didSendRangeHeader = (resumeOffset > 0)
    if didSendRangeHeader {
      effectiveRequest.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
    }

    // Stream the HTTP response as OS-sized `Data` chunks instead of one
    // `UInt8` at a time. `bytes(for:)` yields a `UInt8` async sequence, so a
    // multi-GB model crosses the `AsyncSequence.next()` machinery billions of
    // times and the download becomes CPU-bound on async-iteration overhead
    // rather than network/disk bound (issue #69). `chunkedResponseStream`
    // delivers the identical body via a `URLSessionDataDelegate`, surfacing the
    // ~16-64 KB chunks the OS hands us; the resume / hashing / progress
    // bookkeeping below is unchanged, just driven per chunk instead of per
    // byte. A transport failure here throws a non-`AcervoError`, so the
    // caller's fallback to `fallbackDownloadFile` is preserved.
    let (response, byteStream) = try await chunkedResponseStream(
      for: effectiveRequest,
      session: session
    )

    // Validate HTTP status: 200 (full body) or 206 (partial). If we sent a
    // Range header and the server responded 200, the server ignored it and
    // is sending the full body — reset hasher + truncate part file and
    // continue from offset 0.
    var serverIgnoredRange = false
    if let httpResponse = response as? HTTPURLResponse {
      let status = httpResponse.statusCode
      switch status {
      case 200:
        if didSendRangeHeader {
          // Server ignored our Range request. Reset and consume from start.
          serverIgnoredRange = true
        }
      case 206:
        // Trust partial bytes already on disk; body resumes at `resumeOffset`.
        break
      default:
        if let telemetry {
          await telemetry.capture(
            .errorThrown(
              phase: .fileDownload,
              errorDescription: "File download failed with HTTP \(status)",
              modelID: nil,
              fileName: fileName
            ))
        }
        // Non-success HTTP status — KEEP the part file (transient: server
        // may be healthy on retry). Throw to surface the failure.
        throw AcervoError.downloadFailed(
          fileName: fileName,
          statusCode: status
        )
      }
    }

    // Report initial progress (factoring resume offset into the byte counter
    // so consumers see continuous progress across attempts).
    progress?(
      AcervoDownloadProgress(
        fileName: fileName,
        bytesDownloaded: bytesWritten,
        totalBytes: totalBytes,
        fileIndex: fileIndex,
        totalFiles: totalFiles
      ))

    // Open the part file for writing. If we are resuming (206 case), seek to
    // `resumeOffset` so appended bytes land after the existing prefix. If the
    // server ignored our Range header, we'll truncate to 0 below.
    if !fm.fileExists(atPath: partURL.path) {
      fm.createFile(atPath: partURL.path, contents: nil)
    }
    let fileHandle: FileHandle
    do {
      fileHandle = try FileHandle(forWritingTo: partURL)
    } catch {
      // Could not open the part file for writing — KEEP the file (the bytes
      // on disk are still valid, the failure is transient).
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .other,
            errorDescription: "Failed to open part file for writing: \(error.localizedDescription)",
            modelID: nil,
            fileName: fileName
          ))
      }
      throw error
    }

    if serverIgnoredRange {
      // Discard the partial prefix: reset hasher, truncate file, restart.
      hasher = SHA256()
      do {
        try fileHandle.truncate(atOffset: 0)
        try fileHandle.seek(toOffset: 0)
      } catch {
        try? fileHandle.close()
        // Truncation failure is transient — keep the part file as-is and
        // surface the error so the caller can retry.
        throw error
      }
      bytesWritten = 0
    } else if resumeOffset > 0 {
      // Seek past the existing prefix so streamed bytes append.
      do {
        try fileHandle.seek(toOffset: UInt64(resumeOffset))
      } catch {
        try? fileHandle.close()
        throw error
      }
    }

    var buffer = Data()
    buffer.reserveCapacity(streamChunkSize)

    do {
      for try await chunk in byteStream {
        buffer.append(chunk)

        // Flush buffer when it reaches chunk size. Accumulating whole `Data`
        // chunks (rather than single bytes) preserves the existing 4 MB
        // write / hash / progress granularity exactly.
        if buffer.count >= streamChunkSize {
          hasher.update(data: buffer)
          try fileHandle.write(contentsOf: buffer)
          bytesWritten += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)

          // Report intermediate progress
          progress?(
            AcervoDownloadProgress(
              fileName: fileName,
              bytesDownloaded: bytesWritten,
              totalBytes: totalBytes,
              fileIndex: fileIndex,
              totalFiles: totalFiles
            ))
        }
      }

      // Flush any remaining bytes in buffer
      if !buffer.isEmpty {
        hasher.update(data: buffer)
        try fileHandle.write(contentsOf: buffer)
        bytesWritten += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
      }

      try fileHandle.close()
    } catch {
      // Stream interrupted or write failed -- KEEP the part file. The bytes
      // already on disk remain a valid partial that a future retry can
      // resume from.
      try? fileHandle.close()
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .fileDownload,
            errorDescription: "Stream interrupted or write failed: \(error.localizedDescription)",
            modelID: nil,
            fileName: fileName
          ))
      }
      throw error
    }

    // Verify size — DELETE on validated corruption.
    if bytesWritten != manifestFile.sizeBytes {
      try? fm.removeItem(at: partURL)
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .fileDownloadSize,
            errorDescription:
              "Size mismatch for \(manifestFile.path): expected \(manifestFile.sizeBytes), got \(bytesWritten)",
            modelID: nil,
            fileName: manifestFile.path
          ))
      }
      throw AcervoError.downloadSizeMismatch(
        fileName: manifestFile.path,
        expected: manifestFile.sizeBytes,
        actual: bytesWritten
      )
    }

    // Finalize hash and verify SHA-256 — DELETE on validated corruption.
    let digest = hasher.finalize()
    let actualHash = digest.map { String(format: "%02x", $0) }.joined()
    if actualHash != manifestFile.sha256 {
      try? fm.removeItem(at: partURL)
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .fileDownloadIntegrity,
            errorDescription: "SHA-256 mismatch for \(manifestFile.path)",
            modelID: nil,
            fileName: manifestFile.path
          ))
      }
      throw AcervoError.integrityCheckFailed(
        file: manifestFile.path,
        expected: manifestFile.sha256,
        actual: actualHash
      )
    }

    // Remove any existing file at destination, then atomic-rename the
    // verified part file into place.
    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }
    try fm.moveItem(at: partURL, to: destination)

    // Report completion
    progress?(
      AcervoDownloadProgress(
        fileName: fileName,
        bytesDownloaded: totalBytes,
        totalBytes: totalBytes,
        fileIndex: fileIndex,
        totalFiles: totalFiles
      ))
  }
}

// MARK: - Chunked Streaming Transport

extension AcervoDownloader {

  /// Streams an HTTP response body as OS-sized `Data` chunks rather than one
  /// `UInt8` at a time.
  ///
  /// `URLSession.bytes(for:)` vends the body as a `UInt8` async sequence; every
  /// byte crosses the `AsyncSequence.next()` suspension machinery, which makes
  /// multi-GB model downloads CPU-bound on async-iteration overhead instead of
  /// network/disk bound (issue #69). This helper instead drives a
  /// `URLSessionDataTask` through `ChunkedDownloadDelegate`, surfacing the
  /// whole `Data` chunks the OS delivers (~16-64 KB) via an
  /// `AsyncThrowingStream`.
  ///
  /// The return shape mirrors `bytes(for:)`: the `URLResponse` resolves as soon
  /// as the response headers arrive (so the caller can run its 200-vs-206
  /// status checks before consuming the body), and the stream then yields the
  /// body chunk-by-chunk. A transport failure before the headers arrive is
  /// thrown from this call; a failure mid-body terminates the returned stream
  /// (so the active `for try await` throws). Both surface as non-`AcervoError`,
  /// preserving `downloadFile`'s fallback to `fallbackDownloadFile`.
  ///
  /// The injected `session`'s own delegate (e.g. `SecureDownloadDelegate`'s
  /// redirect rejection) is still consulted for any method this per-task
  /// delegate does not implement, so the CDN-host security guard is unaffected.
  ///
  /// - Parameters:
  ///   - request: The configured request (including any `Range` header).
  ///   - session: The session to issue the data task on. Tests may inject a
  ///     `URLProtocol`-backed mock that delivers the body in multiple chunks.
  /// - Returns: The response and an `AsyncThrowingStream` of body `Data` chunks.
  static func chunkedResponseStream(
    for request: URLRequest,
    session: URLSession
  ) async throws -> (URLResponse, AsyncThrowingStream<Data, Error>) {
    let delegate = ChunkedDownloadDelegate()
    let task = session.dataTask(with: request)
    // A per-task delegate (macOS 12 / iOS 15+) receives the data callbacks
    // without disturbing the session-level delegate used for redirect security.
    task.delegate = delegate
    delegate.attachTask(task)

    let stream = AsyncThrowingStream<Data, Error> { continuation in
      // Cancel the in-flight task if the consumer stops iterating early (e.g.
      // a disk-write error breaks out of the loop in `streamDownloadFile`).
      continuation.onTermination = { [delegate] _ in
        delegate.cancelTask()
      }
      delegate.attachStream(continuation)
    }

    task.resume()

    // Suspend until the response headers arrive (or the task fails first),
    // matching the `(bytes, response)` ordering of `bytes(for:)`.
    let response = try await delegate.awaitResponse()
    return (response, stream)
  }

  /// Bridges a delegate-driven `URLSessionDataTask` to async `Data`-chunk
  /// delivery for ``chunkedResponseStream(for:session:)``.
  ///
  /// `@unchecked Sendable`: all mutable state is guarded by `lock`, and the
  /// session invokes the delegate callbacks serially on its delegate queue.
  final class ChunkedDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var responseSettled = false
    private var pendingResponse: URLResponse?
    private var pendingError: Error?
    private var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var task: URLSessionTask?

    /// Records the task so the stream's termination handler can cancel it.
    func attachTask(_ task: URLSessionTask) {
      lock.lock()
      defer { lock.unlock() }
      self.task = task
    }

    /// Stores the body stream's continuation. Chunks delivered before the
    /// caller begins iterating are buffered by the stream (`.unbounded`).
    func attachStream(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
      lock.lock()
      defer { lock.unlock() }
      streamContinuation = continuation
    }

    /// Cancels the underlying task (safe to call from any thread).
    func cancelTask() {
      lock.lock()
      let task = self.task
      lock.unlock()
      task?.cancel()
    }

    /// Suspends until the first response header arrives, or the task fails
    /// before delivering any response. Awaited exactly once. If the response
    /// (or failure) already landed before this call — the delegate callbacks
    /// run on the session's queue and can race ahead of this suspension — it
    /// resolves immediately from the recorded result rather than hanging.
    func awaitResponse() async throws -> URLResponse {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if responseSettled {
          let response = pendingResponse
          let error = pendingError
          lock.unlock()
          if let response {
            continuation.resume(returning: response)
          } else {
            continuation.resume(throwing: error ?? URLError(.badServerResponse))
          }
          return
        }
        responseContinuation = continuation
        lock.unlock()
      }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
      lock.lock()
      let continuation = responseContinuation
      responseContinuation = nil
      responseSettled = true
      pendingResponse = response
      lock.unlock()

      continuation?.resume(returning: response)
      completionHandler(.allow)
    }

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive data: Data
    ) {
      lock.lock()
      let continuation = streamContinuation
      lock.unlock()
      continuation?.yield(data)
    }

    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      didCompleteWithError error: Error?
    ) {
      lock.lock()
      let responseContinuation = self.responseContinuation
      self.responseContinuation = nil
      let alreadySettled = responseSettled
      if !alreadySettled {
        responseSettled = true
        pendingError = error
      }
      let streamContinuation = self.streamContinuation
      self.streamContinuation = nil
      self.task = nil
      lock.unlock()

      if let error {
        // Transport failure. If the headers never arrived, surface the error to
        // `awaitResponse()`; otherwise terminate the body stream so the active
        // iteration throws (the KEEP-the-part-file path in streamDownloadFile).
        if !alreadySettled {
          responseContinuation?.resume(throwing: error)
        }
        streamContinuation?.finish(throwing: error)
      } else {
        // Clean completion. A successful HTTP exchange always delivers the
        // response before completing, so `responseContinuation` is normally
        // nil here; the guard only fires for the degenerate "finished without
        // a response" case, where we surface a transport error rather than
        // leave `awaitResponse()` suspended forever.
        if !alreadySettled {
          responseContinuation?.resume(throwing: URLError(.badServerResponse))
        }
        streamContinuation?.finish()
      }
    }
  }
}

// MARK: - Fallback Download (Legacy)

extension AcervoDownloader {

  /// Legacy whole-file fallback. Invoked only when `streamDownloadFile` throws a
  /// non-`AcervoError` (transport error, etc.). This path intentionally does NOT
  /// implement `.part`-based resume: it is the second-chance retry for a stream that
  /// has already failed. Restarting the whole file is acceptable here because
  /// (a) reaching this path is already an exceptional case, (b) `URLSession.download(for:)`
  /// writes to session-managed temp anyway and is rename-only on the final hop,
  /// (c) adding resume here would duplicate `streamDownloadFile`'s range-classification
  /// logic for negligible benefit.
  ///
  /// - Parameters:
  ///   - request: The configured `URLRequest` targeting the CDN resource.
  ///   - destination: The local file URL where the downloaded file should be placed.
  ///   - manifestFile: The manifest entry for this file.
  ///   - fileName: The display name for progress reporting.
  ///   - fileIndex: The zero-based index of this file in a multi-file download.
  ///   - totalFiles: The total number of files in the download operation.
  ///   - progress: An optional callback invoked with download progress.
  ///   - session: The `URLSession` used to perform the download request.
  ///     Defaults to `SecureDownloadSession.shared`, which rejects redirects
  ///     to non-CDN domains. Tests may inject a mock session.
  /// - Throws: Download, verification, or directory creation errors.
  private static func fallbackDownloadFile(
    request: URLRequest,
    to destination: URL,
    manifestFile: CDNManifestFile,
    fileName: String,
    fileIndex: Int,
    totalFiles: Int,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)?,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    // Refuse the fetch up front when offline mode is active. The streaming
    // path checks the gate too, but `streamDownloadFile` may delegate here
    // on its own initiative when bytes(for:) is unavailable, so we re-check
    // before the legacy URLSession.download call.
    if Acervo.isOfflineModeActive {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .offlineMode,
            errorDescription: "Fallback file download blocked: offline mode is active",
            modelID: nil,
            fileName: fileName
          ))
      }
      throw AcervoError.offlineModeActive
    }

    // Download the file to a temp location using the provided session
    let tempFileURL: URL
    let response: URLResponse
    do {
      (tempFileURL, response) = try await session.download(for: request)
    } catch {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .fileDownload,
            errorDescription: error.localizedDescription,
            modelID: nil,
            fileName: fileName
          ))
      }
      throw AcervoError.networkError(error)
    }

    // Verify HTTP 200
    if let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode != 200
    {
      try? FileManager.default.removeItem(at: tempFileURL)
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .fileDownload,
            errorDescription: "Fallback file download failed with HTTP \(httpResponse.statusCode)",
            modelID: nil,
            fileName: fileName
          ))
      }
      throw AcervoError.downloadFailed(
        fileName: fileName,
        statusCode: httpResponse.statusCode
      )
    }

    let totalBytes = manifestFile.sizeBytes

    // Report initial progress
    progress?(
      AcervoDownloadProgress(
        fileName: fileName,
        bytesDownloaded: 0,
        totalBytes: totalBytes,
        fileIndex: fileIndex,
        totalFiles: totalFiles
      ))

    // Ensure destination's parent directory exists
    let parentDirectory = destination.deletingLastPathComponent()
    try ensureDirectory(at: parentDirectory, telemetry: telemetry)

    // Remove any existing file at destination
    let fm = FileManager.default
    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }

    // Move temp file to destination atomically
    try fm.moveItem(at: tempFileURL, to: destination)

    // Verify integrity: size then SHA-256
    try await IntegrityVerification.verifyAgainstManifest(
      fileURL: destination,
      manifestFile: manifestFile,
      telemetry: telemetry
    )

    // Report completion
    progress?(
      AcervoDownloadProgress(
        fileName: fileName,
        bytesDownloaded: totalBytes,
        totalBytes: totalBytes,
        fileIndex: fileIndex,
        totalFiles: totalFiles
      ))
  }
}

// MARK: - File Download (Public Internal API)

extension AcervoDownloader {

  /// Downloads a single file from the CDN to a local destination.
  ///
  /// Uses the streaming download path by default, which computes SHA-256
  /// incrementally as bytes arrive. Falls back to the legacy
  /// `download(for:)` + `verifyAgainstManifest` pattern if streaming fails.
  ///
  /// The file is written to a UUID-named temp file, verified against the
  /// manifest entry (size + SHA-256), then moved atomically to the
  /// destination. If verification fails, the temp file is deleted and an
  /// error is thrown.
  ///
  /// - Parameters:
  ///   - url: The remote CDN URL to download from.
  ///   - destination: The local file URL where the downloaded file should be placed.
  ///   - manifestFile: The manifest entry for this file, used for integrity verification.
  ///   - session: The `URLSession` used to perform the download request.
  ///     Defaults to `SecureDownloadSession.shared`, which rejects redirects
  ///     to non-CDN domains. Tests may inject a mock session.
  /// - Throws: `AcervoError.downloadFailed` for non-200 HTTP responses,
  ///   `AcervoError.networkError` for connection failures,
  ///   `AcervoError.downloadSizeMismatch` or `AcervoError.integrityCheckFailed`
  ///   if post-download verification fails.
  static func downloadFile(
    from url: URL,
    to destination: URL,
    manifestFile: CDNManifestFile,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    let request = buildRequest(from: url)

    do {
      try await streamDownloadFile(
        request: request,
        to: destination,
        manifestFile: manifestFile,
        fileName: manifestFile.path,
        fileIndex: 0,
        totalFiles: 1,
        progress: nil,
        session: session,
        telemetry: telemetry
      )
    } catch let streamError {
      // If the error is a verification or HTTP error, propagate immediately
      // (no point falling back -- the data was already bad)
      if streamError is AcervoError {
        if let telemetry {
          await telemetry.capture(
            .errorThrown(
              phase: .fileDownload,
              errorDescription: streamError.localizedDescription,
              modelID: nil,
              fileName: manifestFile.path
            ))
        }
        throw streamError
      }

      // Stream failed for a non-verification reason; fall back to legacy path
      logger.warning(
        "Streaming download failed for \(manifestFile.path, privacy: .public), falling back to legacy download: \(streamError.localizedDescription, privacy: .public)"
      )

      try await fallbackDownloadFile(
        request: request,
        to: destination,
        manifestFile: manifestFile,
        fileName: manifestFile.path,
        fileIndex: 0,
        totalFiles: 1,
        progress: nil,
        session: session,
        telemetry: telemetry
      )
    }
  }

  /// Downloads a single file from the CDN with progress reporting.
  ///
  /// Uses the streaming download path by default, which computes SHA-256
  /// incrementally as bytes arrive. Falls back to the legacy
  /// `download(for:)` + `verifyAgainstManifest` pattern if streaming fails.
  ///
  /// - Parameters:
  ///   - url: The remote CDN URL to download from.
  ///   - destination: The local file URL where the downloaded file should be placed.
  ///   - manifestFile: The manifest entry for this file.
  ///   - fileName: The display name for the file (used in progress reporting).
  ///   - fileIndex: The zero-based index of this file in a multi-file download.
  ///   - totalFiles: The total number of files in the download operation.
  ///   - progress: An optional callback invoked with download progress.
  ///   - session: The `URLSession` used to perform the download request.
  ///     Defaults to `SecureDownloadSession.shared`, which rejects redirects
  ///     to non-CDN domains. Tests may inject a mock session.
  /// - Throws: Download, verification, or directory creation errors.
  static func downloadFile(
    from url: URL,
    to destination: URL,
    manifestFile: CDNManifestFile,
    fileName: String,
    fileIndex: Int,
    totalFiles: Int,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)?,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    let request = buildRequest(from: url)

    do {
      try await streamDownloadFile(
        request: request,
        to: destination,
        manifestFile: manifestFile,
        fileName: fileName,
        fileIndex: fileIndex,
        totalFiles: totalFiles,
        progress: progress,
        session: session,
        telemetry: telemetry
      )
    } catch let streamError {
      // If the error is a verification or HTTP error, propagate immediately
      if streamError is AcervoError {
        if let telemetry {
          await telemetry.capture(
            .errorThrown(
              phase: .fileDownload,
              errorDescription: streamError.localizedDescription,
              modelID: nil,
              fileName: fileName
            ))
        }
        throw streamError
      }

      // Stream failed for a non-verification reason; fall back to legacy path
      logger.warning(
        "Streaming download failed for \(fileName, privacy: .public), falling back to legacy download: \(streamError.localizedDescription, privacy: .public)"
      )

      try await fallbackDownloadFile(
        request: request,
        to: destination,
        manifestFile: manifestFile,
        fileName: fileName,
        fileIndex: fileIndex,
        totalFiles: totalFiles,
        progress: progress,
        session: session,
        telemetry: telemetry
      )
    }
  }
}

// MARK: - Multi-File Manifest-Driven Download

extension AcervoDownloader {

  /// Downloads files for a model using the CDN manifest for integrity verification.
  ///
  /// This is the core download method. It:
  /// 1. Fetches and validates the CDN manifest
  /// 2. Filters to the requested files (or all files if none specified)
  /// 3. Downloads each file from the CDN concurrently (up to `maxConcurrentDownloads`)
  /// 4. Verifies each file's size and SHA-256 against the manifest
  ///
  /// Files that already exist and pass verification are skipped unless `force` is `true`.
  ///
  /// Progress is reported as byte-accurate cumulative progress:
  /// `totalBytesDownloaded / totalBytesForAllFiles`. This prevents small config/JSON
  /// files from jumping `overallProgress` to 1.0 while large model weights are still
  /// downloading.
  ///
  /// - Parameters:
  ///   - modelId: The model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - requestedFiles: Files to download. If empty, downloads ALL files in the manifest.
  ///   - destination: The local directory URL where files should be placed.
  ///   - force: When `true`, re-downloads files even if they already exist. Defaults to `false`.
  ///   - progress: An optional callback invoked with download progress.
  ///   - session: The `URLSession` used to perform both the manifest and
  ///     file downloads. Defaults to `SecureDownloadSession.shared`, which
  ///     rejects redirects to non-CDN domains. Tests may inject a mock session.
  /// - Throws: Manifest, download, or verification errors.
  static func downloadFiles(
    modelId: String,
    requestedFiles: [String],
    destination: URL,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    session: URLSession = SecureDownloadSession.shared,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    // Step 1: Fetch and validate the manifest. We capture the raw bytes
    // here so we can persist the byte-equal CDN manifest to
    // `<model-dir>/manifest.json` at the end of the run (REQUIREMENTS §2
    // invariant — see `persistManifestBytes` doc-comment).
    let (manifest, manifestBytes) = try await downloadManifestWithBytes(
      for: modelId,
      session: session,
      telemetry: telemetry
    )

    // Step 2: Determine which files to download
    let filesToDownload: [CDNManifestFile]
    if requestedFiles.isEmpty {
      // Download everything in the manifest
      filesToDownload = manifest.files
    } else {
      // Download only requested files, validated against manifest
      filesToDownload = try requestedFiles.map { fileName in
        guard let entry = manifest.file(at: fileName) else {
          // NOTE: This throw is inside a sync map closure; telemetry is fire-and-forget via Task.
          // Ordering relative to the throw is not guaranteed, but the event will be captured.
          if let tel = telemetry {
            Task {
              await tel.capture(
                .errorThrown(
                  phase: .other,
                  errorDescription: "Requested file not found in manifest: \(fileName)",
                  modelID: modelId,
                  fileName: fileName
                ))
            }
          }
          throw AcervoError.fileNotInManifest(
            fileName: fileName,
            modelId: modelId
          )
        }
        return entry
      }
    }

    // Step 3: Ensure the top-level destination directory exists
    try ensureDirectory(at: destination, telemetry: telemetry)

    let totalFiles = filesToDownload.count

    // Step 4: Download files concurrently, up to maxConcurrentDownloads at a time.
    //
    // Byte-accurate progress: indices are assigned in manifest order (outside async
    // tasks, so they are deterministic) and a ByteProgressTracker accumulates bytes
    // across all concurrent downloads. Each progress callback reports
    // overallProgress = totalBytesDownloaded / totalBytesForAllFiles, eliminating
    // the prior bug where small JSON/config files completed with high file-count
    // indices and pushed overallProgress to 1.0 immediately.
    //
    // On the first error the task group is cancelled, signalling cooperative
    // cancellation to all in-flight child tasks.
    let totalAllBytes = filesToDownload.reduce(Int64(0)) { $0 + $1.sizeBytes }
    let byteTracker = ByteProgressTracker(totalAllBytes: totalAllBytes)

    try await withThrowingTaskGroup(of: Void.self) { group in
      var inFlight = 0

      for (index, manifestFile) in filesToDownload.enumerated() {
        // Cooperative cancellation: check before starting each new task.
        try Task.checkCancellation()

        // Throttle: wait for one task to finish before adding a new one
        // once we have reached the concurrency limit.
        if inFlight >= maxConcurrentDownloads {
          try await group.next()
          inFlight -= 1
        }

        let fileDestination = destination.appendingPathComponent(manifestFile.path)

        // Cache decision: emit cacheHit/cacheMiss BEFORE any network I/O so
        // observers see the verdict before HTTP traffic. Payload construction
        // is skipped when no reporter is attached. The current cache check is
        // size-only (no on-disk SHA recomputation), so we can definitively
        // emit `.notPresent`, `.sizeChangedRemote`, or `.forcedRefresh`. The
        // `.corrupted` and `.shaChangedRemote` reasons are reserved for
        // future verify-on-read paths that recompute the on-disk SHA before
        // network I/O — currently unreachable from this code path (see
        // CacheMissReason references near `modelLoadComplete` below).
        let fm = FileManager.default
        if force {
          if let telemetry {
            await telemetry.capture(
              .cacheMiss(
                modelID: modelId,
                fileName: manifestFile.path,
                reason: .forcedRefresh
              )
            )
          }
          // Fall through to download (force overrides cache).
        } else if !fm.fileExists(atPath: fileDestination.path) {
          if let telemetry {
            await telemetry.capture(
              .cacheMiss(
                modelID: modelId,
                fileName: manifestFile.path,
                reason: .notPresent
              )
            )
          }
          // Fall through to download.
        } else {
          // Per-file predicate is shared with `isModelAvailable(_:)` via
          // `IntegrityVerification.fileMatchesManifestEntry(_:in:)` so the
          // two code paths agree on the definition of "this file is intact
          // on disk." Telemetry remains per-file here; the predicate itself
          // is silent.
          if IntegrityVerification.fileMatchesManifestEntry(manifestFile, in: destination) {
            // Cache hit: file exists with the correct size. Emit before
            // crediting progress so observers see the cache decision first.
            let existingSize = manifestFile.sizeBytes
            if let telemetry {
              let ageSeconds: Double
              if let attrs = try? fm.attributesOfItem(atPath: fileDestination.path),
                let mtime = attrs[.modificationDate] as? Date
              {
                ageSeconds = Date().timeIntervalSince(mtime)
              } else {
                ageSeconds = 0
              }
              await telemetry.capture(
                .cacheHit(
                  modelID: modelId,
                  fileName: manifestFile.path,
                  onDiskBytes: existingSize,
                  ageSeconds: ageSeconds
                )
              )
            }
            // Credit this file's full byte count so overall progress is accurate.
            let overallFraction = byteTracker.update(
              fileIndex: index,
              bytes: manifestFile.sizeBytes
            )
            progress?(
              AcervoDownloadProgress(
                fileName: manifestFile.path,
                bytesDownloaded: manifestFile.sizeBytes,
                totalBytes: manifestFile.sizeBytes,
                fileIndex: index,
                totalFiles: totalFiles,
                _overallProgressOverride: overallFraction
              ))
            continue
          }
          // Size mismatch -- file is corrupt or stale, re-download. The
          // existing code can't distinguish "size changed at the remote"
          // from "local corruption" without recomputing the on-disk SHA, so
          // we report `.sizeChangedRemote` (the literal observation: the
          // on-disk byte count differs from the CDN's current manifest).
          if let telemetry {
            await telemetry.capture(
              .cacheMiss(
                modelID: modelId,
                fileName: manifestFile.path,
                reason: .sizeChangedRemote
              )
            )
          }
        }

        let url = buildURL(modelId: modelId, fileName: manifestFile.path)

        // Capture loop variables for the child task.
        let capturedManifestFile = manifestFile
        let capturedDestination = fileDestination
        let capturedURL = url
        let capturedIndex = index

        // Wrap the progress callback so each per-file update feeds the byte tracker
        // and carries a byte-accurate _overallProgressOverride.
        let wrappedProgress: (@Sendable (AcervoDownloadProgress) -> Void)? = progress.map {
          originalProgress in
          { @Sendable acervoProgress in
            let overallFraction = byteTracker.update(
              fileIndex: capturedIndex,
              bytes: acervoProgress.bytesDownloaded
            )
            originalProgress(
              AcervoDownloadProgress(
                fileName: acervoProgress.fileName,
                bytesDownloaded: acervoProgress.bytesDownloaded,
                totalBytes: acervoProgress.totalBytes,
                fileIndex: acervoProgress.fileIndex,
                totalFiles: acervoProgress.totalFiles,
                _overallProgressOverride: overallFraction
              ))
          }
        }

        let capturedSession = session
        let capturedTelemetry = telemetry
        let capturedModelId = modelId

        group.addTask {
          // Cooperative cancellation inside the child task.
          try Task.checkCancellation()

          // Per-component start. Payload construction (URL string, expected
          // bytes) is skipped when no reporter is attached. Duration is
          // measured from this point — slightly before body-read (the TCP
          // handshake is included). True start-of-body-read would require
          // passing telemetry farther down into `streamDownloadFile`, which
          // doesn't carry the modelID needed for the event payload.
          let bodyReadStart = Date()
          if let telemetry = capturedTelemetry {
            let sourceURLString = capturedURL.absoluteString
            await telemetry.capture(
              .componentDownloadStart(
                modelID: capturedModelId,
                fileName: capturedManifestFile.path,
                expectedBytes: capturedManifestFile.sizeBytes,
                sourceURL: sourceURLString
              )
            )
          }

          try await downloadFile(
            from: capturedURL,
            to: capturedDestination,
            manifestFile: capturedManifestFile,
            fileName: capturedManifestFile.path,
            fileIndex: capturedIndex,
            totalFiles: totalFiles,
            progress: wrappedProgress,
            session: capturedSession,
            telemetry: capturedTelemetry
          )

          // Per-component complete. Throughput is reported in megabytes per
          // second using the base-1024 (MiB/s) convention: bytes / seconds /
          // 1_048_576. Skipped when no reporter is attached.
          if let telemetry = capturedTelemetry {
            let durationSeconds = Date().timeIntervalSince(bodyReadStart)
            let actualBytes = capturedManifestFile.sizeBytes
            let throughputMBps: Double
            if durationSeconds > 0 {
              throughputMBps =
                Double(actualBytes) / durationSeconds / 1_048_576.0
            } else {
              throughputMBps = 0
            }
            await telemetry.capture(
              .componentDownloadComplete(
                modelID: capturedModelId,
                fileName: capturedManifestFile.path,
                actualBytes: actualBytes,
                durationSeconds: durationSeconds,
                throughputMBps: throughputMBps
              )
            )
          }
        }

        inFlight += 1
      }

      // Drain any remaining in-flight tasks.  If any of them threw, the
      // error propagates here and the task group cancels the remaining ones.
      try await group.waitForAll()
    }

    // Persist the validated manifest alongside the model files so the
    // strict-on-disk `Acervo.isModelAvailable(_:)` check can verify every
    // file without re-fetching from the CDN. Best-effort: a write failure
    // here must not propagate as a user-visible download error — the model
    // is fully downloaded and verified by this point, the manifest cache is
    // just an optimization for subsequent availability probes. We compute
    // the base directory as `destination.deletingLastPathComponent()`
    // because `downloadFiles` is invoked with `destination =
    // baseDirectory/{slug}`; `persistManifest` re-derives the slug from the
    // manifest itself, anchoring the cache file consistently with
    // `loadCachedManifest(for:in:)`.
    let manifestBaseDirectory = destination.deletingLastPathComponent()
    do {
      try persistManifest(manifest, in: manifestBaseDirectory)
    } catch {
      logger.warning(
        "Failed to persist cached manifest for \(modelId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }

    // EM-1: also persist the byte-equal CDN manifest to
    // `<model-dir>/manifest.json`. REQUIREMENTS §2 invariant — the local
    // file MUST be byte-equal to the wire bytes. This is the on-disk
    // artifact the validity oracle (EM-2) consults. Best-effort: same
    // rationale as the legacy `.acervo-manifest.json` write above.
    do {
      try persistManifestBytes(
        manifestBytes,
        slug: manifest.slug,
        in: manifestBaseDirectory
      )
    } catch {
      logger.warning(
        "Failed to persist byte-equal manifest for \(modelId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }

    // Boundary memory event: emit once per model after the last component
    // is verified (downloaded OR cache-hit). This is the choke-point where
    // all per-file paths (download + integrity verify, or cache-hit skip)
    // have converged; the host adapter wraps this single emission with a
    // memory snapshot to characterize boundary-memory state at the end of
    // model materialization.
    //
    // Adapter routes this event through captureWithMemorySnapshot; library emits normally.
    //
    // CacheMissReason coverage note: only `.notPresent`, `.sizeChangedRemote`,
    // and `.forcedRefresh` fire from the current code path. The two reasons
    // `.shaChangedRemote` and `.corrupted` are reserved for a future
    // verify-on-read path that recomputes the on-disk SHA before any network
    // I/O — they are unreachable from the present cache check, which is
    // size-only. Symbol references retained for enum coverage:
    // AcervoTelemetryEvent.CacheMissReason.shaChangedRemote (reserved),
    // AcervoTelemetryEvent.CacheMissReason.corrupted (reserved).
    if let telemetry {
      let totalSizeMB = Double(totalAllBytes) / 1_048_576.0
      let componentCount = filesToDownload.count
      await telemetry.capture(
        .modelLoadComplete(
          modelID: modelId,
          totalSizeMB: totalSizeMB,
          componentCount: componentCount
        )
      )
    }
  }
}
