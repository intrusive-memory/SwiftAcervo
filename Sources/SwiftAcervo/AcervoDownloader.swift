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

  /// Flush-and-hash quantum on the delegate-driven streaming path: bytes
  /// accumulate in an in-memory buffer until they cross this threshold,
  /// then drain into `hasher.update(data:)` + `fileHandle.write(contentsOf:)`
  /// in one shot. Smaller than the legacy 4 MB chunk because the OS picks
  /// I/O sizes for us now (no per-byte amortization need), and smaller
  /// flushes give finer-grained progress callbacks and lower peak memory
  /// per in-flight stream.
  static let streamFlushSize: Int = 256 * 1024

  /// Files smaller than this take the single-request path; larger files
  /// fan out into `parallelRangeCount` concurrent HTTP Range requests.
  /// 64 MB is small enough that 4-way parallelism would only shave
  /// milliseconds, and large enough that single-stream throughput already
  /// saturates most connections.
  static let parallelRangeThreshold: Int64 = 64 * 1024 * 1024

  /// Number of concurrent HTTP Range requests issued per file when the
  /// file exceeds `parallelRangeThreshold`. Matches `maxConcurrentDownloads`
  /// so peak in-flight HTTP requests across the session stays bounded by
  /// `httpMaximumConnectionsPerHost = 8` even with HTTP/2/3 multiplexing.
  static let parallelRangeCount: Int = 4

  /// Maximum number of files downloaded concurrently in `downloadFiles()`.
  ///
  /// This is an internal constant and is intentionally not part of the public API.
  /// Increasing this value improves throughput on fast connections but raises
  /// peak memory usage proportionally.
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
  /// Sets `assumesHTTP3Capable = true` ONLY for requests targeting the
  /// production CDN host so URLSession attempts QUIC on the first request
  /// rather than waiting for `Alt-Svc` discovery on the second.
  /// Cloudflare R2's `pub-*.r2.dev` endpoint advertises HTTP/3, so this
  /// saves 1 RTT cold-start per download. We gate the flag on the host
  /// because applying it indiscriminately (e.g., for mock-protocol test
  /// URLs that share the CDN hostname-pattern but don't actually serve
  /// HTTP/3) materially slows test execution while URLSession negotiates
  /// QUIC against a fake endpoint.
  ///
  /// `assumesHTTP3Capable` is a per-request property in Foundation, not a
  /// session-level config flag — that is why this opt-in lives here rather
  /// than in `SecureDownloadSession.shared`.
  ///
  /// - Parameter url: The remote URL to download from.
  /// - Returns: A configured `URLRequest`.
  static func buildRequest(from url: URL) -> URLRequest {
    var req = URLRequest(url: url)
    if url.host == SecureDownloadDelegate.allowedHost {
      req.assumesHTTP3Capable = true
    }
    return req
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

    return manifest
  }
}

// MARK: - Manifest Persistence (Local Cache)

extension AcervoDownloader {

  /// Filename for the locally-cached copy of the CDN manifest, stored at the
  /// root of each model's directory. Hidden (leading dot) to keep it from
  /// appearing in casual listings, but otherwise a regular file.
  static let cachedManifestFilename = ".acervo-manifest.json"

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

// MARK: - Stream State (shared by single-request and parallel-range paths)

/// Mutable state shared between `streamDownloadFile` and its helper
/// functions. Class-based so the helpers can mutate without requiring
/// `inout` across `async` boundaries.
private final class StreamState: @unchecked Sendable {
  var hasher: SHA256
  var bytesWritten: Int64

