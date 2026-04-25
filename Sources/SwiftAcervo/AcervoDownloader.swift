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
  static func ensureDirectory(at url: URL) throws {
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
    session: URLSession = SecureDownloadSession.shared
  ) async throws -> CDNManifest {
    // Refuse the fetch up front when offline mode is active. This must run
    // BEFORE any URLSession call so callers can rely on the gate to keep the
    // process completely offline (no DNS, no socket, no proxy).
    if Acervo.isOfflineModeActive {
      throw AcervoError.offlineModeActive
    }

    let url = buildManifestURL(modelId: modelId)
    let request = buildRequest(from: url)

    // Download manifest using the provided session
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw AcervoError.networkError(error)
    }

    // Verify HTTP 200
    if let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode != 200
    {
      throw AcervoError.manifestDownloadFailed(statusCode: httpResponse.statusCode)
    }

    // Decode JSON
    let manifest: CDNManifest
    do {
      manifest = try JSONDecoder().decode(CDNManifest.self, from: data)
    } catch {
      throw AcervoError.manifestDecodingFailed(error)
    }

    // Validate version
    guard manifest.manifestVersion == CDNManifest.supportedVersion else {
      throw AcervoError.manifestVersionUnsupported(manifest.manifestVersion)
    }

    // Validate model ID matches
    guard manifest.modelId == modelId else {
      throw AcervoError.manifestModelIdMismatch(
        expected: modelId,
        actual: manifest.modelId
      )
    }

    // Verify manifest integrity (checksum-of-checksums)
    let computedChecksum = CDNManifest.computeChecksum(from: manifest.files.map(\.sha256))
    guard manifest.manifestChecksum == computedChecksum else {
      throw AcervoError.manifestIntegrityFailed(
        expected: manifest.manifestChecksum,
        actual: computedChecksum
      )
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
  /// is written in 4 MB chunks to `FileManager.default.temporaryDirectory`
  /// using a UUID-based name.
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
  /// - Throws: `AcervoError.downloadFailed` for non-200 HTTP responses,
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
    session: URLSession = SecureDownloadSession.shared
  ) async throws {
    // Refuse the fetch up front when offline mode is active. This runs
    // BEFORE the URLSession streaming call so the gate is unconditional
    // for every file download, regardless of which public entry point
    // (downloadFile, downloadFiles, hydrateComponent, etc.) routed here.
    if Acervo.isOfflineModeActive {
      throw AcervoError.offlineModeActive
    }

    // Stream the HTTP response using bytes(for:)
    let (asyncBytes, response) = try await session.bytes(for: request)

    // Validate HTTP 200 status before processing bytes
    if let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode != 200
    {
      throw AcervoError.downloadFailed(
        fileName: fileName,
        statusCode: httpResponse.statusCode
      )
    }

    // Use manifest size for accurate progress
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

    // Create UUID-named temp file in temporaryDirectory
    let tempFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)

    // Set up incremental SHA-256 hasher
    var hasher = SHA256()
    var buffer = Data()
    buffer.reserveCapacity(streamChunkSize)
    var bytesWritten: Int64 = 0

    // Ensure temp file is cleaned up on any failure path
    let fm = FileManager.default
    // Create the file so FileHandle can open it for writing
    fm.createFile(atPath: tempFileURL.path, contents: nil)
    let fileHandle: FileHandle
    do {
      fileHandle = try FileHandle(forWritingTo: tempFileURL)
    } catch {
      try? fm.removeItem(at: tempFileURL)
      throw error
    }

    do {
      for try await byte in asyncBytes {
        buffer.append(byte)

        // Flush buffer when it reaches chunk size
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
      // Stream interrupted or write failed -- clean up temp file
      try? fileHandle.close()
      try? fm.removeItem(at: tempFileURL)
      throw error
    }

    // Verify size
    if bytesWritten != manifestFile.sizeBytes {
      try? fm.removeItem(at: tempFileURL)
      throw AcervoError.downloadSizeMismatch(
        fileName: manifestFile.path,
        expected: manifestFile.sizeBytes,
        actual: bytesWritten
      )
    }

    // Finalize hash and verify SHA-256
    let digest = hasher.finalize()
    let actualHash = digest.map { String(format: "%02x", $0) }.joined()
    if actualHash != manifestFile.sha256 {
      try? fm.removeItem(at: tempFileURL)
      throw AcervoError.integrityCheckFailed(
        file: manifestFile.path,
        expected: manifestFile.sha256,
        actual: actualHash
      )
    }

    // Ensure destination's parent directory exists
    let parentDirectory = destination.deletingLastPathComponent()
    try ensureDirectory(at: parentDirectory)

    // Remove any existing file at destination
    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }

    // Atomic move: temp -> destination (file is fully verified at this point)
    try fm.moveItem(at: tempFileURL, to: destination)

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

