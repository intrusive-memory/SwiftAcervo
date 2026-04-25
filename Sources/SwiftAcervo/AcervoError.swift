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

  /// A component ID was not found in the registry.
  case componentNotRegistered(String)

  /// A registered component's files are not yet downloaded.
  case componentNotDownloaded(String)

  /// A file failed SHA-256 integrity verification.
  case integrityCheckFailed(file: String, expected: String, actual: String)

  /// A specific file is missing from a downloaded component's directory.
  case componentFileNotFound(component: String, file: String)

  /// The CDN manifest could not be downloaded.
  case manifestDownloadFailed(statusCode: Int)

  /// The CDN manifest JSON could not be decoded.
  case manifestDecodingFailed(Error)

  /// The manifest's checksum-of-checksums does not match the computed value.
  case manifestIntegrityFailed(expected: String, actual: String)

  /// The manifest declares a version this client does not support.
  case manifestVersionUnsupported(Int)

  /// The manifest's `modelId` field does not match the requested model.
  case manifestModelIdMismatch(expected: String, actual: String)

  /// A downloaded file's size does not match the manifest.
  case downloadSizeMismatch(fileName: String, expected: Int64, actual: Int64)

  /// A requested file is not listed in the CDN manifest.
  case fileNotInManifest(fileName: String, modelId: String)

  /// A caller-supplied local URL does not exist on disk.
  case localPathNotFound(url: URL)

  /// A registered component has no populated file list; `hydrateComponent` must be
  /// called (or use an auto-hydrating entry point) before this operation.
  case componentNotHydrated(id: String)

  /// Offline mode is active (`ACERVO_OFFLINE=1` environment variable is set);
  /// every outbound HTTP fetch is refused. The library continues to serve
  /// resources that are already present in the local SharedModels directory,
  /// but any code path that would otherwise hit the CDN throws this error
  /// instead.
  case offlineModeActive

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

    case .componentNotRegistered(let componentId):
      return "Component not registered: '\(componentId)'"

    case .componentNotDownloaded(let componentId):
      return "Component not downloaded: '\(componentId)'"

    case .integrityCheckFailed(let file, let expected, let actual):
      return "Integrity check failed for '\(file)': expected SHA-256 '\(expected)', got '\(actual)'"

    case .componentFileNotFound(let component, let file):
      return "File '\(file)' not found in component '\(component)'"

    case .manifestDownloadFailed(let statusCode):
      return "CDN manifest download failed with HTTP status code \(statusCode)"

    case .manifestDecodingFailed(let error):
      return "CDN manifest JSON decoding failed: \(error.localizedDescription)"

    case .manifestIntegrityFailed(let expected, let actual):
      return "CDN manifest integrity check failed: expected checksum '\(expected)', got '\(actual)'"

    case .manifestVersionUnsupported(let version):
      return "CDN manifest version \(version) is not supported by this client"

    case .manifestModelIdMismatch(let expected, let actual):
      return "CDN manifest model ID mismatch: expected '\(expected)', got '\(actual)'"

    case .downloadSizeMismatch(let fileName, let expected, let actual):
      return
        "Downloaded file '\(fileName)' size mismatch: expected \(expected) bytes, got \(actual) bytes"

    case .fileNotInManifest(let fileName, let modelId):
      return "File '\(fileName)' is not listed in the CDN manifest for '\(modelId)'"

    case .localPathNotFound(let url):
      return "Local path not found: \(url.path)"

    case .componentNotHydrated(let id):
      return
        "Component '\(id)' has no file list yet. Call Acervo.hydrateComponent(_:) to populate it from the CDN manifest, or use an auto-hydrating API such as ensureComponentReady(_:)."

    case .offlineModeActive:
      return
        "Offline mode is active (ACERVO_OFFLINE=1); the requested resource was not found in the local SharedModels directory."
    }
  }
}
