// AcervoDownloader.swift
// SwiftAcervo
//
// Internal download infrastructure for fetching HuggingFace model files.
//
// AcervoDownloader provides static helpers for constructing HuggingFace
// download URLs, ensuring local directories exist, and downloading
// individual files with optional authentication. This type is internal
// to the package; the public download API lives on `Acervo`.
//
// URL format:
//   https://huggingface.co/{modelId}/resolve/main/{fileName}
//
// Auth header (for gated models):
//   Authorization: Bearer {token}

import Foundation

/// Internal download infrastructure for fetching HuggingFace model files.
///
/// All methods are static. This struct is not publicly exposed; consumers
/// use `Acervo.download()` and related public API instead.
struct AcervoDownloader: Sendable {

    /// The base URL for the HuggingFace model repository.
    static let huggingFaceBaseURL = "https://huggingface.co"

    private init() {}
}

// MARK: - URL Construction

extension AcervoDownloader {

    /// Constructs the HuggingFace download URL for a specific file in a model repository.
    ///
    /// The URL follows the HuggingFace pattern:
    /// `https://huggingface.co/{modelId}/resolve/main/{fileName}`
    ///
    /// Subdirectory files are supported. For example, a `fileName` of
    /// `"speech_tokenizer/config.json"` produces a URL with the subdirectory
    /// path preserved in the URL path.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - fileName: The file name or relative path within the model repository
    ///     (e.g., "config.json" or "speech_tokenizer/config.json").
    /// - Returns: The fully qualified download URL.
    static func buildURL(modelId: String, fileName: String) -> URL {
        // Build the URL by appending path components to avoid encoding issues.
        // modelId contains a "/" (e.g., "org/repo") which is a valid path separator.
        var url = URL(string: huggingFaceBaseURL)!
            .appendingPathComponent(modelId)
            .appendingPathComponent("resolve")
            .appendingPathComponent("main")

        // Handle subdirectory files by appending each path component separately
        let pathComponents = fileName.split(separator: "/").map(String.init)
        for component in pathComponents {
            url = url.appendingPathComponent(component)
        }

        return url
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

// MARK: - File Download

extension AcervoDownloader {

    /// Constructs a `URLRequest` for downloading a file, optionally including
    /// a Bearer authorization header.
    ///
    /// This is extracted as a separate method to enable unit testing of
    /// request construction without making network calls.
    ///
    /// - Parameters:
    ///   - url: The remote URL to download from.
    ///   - token: An optional HuggingFace API token for gated model access.
    /// - Returns: A configured `URLRequest`.
    static func buildRequest(from url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Downloads a single file from a remote URL to a local destination.
    ///
    /// The file is first downloaded to a temporary location, then moved
    /// atomically to the destination. Intermediate directories at the
    /// destination are created automatically if they do not exist.
    ///
    /// If the server responds with a non-200 HTTP status code, this method
    /// throws `AcervoError.downloadFailed`. Network-level errors are wrapped
    /// in `AcervoError.networkError`.
    ///
    /// - Parameters:
    ///   - url: The remote URL to download from.
    ///   - destination: The local file URL where the downloaded file should be placed.
    ///   - token: An optional HuggingFace API token for gated model access.
    ///     When provided, an `Authorization: Bearer {token}` header is added.
    /// - Throws: `AcervoError.downloadFailed` for non-200 HTTP responses,
    ///   `AcervoError.networkError` for connection failures,
    ///   `AcervoError.directoryCreationFailed` if intermediate directories
    ///   cannot be created.
    static func downloadFile(
        from url: URL,
        to destination: URL,
        token: String?
    ) async throws {
        let request = buildRequest(from: url, token: token)

        // Download the file
        let tempFileURL: URL
        let response: URLResponse
        do {
            (tempFileURL, response) = try await URLSession.shared.download(for: request)
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
    }

    /// Downloads a single file from a remote URL to a local destination,
    /// reporting progress via a callback.
    ///
    /// Uses `URLSession.bytes(for:)` to stream the response, writing chunks
    /// to a temporary file and reporting byte-level progress along the way.
    /// Once the download is complete, the temporary file is moved atomically
    /// to the final destination.
    ///
    /// If the server responds with a non-200 HTTP status code, this method
    /// throws `AcervoError.downloadFailed`. Network-level errors are wrapped
    /// in `AcervoError.networkError`.
    ///
    /// - Parameters:
    ///   - url: The remote URL to download from.
    ///   - destination: The local file URL where the downloaded file should be placed.
    ///   - token: An optional HuggingFace API token for gated model access.
    ///   - fileName: The display name for the file (used in progress reporting).
    ///   - fileIndex: The zero-based index of this file in a multi-file download.
    ///   - totalFiles: The total number of files in the download operation.
    ///   - progress: An optional callback invoked periodically with download progress.
    ///     Must be `@Sendable` for Swift 6 strict concurrency.
    /// - Throws: `AcervoError.downloadFailed` for non-200 HTTP responses,
    ///   `AcervoError.networkError` for connection failures,
    ///   `AcervoError.directoryCreationFailed` if intermediate directories
    ///   cannot be created.
    static func downloadFile(
        from url: URL,
        to destination: URL,
        token: String?,
        fileName: String,
        fileIndex: Int,
        totalFiles: Int,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)?
    ) async throws {
        let request = buildRequest(from: url, token: token)

        // Use bytes API for streaming progress
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw AcervoError.networkError(error)
        }

        // Verify HTTP 200
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            let name = url.lastPathComponent
            throw AcervoError.downloadFailed(
                fileName: name,
                statusCode: httpResponse.statusCode
            )
        }

        // Get expected content length (may be -1 / unknown)
        let expectedLength = response.expectedContentLength
        let totalBytes: Int64? = expectedLength > 0 ? expectedLength : nil

        // Ensure the destination's parent directory exists
        let parentDirectory = destination.deletingLastPathComponent()
        try ensureDirectory(at: parentDirectory)

        // Write to a temporary file while streaming
        let tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempFileURL)
        defer { try? fileHandle.close() }

        var bytesDownloaded: Int64 = 0
        // Buffer size for progress reporting (64 KB chunks)
        let reportInterval: Int64 = 65_536
        var bytesSinceLastReport: Int64 = 0
        var buffer = Data()
        let bufferFlushSize = 262_144 // 256 KB

        // Report initial progress
        progress?(AcervoDownloadProgress(
            fileName: fileName,
            bytesDownloaded: 0,
            totalBytes: totalBytes,
            fileIndex: fileIndex,
            totalFiles: totalFiles
        ))

        for try await byte in bytes {
            buffer.append(byte)

            if buffer.count >= bufferFlushSize {
                fileHandle.write(buffer)
                bytesDownloaded += Int64(buffer.count)
                bytesSinceLastReport += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                // Report progress periodically
                if bytesSinceLastReport >= reportInterval {
                    bytesSinceLastReport = 0
                    progress?(AcervoDownloadProgress(
                        fileName: fileName,
                        bytesDownloaded: bytesDownloaded,
                        totalBytes: totalBytes,
                        fileIndex: fileIndex,
                        totalFiles: totalFiles
                    ))
                }
            }
        }

        // Flush remaining buffer
        if !buffer.isEmpty {
            fileHandle.write(buffer)
            bytesDownloaded += Int64(buffer.count)
        }

        try fileHandle.close()

        // Report final progress
        progress?(AcervoDownloadProgress(
            fileName: fileName,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes ?? bytesDownloaded,
            fileIndex: fileIndex,
            totalFiles: totalFiles
        ))

        // Remove any existing file at the destination
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        // Move temp file to destination atomically
        try fm.moveItem(at: tempFileURL, to: destination)
    }
}
