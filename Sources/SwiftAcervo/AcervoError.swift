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

  /// A manifest entry has a relative path that is empty, absolute, or
  /// contains traversal components (`.` / `..`). Such manifests are
  /// rejected to prevent writing outside the model directory.
  case invalidManifestPath(String)

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

  /// A signed mutation request to the CDN was rejected with HTTP 401 or 403.
  /// The R2 IAM scope is doing its job (read-only key attempting a write,
  /// missing signature, expired credential, etc.); surface clearly so callers
  /// can distinguish "credentials problem" from a transient network error.
  ///
  /// `operation` is a short label identifying which `S3CDNClient` call failed
  /// (`"head"`, `"list"`, `"delete"`, `"deleteObjects"`, etc.).
  case cdnAuthorizationFailed(operation: String)

  /// A signed CDN request failed with a non-2xx response that is not 401/403.
  ///
  /// `operation` is a short label identifying which `S3CDNClient` call failed
  /// (`"head"`, `"list"`, `"delete"`, `"deleteObjects"`, `"put"`,
  /// `"initiateMultipartUpload"`, `"uploadPart"`, `"completeMultipartUpload"`,
  /// `"abortMultipartUpload"`, etc.).
  ///
  /// `statusCode` is the HTTP status code returned by R2/S3, or `200` for
  /// the special case where the response was 2xx but its XML body could not
  /// be parsed (still a failure from the caller's perspective).
  ///
  /// `body` carries the raw response body for caller-side logging. The
  /// `errorDescription` truncates `body` to keep the human-readable string
  /// from leaking large payloads into logs; the full body is always
  /// available on the case payload itself.
  case cdnOperationFailed(operation: String, statusCode: Int, body: String)

  /// One of `publishModel`'s post-upload verification stages (CHECK 4, 5,
  /// or 6 in requirements §7) failed. `stage` identifies which stage —
  /// e.g. `"rehash"`, `"manifest-fetch"`, or `"sample-file"` — so callers
  /// can distinguish a corrupted local staging directory from a CDN
  /// readback discrepancy.
  case publishVerificationFailed(stage: String)

  /// `Acervo.recache(...)`'s caller-supplied `fetchSource` closure threw.
  /// Wrapped here so the recache call site presents a single error type
  /// while preserving the original error for logging.
  case fetchSourceFailed(modelId: String, underlying: any Error)

  /// `ManifestGenerator` (CHECK 2) refused to write a manifest because the
  /// staging directory contains a zero-byte file. `path` is the relative
  /// path of the offender within the staging directory.
  case manifestZeroByteFile(path: String)

  /// `ManifestGenerator` (CHECK 3) wrote `manifest.json` and re-read it,
  /// but the round-tripped manifest's `manifestChecksum` no longer matched
  /// the recomputed checksum. The manifest is removed from disk before
  /// this error is thrown so the caller cannot accidentally publish a
  /// corrupted manifest. `path` is the absolute path that briefly existed.
  case manifestPostWriteCorrupted(path: String)

  /// A file enumerated under a staging base directory could not be
  /// expressed as a relative path under that base. Indicates a path-
  /// representation mismatch between the base URL and the enumerator's
  /// child URL (e.g. `/tmp` vs `/private/tmp`) that survived symlink
  /// resolution. Surfaced as a hard error rather than silently falling
  /// back to `lastPathComponent`, which would produce ambiguous duplicate
  /// paths in the manifest.
  case manifestRelativePathOutsideBase(file: String, base: String)

  /// `publishModel` attempted to delete orphan keys after a successful
  /// publish, but the bulk-delete returned per-key failures. The new
  /// manifest is already live and serving traffic; the orphans are
  /// storage waste, not a correctness bug. `failedKeys` lists every key
  /// the orphan-prune could not remove so the caller can retry that
  /// subset. The published `CDNManifest` is also surfaced so the caller
  /// can return success-with-warnings semantics if desired.
  case publishOrphanPruneFailed(
    failedKeys: [String], publishedManifest: CDNManifest)

  /// Maximum length of the `body` substring included in
  /// `cdnOperationFailed`'s `errorDescription`. Anything longer is
  /// truncated with a hint that the full body is on the case payload.
  /// Kept small (512 chars) so a single error string never bloats logs.
  private static let cdnOperationFailedBodyExcerptLimit: Int = 512

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

    case .invalidManifestPath(let path):
      return
        "CDN manifest contains an invalid file path '\(path)' (must be a non-empty relative path with no '.' or '..' components)"

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

    case .cdnAuthorizationFailed(let operation):
      return
        "CDN authorization failed for operation '\(operation)' (HTTP 401/403). Check that the credentials are scoped to allow this operation."

    case .cdnOperationFailed(let operation, let statusCode, let body):
      let limit = Self.cdnOperationFailedBodyExcerptLimit
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      let bodyHint: String
      if trimmed.isEmpty {
        bodyHint = "(empty body)"
      } else if trimmed.count > limit {
        let prefix = trimmed.prefix(limit)
        bodyHint =
          "\(prefix)… (truncated; full body available on the AcervoError case payload)"
      } else {
        bodyHint = trimmed
      }
      return
        "CDN operation '\(operation)' failed with HTTP status \(statusCode). Response body: \(bodyHint)"

    case .publishVerificationFailed(let stage):
      return
        "Publish verification failed at stage '\(stage)'. The CDN now serves a manifest whose post-upload check did not match the staged content; investigate before retrying."

    case .fetchSourceFailed(let modelId, let underlying):
      return
        "fetchSource closure for model '\(modelId)' threw: \(underlying.localizedDescription)"

    case .manifestZeroByteFile(let path):
      return
        "Refusing to write manifest: zero-byte file in staging at relative path '\(path)' (CHECK 2 failed)."

    case .manifestPostWriteCorrupted(let path):
      return
        "Post-write manifest checksum mismatch at '\(path)' (CHECK 3 failed). The just-written manifest has been deleted; investigate the staging directory before retrying."

    case .manifestRelativePathOutsideBase(let file, let base):
      return
        "Cannot compute relative path: '\(file)' is not contained in '\(base)'. Refusing to fall back to basename, which would produce ambiguous manifest entries for nested layouts."

    case .publishOrphanPruneFailed(let failedKeys, _):
      let preview = failedKeys.prefix(5).joined(separator: ", ")
      let suffix =
        failedKeys.count > 5
        ? " … (\(failedKeys.count - 5) more; full list available on the AcervoError case payload)"
        : ""
      return
        "publishModel succeeded but the orphan-prune step left \(failedKeys.count) key(s) on the CDN: \(preview)\(suffix). The new manifest is live; the orphans are storage waste and can be retried."
    }
  }
}