  init(hasher: SHA256, bytesWritten: Int64) {
    self.hasher = hasher
    self.bytesWritten = bytesWritten
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

    // Decide whether to use the single-request path or the parallel-range
    // path. Parallelization applies only to large files (> threshold) AND
    // only when the diagnostics override is not engaged. Resumed downloads
    // still parallelize across the remaining tail.
    let useParallelRanges =
      manifestFile.sizeBytes > parallelRangeThreshold
      && !SecureDownloadSession.parallelRangesDisabled
      && parallelRangeCount > 1

    // Open the part file for writing. Same setup for both paths.
    if !fm.fileExists(atPath: partURL.path) {
      fm.createFile(atPath: partURL.path, contents: nil)
    }
    let fileHandle: FileHandle
    do {
      fileHandle = try FileHandle(forWritingTo: partURL)
    } catch {
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

    let state = StreamState(hasher: hasher, bytesWritten: bytesWritten)

    do {
      if useParallelRanges {
        try await runParallelRangeStream(
          request: request,
          fileHandle: fileHandle,
          partURL: partURL,
          manifestFile: manifestFile,
          fileName: fileName,
          fileIndex: fileIndex,
          totalFiles: totalFiles,
          totalBytes: totalBytes,
          resumeOffset: resumeOffset,
          state: state,
          progress: progress,
          session: session,
          telemetry: telemetry
        )
      } else {
        try await runSingleRequestStream(
          request: request,
          fileHandle: fileHandle,
          manifestFile: manifestFile,
          fileName: fileName,
          fileIndex: fileIndex,
          totalFiles: totalFiles,
          totalBytes: totalBytes,
          resumeOffset: resumeOffset,
          state: state,
          progress: progress,
          session: session,
          telemetry: telemetry
        )
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
    if state.bytesWritten != manifestFile.sizeBytes {
      try? fm.removeItem(at: partURL)
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .fileDownloadSize,
            errorDescription:
              "Size mismatch for \(manifestFile.path): expected \(manifestFile.sizeBytes), got \(state.bytesWritten)",
            modelID: nil,
            fileName: manifestFile.path
          ))
      }
      throw AcervoError.downloadSizeMismatch(
        fileName: manifestFile.path,
        expected: manifestFile.sizeBytes,
        actual: state.bytesWritten
      )
    }

    // Finalize hash and verify SHA-256 — DELETE on validated corruption.
    let digest = state.hasher.finalize()
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

  /// Drives the single-request streaming path: one `URLSessionDataTask`,
  /// chunks delivered via the session's `SecureDownloadDelegate`, buffered
  /// into `streamFlushSize`-sized flushes that hit both the SHA-256 hasher
  /// and the part file's `FileHandle` in one shot.
  ///
  /// Handles the "Range header sent but server returned 200" case by
  /// resetting the hasher and truncating the part file before consuming
  /// the body from offset 0.
  fileprivate static func runSingleRequestStream(
    request: URLRequest,
    fileHandle: FileHandle,
    manifestFile: CDNManifestFile,
    fileName: String,
    fileIndex: Int,
    totalFiles: Int,
    totalBytes: Int64,
    resumeOffset: Int64,
    state: StreamState,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)?,
    session: URLSession,
    telemetry: (any AcervoTelemetryReporter)?
  ) async throws {
    // Build the effective request, attaching a `Range` header only when we
    // have valid partial bytes to resume from.
    var effectiveRequest = request
    let didSendRangeHeader = (resumeOffset > 0)
    if didSendRangeHeader {
      effectiveRequest.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
    }

    let (stream, task, consumer): (
      AsyncThrowingStream<Data, Error>, URLSessionDataTask, ChunkConsumer
    ) = try session.chunkedDownload(for: effectiveRequest)

    // Seek the handle to the right starting offset BEFORE the first chunk
    // arrives. If we sent Range and the server honors it (206), we resume
    // at `resumeOffset`. If the server ignores Range (200), we will reset
    // and rewind below once we see the status code on the first chunk.
    if resumeOffset > 0 {
      do {
        try fileHandle.seek(toOffset: UInt64(resumeOffset))
      } catch {
        task.cancel()
        throw error
      }
    }

    // The initial progress callback fires when the first chunk arrives,
    // NOT before the network call returns. This preserves the legacy
    // contract that a failed connection (e.g., unreachable host) never
    // surfaces a progress event.

    var buffer = Data()
    buffer.reserveCapacity(streamFlushSize)
    var sawFirstChunk = false
    var serverIgnoredRange = false

    do {
      for try await chunk in stream {
        if !sawFirstChunk {
          sawFirstChunk = true
          if let status = consumer.responseStatus {
            switch status {
            case 200:
              if didSendRangeHeader {
                // Server ignored our Range header — reset and consume from
                // start.
                serverIgnoredRange = true
                state.hasher = SHA256()
                try fileHandle.truncate(atOffset: 0)
                try fileHandle.seek(toOffset: 0)
                state.bytesWritten = 0
              }
            case 206:
              break  // expected when Range was sent; nothing to do
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
              task.cancel()
              throw AcervoError.downloadFailed(
                fileName: fileName,
                statusCode: status
              )
            }
          }
          // Fire the initial progress event only after we have evidence
          // the connection produced a usable response. This factors the
          // resume offset into the byte counter so consumers see
          // continuous progress across attempts.
          progress?(
            AcervoDownloadProgress(
              fileName: fileName,
              bytesDownloaded: state.bytesWritten,
              totalBytes: totalBytes,
              fileIndex: fileIndex,
              totalFiles: totalFiles
            ))
        }

        buffer.append(chunk)
        if buffer.count >= streamFlushSize {
          state.hasher.update(data: buffer)
          try fileHandle.write(contentsOf: buffer)
          state.bytesWritten += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)
          progress?(
            AcervoDownloadProgress(
              fileName: fileName,
              bytesDownloaded: state.bytesWritten,
              totalBytes: totalBytes,
              fileIndex: fileIndex,
              totalFiles: totalFiles
            ))
        }
      }

      // Tail flush.
      if !buffer.isEmpty {
        state.hasher.update(data: buffer)
        try fileHandle.write(contentsOf: buffer)
        state.bytesWritten += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
      }
    } catch {
      // If the stream ended because we cancelled on a non-2xx/206 status,
      // surface the HTTP error in preference to the underlying URL error.
      if let status = consumer.responseStatus,
        status != 200, status != 206, !(error is AcervoError)
      {
        if let telemetry {
          await telemetry.capture(
            .errorThrown(
              phase: .fileDownload,
              errorDescription: "File download failed with HTTP \(status)",
              modelID: nil,
              fileName: fileName
            ))
        }
        throw AcervoError.downloadFailed(fileName: fileName, statusCode: status)
      }
      throw error
    }

