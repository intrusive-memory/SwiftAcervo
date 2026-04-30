import Foundation

/// Errors raised while reconciling a freshly-downloaded file against the
/// authoritative HuggingFace LFS metadata record.
enum HFIntegrityError: Error, CustomStringConvertible {

  /// The SHA-256 advertised by HuggingFace (`oid` field) did not match
  /// the hash computed locally from the staging file.
  case checksumMismatch(filename: String, expected: String, actual: String)

  /// The HuggingFace LFS API returned a non-2xx HTTP status.
  case httpError(statusCode: Int, filename: String)

  /// The HuggingFace LFS API responded without a decodable `oid` field.
  case missingOID(filename: String)

  var description: String {
    switch self {
    case .checksumMismatch(let filename, let expected, let actual):
      return
        "HF LFS checksum mismatch for \(filename): expected \(expected), got \(actual)"
    case .httpError(let status, let filename):
      return "HF LFS API returned HTTP \(status) for \(filename)"
    case .missingOID(let filename):
      return "HF LFS API response for \(filename) is missing the 'oid' field"
    }
  }
}

/// Static hints surfaced when LFS verification fails in patterns that
/// map to operator-actionable conditions.
enum LFSVerificationHints {
  /// When every file-level `verifyLFS` call returned HTTP 404, the
  /// repo almost certainly is not Git LFS-backed: the LFS metadata
  /// endpoint exists per file, and a 404 across the entire repo means
  /// none of the files are tracked by LFS. Surface this as a clear
  /// hint so the operator knows to pass `--no-verify` instead of
  /// staring at a wall of `HTTP 404 for <filename>` errors.
  static let notLFSBackedHint =
    """

    hint: every file returned HTTP 404 from the HuggingFace LFS API.
          This typically means the repo is not Git LFS-backed (for
          example: lmstudio-community/* and aydin99/*). Pass
          --no-verify to skip CHECK 1 for non-LFS repos.

    """
}

/// Talks to HuggingFace's LFS metadata endpoint to reconcile downloaded
/// bytes against the authoritative `oid` (SHA-256) that HF publishes.
///
/// This is the implementation of **CHECK 1** in the acervo tool
/// requirements: before any staged file is promoted, its locally-computed
/// SHA-256 is compared against `oid` returned from
/// `https://huggingface.co/api/models/<model-id>/lfs/<filename>`. On
/// mismatch the staging file is deleted and `HFIntegrityError` is thrown,
/// aborting the pipeline.
actor HuggingFaceClient {

  /// JSON shape returned by the HF LFS metadata endpoint. The API returns
  /// additional fields we do not use; only `oid` and `size` are decoded.
  private struct LFSResponse: Decodable {
    let oid: String
    let size: Int64?
  }

  private let session: URLSession
  private let apiBase: URL

  init(
    session: URLSession = .shared,
    apiBase: URL = URL(string: "https://huggingface.co/api/models")!
  ) {
    self.session = session
    self.apiBase = apiBase
  }

  /// Verifies that `actualSHA256` matches the `oid` HuggingFace advertises
  /// for `<modelId>/<filename>`. On mismatch deletes the staging file and
  /// throws `HFIntegrityError.checksumMismatch`.
  ///
  /// - Parameters:
  ///   - modelId: `org/repo` HuggingFace model identifier.
  ///   - filename: File path relative to the repo root (e.g. `config.json`
  ///     or `pytorch_model-00001-of-00002.bin`).
  ///   - actualSHA256: Lowercase hex SHA-256 computed locally via
  ///     `IntegrityVerification.sha256(of:)`.
  ///   - stagingURL: Local file URL that will be removed on mismatch.
  /// - Throws: `HFIntegrityError` on mismatch, missing `oid`, bad HTTP
  ///   status, or network failure.
  func verifyLFS(
    modelId: String,
    filename: String,
    actualSHA256: String,
    stagingURL: URL
  ) async throws {
    let url = buildLFSURL(modelId: modelId, filename: filename)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    // Only attach bearer credentials when an HF_TOKEN is explicitly set
    // in the environment. Never echo the token value.
    if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await session.data(for: request)

    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw HFIntegrityError.httpError(statusCode: http.statusCode, filename: filename)
    }

    let decoded: LFSResponse
    do {
      decoded = try JSONDecoder().decode(LFSResponse.self, from: data)
    } catch {
      throw HFIntegrityError.missingOID(filename: filename)
    }

    let expected = decoded.oid.lowercased()
    let actual = actualSHA256.lowercased()
    guard expected == actual else {
      // CHECK 1: delete the staging file so downstream steps can never
      // accidentally promote a corrupted download.
      try? FileManager.default.removeItem(at: stagingURL)
      throw HFIntegrityError.checksumMismatch(
        filename: filename,
        expected: expected,
        actual: actual
      )
    }
  }

  // MARK: - URL construction

  /// Builds `https://huggingface.co/api/models/<model-id>/lfs/<filename>`,
  /// percent-encoding path components so filenames with spaces or unicode
  /// round-trip safely.
  func buildLFSURL(modelId: String, filename: String) -> URL {
    // `modelId` is `org/repo`; encode the two halves individually so the
    // slash survives as a path separator.
    let modelComponents = modelId.split(separator: "/", omittingEmptySubsequences: false)
    var url = apiBase
    for component in modelComponents {
      url.appendPathComponent(String(component))
    }
    url.appendPathComponent("lfs")
    url.appendPathComponent(filename)
    return url
  }
}
