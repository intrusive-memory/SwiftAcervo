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
// CDN URL format:
//   https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/{slug}/{fileName}
//
// All downloads use SecureDownloadSession which rejects redirects
// to non-CDN domains.

import Foundation

/// Internal download infrastructure for fetching model files from the CDN.
///
/// All methods are static. This struct is not publicly exposed; consumers
/// use `Acervo.download()` and related public API instead.
struct AcervoDownloader: Sendable {

    /// The base URL for the CDN model repository.
    static let cdnBaseURL = "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models"

    private init() {}
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
    /// - Parameter url: The directory URL to ensure exists.
    /// - Throws: `AcervoError.directoryCreationFailed` if the directory
    ///   cannot be created.
    static func ensureDirectory(at url: URL) throws {
        let fm = FileManager.default

        // Skip if directory already exists
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
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
    /// - Parameter modelId: The model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    /// - Returns: The validated manifest.
    /// - Throws: `AcervoError` for download, decoding, or validation failures.
    static func downloadManifest(for modelId: String) async throws -> CDNManifest {
        let url = buildManifestURL(modelId: modelId)
        let request = buildRequest(from: url)

        // Download manifest using secure session
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await SecureDownloadSession.shared.data(for: request)
        } catch {
            throw AcervoError.networkError(error)
        }

        // Verify HTTP 200
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
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

// MARK: - File Download

extension AcervoDownloader {

    /// Downloads a single file from the CDN to a local destination.
    ///
    /// The file is first downloaded to a temporary location, then moved
    /// atomically to the destination. Intermediate directories at the
    /// destination are created automatically if they do not exist.
    ///
    /// After download, the file is verified against the manifest entry
    /// (size + SHA-256). If verification fails, the file is deleted
    /// and an error is thrown.
    ///
    /// - Parameters:
    ///   - url: The remote CDN URL to download from.
    ///   - destination: The local file URL where the downloaded file should be placed.
    ///   - manifestFile: The manifest entry for this file, used for integrity verification.
    /// - Throws: `AcervoError.downloadFailed` for non-200 HTTP responses,
    ///   `AcervoError.networkError` for connection failures,
    ///   `AcervoError.downloadSizeMismatch` or `AcervoError.integrityCheckFailed`
    ///   if post-download verification fails.
    static func downloadFile(
        from url: URL,
        to destination: URL,
        manifestFile: CDNManifestFile
    ) async throws {
        let request = buildRequest(from: url)

        // Download the file using secure session
        let tempFileURL: URL
        let response: URLResponse
        do {
            (tempFileURL, response) = try await SecureDownloadSession.shared.download(for: request)
        } catch {
            throw AcervoError.networkError(error)
        }

        // Verify HTTP 200
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempFileURL)
            let fileName = url.lastPathComponent
            throw AcervoError.downloadFailed(
                fileName: fileName,
                statusCode: httpResponse.statusCode
            )
        }

        // Ensure the destination's parent directory exists
        let parentDirectory = destination.deletingLastPathComponent()
        try ensureDirectory(at: parentDirectory)

        // Remove any existing file at the destination
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
    }