    // If we saw zero chunks but the response status indicates failure (empty
    // body 4xx/5xx), surface as a download error.
    if !sawFirstChunk, let status = consumer.responseStatus,
      status != 200, status != 206
    {
      throw AcervoError.downloadFailed(fileName: fileName, statusCode: status)
    }

    // If we sent Range but never saw a status (no chunks, no error) the
    // server-ignored-range branch could not run; nothing else to do.
    _ = serverIgnoredRange
  }

  /// Drives the parallel-range streaming path: splits the file's tail
  /// (`[resumeOffset, sizeBytes)`) into `parallelRangeCount` equal sub-ranges,
  /// fires one `URLSessionDataTask` per sub-range, and writes their bytes
  /// directly to the `.part` file at the correct seek offsets.
  ///
  /// A separate hasher coordinator walks the part file in order, hashing
  /// contiguous bytes from `hashedThrough` as they become available, so
  /// SHA-256 sees the file in the canonical byte order. Memory budget per
  /// in-flight file is bounded by `streamFlushSize × parallelRangeCount` (~1 MB).
  fileprivate static func runParallelRangeStream(
    request: URLRequest,
    fileHandle: FileHandle,
    partURL: URL,
    manifestFile: CDNManifestFile,
    fileName: String,
    fileIndex: Int,
    totalFiles: Int,
    totalBytes: Int64,
    resumeOffset: Int64,
    state: StreamState,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)?,
    session: URLSession,
    telemetry: (any AcervoTelemetryReporter)?
  ) async throws {
    let tailStart = resumeOffset
    let tailEnd = manifestFile.sizeBytes  // exclusive
    let tailLength = tailEnd - tailStart
    precondition(tailLength > 0, "parallel-range path entered with empty tail")

    // Split tail into N sub-ranges. Last absorbs remainder.
    let count = Int64(parallelRangeCount)
    let baseChunk = tailLength / count
    var subRanges: [(start: Int64, end: Int64)] = []
    subRanges.reserveCapacity(parallelRangeCount)
    for i in 0..<parallelRangeCount {
      let s = tailStart + Int64(i) * baseChunk
      let e = (i == parallelRangeCount - 1) ? tailEnd : (s + baseChunk)
      subRanges.append((s, e))
    }

    // The inherited writable file handle is flushed; the parallel-range
    // writer below opens its own handle for the duration of the multi-range
    // transfer (and seeks per write under a lock). The caller still closes
    // the inherited handle on exit; closing a second handle to the same
    // file is benign on macOS/iOS.
    try fileHandle.synchronize()

    // Writer guards concurrent `seek` + `write` to the part file with an
    // NSLock. One shared writer per file; per-range tasks call `write(at:)`.
    let writer = PartFileWriter(partURL: partURL)
    try writer.open()

    // Coordinator advances `hashedThrough` as contiguous bytes complete.
    let coordinator = HasherCoordinator(
      partURL: partURL,
      startOffset: tailStart,
      endOffset: tailEnd,
      state: state,
      manifestFile: manifestFile,
      fileName: fileName,
      fileIndex: fileIndex,
      totalFiles: totalFiles,
      totalBytes: totalBytes,
      progress: progress
    )

    // Initial progress (resume bytes already counted via state.bytesWritten).
    progress?(
      AcervoDownloadProgress(
        fileName: fileName,
        bytesDownloaded: state.bytesWritten,
        totalBytes: totalBytes,
        fileIndex: fileIndex,
        totalFiles: totalFiles
      ))

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for sub in subRanges {
          group.addTask {
            try await Self.runRangeSubTask(
              request: request,
              subStart: sub.start,
              subEnd: sub.end,
              writer: writer,
              coordinator: coordinator,
              session: session,
              fileName: fileName,
              telemetry: telemetry
            )
          }
        }
        try await group.waitForAll()
      }
    } catch {
      writer.close()
      throw error
    }

    // Drain the coordinator: hash any contiguous bytes that arrived after
    // the last advance.
    try coordinator.finalizeAfterAllRangesComplete()
    writer.close()
  }

  /// Runs one parallel-range sub-task. Streams `Range: bytes={start}-{end-1}`,
  /// writes each chunk to the part file at the correct offset, and signals
  /// the hasher coordinator after every successful write so it can advance
  /// `hashedThrough` whenever contiguous bytes become available.
  fileprivate static func runRangeSubTask(
    request: URLRequest,
    subStart: Int64,
    subEnd: Int64,
    writer: PartFileWriter,
    coordinator: HasherCoordinator,
    session: URLSession,
    fileName: String,
    telemetry: (any AcervoTelemetryReporter)?
  ) async throws {
    var rangedRequest = request
    rangedRequest.setValue(
      "bytes=\(subStart)-\(subEnd - 1)", forHTTPHeaderField: "Range")

    let (stream, task, consumer) = try session.chunkedDownload(for: rangedRequest)
    var writeOffset = subStart

    do {
      for try await chunk in stream {
        if let status = consumer.responseStatus,
          status != 206 && status != 200
        {
          // Non-success / non-partial. Cancel and surface.
          task.cancel()
          if let telemetry {
            await telemetry.capture(
              .errorThrown(
                phase: .fileDownload,
                errorDescription:
                  "Parallel-range download failed with HTTP \(status) for range \(subStart)-\(subEnd - 1)",
                modelID: nil,
                fileName: fileName
              ))
          }
          throw AcervoError.downloadFailed(fileName: fileName, statusCode: status)
        }
        try writer.write(data: chunk, at: writeOffset)
        writeOffset += Int64(chunk.count)
        try coordinator.signalChunkComplete(throughOffset: writeOffset)
      }
    } catch {
      // If the consumer captured a non-success status, surface it as the
      // HTTP error rather than the underlying transport error.
      if let status = consumer.responseStatus,
        status != 200, status != 206, !(error is AcervoError)
      {
        throw AcervoError.downloadFailed(fileName: fileName, statusCode: status)
      }
      throw error
    }

    // Sub-range write completed — guarantee we wrote exactly the bytes we
    // were promised. Off-by-one here is the highest-risk parallel-range
    // bug, so it must fail loudly.
    if writeOffset != subEnd {
      throw AcervoError.downloadSizeMismatch(
        fileName: fileName,
        expected: subEnd - subStart,
        actual: writeOffset - subStart
      )
    }
  }
}

