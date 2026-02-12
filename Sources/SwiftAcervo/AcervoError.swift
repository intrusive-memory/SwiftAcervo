import Foundation

/// Errors that can occur during SwiftAcervo operations.
///
/// All cases provide a human-readable `errorDescription` suitable for
/// display to users or inclusion in log messages.
///
/// ```swift
/// do {
///     let dir = try Acervo.modelDirectory(for: "invalid-id")
/// } catch let error as AcervoError {
///     print(error.errorDescription ?? "Unknown error")
///     // "Invalid model ID 'invalid-id'. Expected format: 'org/repo'"
/// }
/// ```
public enum AcervoError: LocalizedError, Sendable {

    /// Failed to create a required directory at the specified path.
    case directoryCreationFailed(String)

    /// No model found matching the given identifier.
    case modelNotFound(String)

    /// A file download returned a non-200 HTTP status code.
    case downloadFailed(fileName: String, statusCode: Int)

    /// An underlying network error occurred during a download.
    case networkError(Error)

    /// A model already exists at the target location.
    case modelAlreadyExists(String)

    /// Migration from a legacy path failed.
    case migrationFailed(source: String, reason: String)

    /// The provided model ID is not in the expected "org/repo" format.
    case invalidModelId(String)

    public var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path):
            return "Failed to create directory at path: \(path)"

        case .modelNotFound(let modelId):
            return "Model not found: \(modelId)"

        case .downloadFailed(let fileName, let statusCode):
            return "Download failed for '\(fileName)' with HTTP status code \(statusCode)"

        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"

        case .modelAlreadyExists(let modelId):
            return "Model already exists: \(modelId)"

        case .migrationFailed(let source, let reason):
            return "Migration failed for '\(source)': \(reason)"

        case .invalidModelId(let modelId):
            return "Invalid model ID '\(modelId)'. Expected format: 'org/repo'"
        }
    }
}