    /// Downloads a single file from the CDN with progress reporting.
    ///
    /// Uses the same download-then-verify pattern as the non-progress variant.
    ///
    /// - Parameters:
    ///   - url: The remote CDN URL to download from.
    ///   - destination: The local file URL where the downloaded file should be placed.
    ///   - manifestFile: The manifest entry for this file.
    ///   - fileName: The display name for the file (used in progress reporting).
    ///   - fileIndex: The zero-based index of this file in a multi-file download.
    ///   - totalFiles: The total number of files in the download operation.
    ///   - progress: An optional callback invoked with download progress.
    /// - Throws: Download, verification, or directory creation errors.
    static func downloadFile(
        from url: URL,
        to destination: URL,
        manifestFile: CDNManifestFile,
        fileName: String,
        fileIndex: Int,
        totalFiles: Int,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)?
    ) async throws {
        let request = buildRequest(from: url)

        // Download the file to a temp location using secure session
        let tempFileURL: URL
        let response: URLResponse
        do {
            (tempFileURL, response) = try await SecureDownloadSession.shared.download(for: request)
        } catch {
            throw AcervoError.networkError(error)
        }

        // Verify HTTP 200
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            // Clean up temp file
            try? FileManager.default.removeItem(at: tempFileURL)
            let name = url.lastPathComponent
            throw AcervoError.downloadFailed(
                fileName: name,
                statusCode: httpResponse.statusCode
            )
        }

        // Use manifest size for accurate progress (don't rely on Content-Length)
        let totalBytes = manifestFile.sizeBytes

        // Report initial progress
        progress?(AcervoDownloadProgress(
            fileName: fileName,
            bytesDownloaded: 0,
            totalBytes: totalBytes,
            fileIndex: fileIndex,
            totalFiles: totalFiles
        ))

        // Ensure the destination's parent directory exists
        let parentDirectory = destination.deletingLastPathComponent()
        try ensureDirectory(at: parentDirectory)

        // Remove any existing file at the destination
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
        progress?(AcervoDownloadProgress(
            fileName: fileName,
            bytesDownloaded: totalBytes,
            totalBytes: totalBytes,
            fileIndex: fileIndex,
            totalFiles: totalFiles
        ))
    }
}

// MARK: - Multi-File Manifest-Driven Download

extension AcervoDownloader {

    /// Downloads files for a model using the CDN manifest for integrity verification.
    ///
    /// This is the core download method. It:
    /// 1. Fetches and validates the CDN manifest
    /// 2. Filters to the requested files (or all files if none specified)
    /// 3. Downloads each file from the CDN
    /// 4. Verifies each file's size and SHA-256 against the manifest
    ///
    /// Files that already exist and pass verification are skipped unless `force` is `true`.
    ///
    /// - Parameters:
    ///   - modelId: The model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - requestedFiles: Files to download. If empty, downloads ALL files in the manifest.
    ///   - destination: The local directory URL where files should be placed.
    ///   - force: When `true`, re-downloads files even if they already exist. Defaults to `false`.
    ///   - progress: An optional callback invoked with download progress.
    /// - Throws: Manifest, download, or verification errors.
    static func downloadFiles(
        modelId: String,
        requestedFiles: [String],
        destination: URL,
        force: Bool = false,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
    ) async throws {
        // Step 1: Fetch and validate the manifest
        let manifest = try await downloadManifest(for: modelId)

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

        // Step 4: Download and verify each file
        for (fileIndex, manifestFile) in filesToDownload.enumerated() {
            let fileDestination = destination.appendingPathComponent(manifestFile.path)

            // Skip if file already exists, passes size check, and force is not set
            if !force && FileManager.default.fileExists(atPath: fileDestination.path) {
                // Verify existing file against manifest before skipping
                let existingSize = (try? IntegrityVerification.fileSize(at: fileDestination)) ?? -1
                if existingSize == manifestFile.sizeBytes {
                    // Size matches -- skip (full SHA-256 check on skip is optional;
                    // use verifyComponent for deep verification)
                    progress?(AcervoDownloadProgress(
                        fileName: manifestFile.path,
                        bytesDownloaded: manifestFile.sizeBytes,
                        totalBytes: manifestFile.sizeBytes,
                        fileIndex: fileIndex,
                        totalFiles: totalFiles
                    ))
                    continue
                }
                // Size mismatch -- file is corrupt or stale, re-download
            }

            let url = buildURL(modelId: modelId, fileName: manifestFile.path)

            try await downloadFile(
                from: url,
                to: fileDestination,
                manifestFile: manifestFile,
                fileName: manifestFile.path,
                fileIndex: fileIndex,
                totalFiles: totalFiles,
                progress: progress
            )
        }
    }
}
