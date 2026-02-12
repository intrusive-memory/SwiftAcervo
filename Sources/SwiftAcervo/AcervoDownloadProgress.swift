import Foundation

/// Progress information for a model download operation.
///
/// Tracks the progress of downloading individual files within a multi-file
/// download operation, including byte-level progress for the current file
/// and file-level progress across the entire operation.
///
/// ```swift
/// try await Acervo.download("mlx-community/Qwen2.5-7B-Instruct-4bit",
///     files: ["config.json", "model.safetensors"]
/// ) { progress in
///     print("\(progress.fileName): \(Int(progress.overallProgress * 100))%")
/// }
/// ```
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

    /// The overall progress of the entire download operation as a value from 0.0 to 1.0.
    ///
    /// Combines file-level progress (which file we are on) with byte-level progress
    /// (how much of the current file has been downloaded). If `totalBytes` is `nil`,
    /// the current file's byte progress is treated as 0.0.
    ///
    /// The result is clamped to the range `0.0...1.0`.
    public var overallProgress: Double {
        guard totalFiles > 0 else { return 0.0 }

        let fileProgress: Double
        if let totalBytes, totalBytes > 0 {
            fileProgress = Double(bytesDownloaded) / Double(totalBytes)
        } else {
            fileProgress = 0.0
        }

        let raw = (Double(fileIndex) + fileProgress) / Double(totalFiles)
        return min(max(raw, 0.0), 1.0)
    }
}
