import Foundation

/// Progress information for a model download operation.
///
/// Tracks the progress of downloading individual files within a multi-file
/// download operation, including byte-level progress for the current file
/// and file-level progress across the entire operation.
public struct AcervoDownloadProgress: Sendable {

    /// The name of the file currently being downloaded.
    ///
    /// May include subdirectory components (e.g., "speech_tokenizer/config.json").
    public let fileName: String

    /// The number of bytes downloaded so far for the current file.
    public let bytesDownloaded: Int64

    /// The expected total size in bytes for the current file, or `nil` if unknown.
    public let totalBytes: Int64?

    /// The zero-based index of the current file in the download list.
    public let fileIndex: Int

    /// The total number of files being downloaded in this operation.
    public let totalFiles: Int

    /// Creates a new download progress instance.
    ///
    /// - Parameters:
    ///   - fileName: The name of the file currently being downloaded.
    ///   - bytesDownloaded: The number of bytes downloaded so far for the current file.
    ///   - totalBytes: The expected total size in bytes, or `nil` if unknown.
    ///   - fileIndex: The zero-based index of the current file in the download list.
    ///   - totalFiles: The total number of files being downloaded.
    public init(
        fileName: String,
        bytesDownloaded: Int64,
        totalBytes: Int64?,
        fileIndex: Int,
        totalFiles: Int
    ) {
        self.fileName = fileName
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.fileIndex = fileIndex
        self.totalFiles = totalFiles
    }
}
