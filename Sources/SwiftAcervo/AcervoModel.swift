import Foundation

/// Metadata for a downloaded HuggingFace model.
///
/// Represents a model stored in the shared models directory with its
/// HuggingFace identifier, local filesystem path, size, and download date.
/// Conforms to `Identifiable` (keyed by HuggingFace ID), `Equatable`,
/// `Codable`, and `Sendable`.
public struct AcervoModel: Identifiable, Equatable, Codable, Sendable {

    /// The HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    public let id: String

    /// The local filesystem URL of the model directory.
    public let path: URL

    /// The total size of all files in the model directory, in bytes.
    public let sizeBytes: Int64

    /// The date when the model was downloaded (directory creation date).
    public let downloadDate: Date

    /// Creates a new model metadata instance.
    ///
    /// - Parameters:
    ///   - id: The HuggingFace model identifier.
    ///   - path: The local filesystem URL of the model directory.
    ///   - sizeBytes: The total size of all files in bytes.
    ///   - downloadDate: The date the model was downloaded.
    public init(
        id: String,
        path: URL,
        sizeBytes: Int64,
        downloadDate: Date
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.downloadDate = downloadDate
    }
}