// MARK: - Fallback Download (Legacy)

extension AcervoDownloader {

  /// Downloads a file using the legacy `download(for:)` + `verifyAgainstManifest` pattern.
  ///
  /// This is the fallback path used when `bytes(for:)` streaming is unavailable
  /// (e.g., the response lacks `Content-Length` or the stream throws).
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
    session: URLSession = SecureDownloadSession.shared
  ) async throws {
    // Refuse the fetch up front when offline mode is active. The streaming
    // path checks the gate too, but `streamDownloadFile` may delegate here
    // on its own initiative when bytes(for:) is unavailable, so we re-check
    // before the legacy URLSession.download call.
    if Acervo.isOfflineModeActive {
      throw AcervoError.offlineModeActive
    }

    // Download the file to a temp location using the provided session
    let tempFileURL: URL
    let response: URLResponse
    do {
      (tempFileURL, response) = try await session.download(for: request)
    } catch {
      throw AcervoError.networkError(error)
    }

    // Verify HTTP 200
    if let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode != 200
    {
      try? FileManager.default.removeItem(at: tempFileURL)
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
    try ensureDirectory(at: parentDirectory)

    // Remove any existing file at destination
    let fm = FileManager.default
    if fm.fileExists(atPath: destination.path) {
      try fm.removeItem(at: destination)
    }

    // Move temp file to destination atomically
    try fm.moveItem(at: tempFileURL, to: destination)

    // Verify integrity: size then SHA-256
    try IntegrityVerification.verifyAgainstManifest(
      fileURL: destination,
      manifestFile: manifestFile
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
    session: URLSession = SecureDownloadSession.shared
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
        session: session
      )
    } catch let streamError {
      // If the error is a verification or HTTP error, propagate immediately
      // (no point falling back -- the data was already bad)
      if streamError is AcervoError {
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
        session: session
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
    session: URLSession = SecureDownloadSession.shared
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
        session: session
      )
    } catch let streamError {
      // If the error is a verification or HTTP error, propagate immediately
      if streamError is AcervoError {
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
        session: session
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
    session: URLSession = SecureDownloadSession.shared
  ) async throws {
    // Step 1: Fetch and validate the manifest
    let manifest = try await downloadManifest(for: modelId, session: session)

    // Step 2: Determine which files to download
    let filesToDownload: [CDNManifestFile]
    if requestedFiles.isEmpty {
      // Download everything in the manifest
      filesToDownload = manifest.files
    } else {
      // Download only requested files, validated against manifest
      filesToDownload = try requestedFiles.map { fileName in
        guard let entry = manifest.file(at: fileName) else {
          throw AcervoError.fileNotInManifest(
            fileName: fileName,
            modelId: modelId
          )
        }
        return entry
      }
    }

    // Step 3: Ensure the top-level destination directory exists
    try ensureDirectory(at: destination)

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

        // Skip if file already exists with the correct size (and force is off).
        if !force && FileManager.default.fileExists(atPath: fileDestination.path) {
          let existingSize = (try? IntegrityVerification.fileSize(at: fileDestination)) ?? -1
          if existingSize == manifestFile.sizeBytes {
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
          // Size mismatch -- file is corrupt or stale, re-download.
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

        group.addTask {
          // Cooperative cancellation inside the child task.
          try Task.checkCancellation()

          try await downloadFile(
            from: capturedURL,
            to: capturedDestination,
            manifestFile: capturedManifestFile,
            fileName: capturedManifestFile.path,
            fileIndex: capturedIndex,
            totalFiles: totalFiles,
            progress: wrappedProgress,
            session: capturedSession
          )
        }

        inFlight += 1
      }

      // Drain any remaining in-flight tasks.  If any of them threw, the
      // error propagates here and the task group cancels the remaining ones.
      try await group.waitForAll()
    }
  }
}