// MARK: - Parallel-Range Plumbing

/// Lock-guarded sparse writer for the `.part` file. Multiple sub-range tasks
/// hand their chunks here and the writer serializes the seek+write pair.
private final class PartFileWriter: @unchecked Sendable {
  private let partURL: URL
  private let lock = NSLock()
  private var handle: FileHandle?

  init(partURL: URL) {
    self.partURL = partURL
  }

  func open() throws {
    lock.lock()
    defer { lock.unlock() }
    self.handle = try FileHandle(forWritingTo: partURL)
  }

  func write(data: Data, at offset: Int64) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let h = handle else {
      throw AcervoError.networkError(
        NSError(
          domain: "SwiftAcervo",
          code: -2,
          userInfo: [NSLocalizedDescriptionKey: "PartFileWriter handle is nil"]
        ))
    }
    try h.seek(toOffset: UInt64(offset))
    try h.write(contentsOf: data)
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    try? handle?.synchronize()
    try? handle?.close()
    handle = nil
  }
}

/// Maintains `hashedThrough` for the parallel-range path. Sub-range tasks
/// announce write-completion offsets; the coordinator reads contiguous
/// bytes from the part file in 64 KB increments and feeds them into the
/// hasher in canonical order.
private final class HasherCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private let partURL: URL
  private let startOffset: Int64
  private let endOffset: Int64
  private var hashedThrough: Int64
  private var pendingFrontier: Int64
  private let state: StreamState
  private let manifestFile: CDNManifestFile
  private let fileName: String
  private let fileIndex: Int
  private let totalFiles: Int
  private let totalBytes: Int64
  private let progress: (@Sendable (AcervoDownloadProgress) -> Void)?

  /// Read-back chunk size when feeding the hasher from disk. 64 KB is small
  /// enough to keep transient peak memory negligible and large enough that
  /// the syscall amortizes cleanly.
  private static let readBackChunkSize: Int = 64 * 1024

  init(
    partURL: URL,
    startOffset: Int64,
    endOffset: Int64,
    state: StreamState,
    manifestFile: CDNManifestFile,
    fileName: String,
    fileIndex: Int,
    totalFiles: Int,
    totalBytes: Int64,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)?
  ) {
    self.partURL = partURL
    self.startOffset = startOffset
    self.endOffset = endOffset
    self.hashedThrough = startOffset
    self.pendingFrontier = startOffset
    self.state = state
    self.manifestFile = manifestFile
    self.fileName = fileName
    self.fileIndex = fileIndex
    self.totalFiles = totalFiles
    self.totalBytes = totalBytes
    self.progress = progress
  }

  /// Called by a sub-range task after writing a chunk that completes
  /// `[oldOffset, throughOffset)` on disk. Atomically advances
  /// `pendingFrontier` and, if the new high-water mark equals `hashedThrough`,
  /// drives the hasher forward over the newly-contiguous bytes.
  func signalChunkComplete(throughOffset: Int64) throws {
    lock.lock()
    defer { lock.unlock() }
    if throughOffset > pendingFrontier {
      pendingFrontier = throughOffset
    }
    try drainContiguousLocked()
  }

  /// Final drain after every sub-range completes. Pulls the remaining
  /// contiguous tail into the hasher in case the last signal lagged.
  func finalizeAfterAllRangesComplete() throws {
    lock.lock()
    defer { lock.unlock() }
    pendingFrontier = endOffset
    try drainContiguousLocked()
  }

  private func drainContiguousLocked() throws {
    // Sub-range tasks announce non-monotonic frontiers — a late chunk for
    // range 0 can leave `pendingFrontier == hashedThrough` until range 0
    // catches up. We only consume bytes where `hashedThrough < frontier`,
    // and only as far forward as the on-disk file actually has bytes (the
    // earliest range governs this).
    guard pendingFrontier > hashedThrough else { return }

    let readHandle = try FileHandle(forReadingFrom: partURL)
    defer { try? readHandle.close() }

    // We hash only contiguous bytes starting from `hashedThrough`. Without
    // a global "all ranges before X are written" signal, we conservatively
    // assume the earliest range's frontier is what's truly contiguous. The
    // simpler invariant: we only advance up to `pendingFrontier`, and that
    // value is the *maximum* offset any range has reached. To preserve
    // contiguity we read until we either hit `pendingFrontier` or read
    // fewer bytes than requested (which would indicate a sparse gap).
    try readHandle.seek(toOffset: UInt64(hashedThrough))
    var remaining = pendingFrontier - hashedThrough
    while remaining > 0 {
      let want = Int(min(Int64(Self.readBackChunkSize), remaining))
      let chunk = readHandle.readData(ofLength: want)
      if chunk.isEmpty { break }
      state.hasher.update(data: chunk)
      hashedThrough += Int64(chunk.count)
      state.bytesWritten += Int64(chunk.count)
      remaining -= Int64(chunk.count)
      if chunk.count < want {
        // Short read — disk doesn't have the bytes yet (sparse hole). Stop
        // here; a later signal will pull the rest.
        break
      }
    }

    progress?(
      AcervoDownloadProgress(
        fileName: fileName,
        bytesDownloaded: state.bytesWritten,
        totalBytes: totalBytes,
        fileIndex: fileIndex,
        totalFiles: totalFiles
      ))
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
    // Step 1: Fetch and validate the manifest
    let manifest = try await downloadManifest(for: modelId, session: session, telemetry: telemetry)

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
