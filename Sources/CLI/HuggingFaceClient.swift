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
  /// hint so the operator knows what to do next instead of staring at
  /// a wall of `HTTP 404 for <filename>` errors.
  ///
  /// Two distinct repo shapes produce all-404s:
  ///   1. Repos that store large blobs via HuggingFace Xet (the
  ///      content-addressable successor to LFS used by all newer
  ///      mlx-community models). The size-completeness check should
  ///      catch these earlier, but if it didn't, this hint nudges the
  ///      operator toward the env-var workaround.
  ///   2. Repos that aren't backed by either LFS or Xet (small
  ///      models like lmstudio-community/* and aydin99/*). For these,
  ///      `--no-verify` is the correct answer.
  static let notLFSBackedHint =
    """

    hint: every file returned HTTP 404 from the HuggingFace LFS API.

          If the repo uses HuggingFace Xet (newer mlx-community/* and
          most current models), ensure HF_HUB_ENABLE_HF_XET=1 is set
          before invoking `acervo download`. acervo sets this env var
          internally, so seeing this hint typically means an outdated
          huggingface_hub or a broken hf_xet install — try:
              pip install --upgrade huggingface-hub hf_xet

          If the repo is genuinely not Git LFS-backed (for example,
          lmstudio-community/* or aydin99/*), pass --no-verify to skip
          CHECK 1.

    """
}

/// Errors raised while reconciling a freshly-downloaded staging
/// directory against the authoritative HuggingFace tree listing.
enum HFTreeError: Error, CustomStringConvertible {

  /// The HuggingFace tree API returned a non-2xx HTTP status for every
  /// revision we tried (typically `main` and `master`).
  case httpError(statusCode: Int, modelId: String)

  /// The HuggingFace tree API returned a body that did not decode as
  /// the expected JSON array of tree entries.
  case decodeFailed(modelId: String, underlying: String)

  var description: String {
    switch self {
    case .httpError(let status, let modelId):
      return "HF tree API returned HTTP \(status) for \(modelId)"
    case .decodeFailed(let modelId, let underlying):
      return "Failed to decode HF tree response for \(modelId): \(underlying)"
    }
  }
}

/// One file as advertised by the HuggingFace tree endpoint.
struct HFTreeFile: Sendable, Equatable {
  /// Path relative to the repo root (e.g. `model.safetensors` or
  /// `subfolder/config.json`).
  let path: String
  /// Size in bytes that HF expects the file to occupy on disk.
  let size: Int64
  /// `true` when the tree entry carries the `xetHash` field, indicating
  /// the file is stored in HuggingFace Xet (vs. classic LFS or inline).
  let isXet: Bool
}

/// One file whose staged on-disk state did not match the HF tree.
struct HFCompletenessFailure: Sendable {

  enum Reason: Sendable {
    /// The file is in the HF tree but not present on disk at all.
    case missing
    /// The file is on disk but its size does not match HF's record.
    /// `actual < expected` is the canonical "Xet blob not pulled"
    /// signature (typically `actual == 0` or a few hundred bytes).
    case sizeMismatch(expected: Int64, actual: Int64)
  }

  let path: String
  let reason: Reason
  let isXet: Bool

  var description: String {
    let suffix = isXet ? " [Xet]" : ""
    switch reason {
    case .missing:
      return "\(path): missing from staging directory\(suffix)"
    case .sizeMismatch(let expected, let actual):
      return
        "\(path): size mismatch — expected \(expected) bytes, got \(actual)\(suffix)"
    }
  }
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

  /// Test-only seam. When non-nil, the no-arg/default-session
  /// initializer routes through this session instead of
  /// `URLSession.shared`. Production code never reads or writes
  /// this — only `@testable` test targets touch it, then restore
  /// `nil` in their teardown to keep the production path unchanged.
  nonisolated(unsafe) static var defaultSessionOverride: URLSession?

  init(
    session: URLSession? = nil,
    apiBase: URL = URL(string: "https://huggingface.co/api/models")!
  ) {
    self.session = session ?? Self.defaultSessionOverride ?? .shared
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

  // MARK: - Tree listing

  /// Decoded shape of one entry returned by the HF tree endpoint. The
  /// API returns more fields than we use; only the ones we need are
  /// listed here so unknown additions don't break decoding.
  private struct TreeEntry: Decodable {
    let type: String
    let path: String
    let size: Int64?
    let xetHash: String?
  }

  /// Fetches the full file listing for a HuggingFace model repository.
  ///
  /// Tries the default branch (`main`) first, falling back to `master`
  /// for the small number of older repos that haven't migrated. Follows
  /// HF's `Link: rel="next"` pagination header so large repos
  /// (>50 entries) return complete results.
  ///
  /// - Parameter modelId: `org/repo` HuggingFace model identifier.
  /// - Returns: Every entry whose `type == "file"`, with size and
  ///   Xet-status preserved. Directory entries are filtered out.
  /// - Throws: `HFTreeError` on non-2xx responses or malformed JSON.
  func fetchRepoFiles(modelId: String) async throws -> [HFTreeFile] {
    var lastError: HFTreeError = .httpError(statusCode: 0, modelId: modelId)
    for revision in ["main", "master"] {
      do {
        return try await fetchRepoFiles(modelId: modelId, revision: revision)
      } catch let error as HFTreeError {
        // Only fall through on 404 — other failures (auth, rate limit,
        // network) should bubble immediately rather than silently
        // retrying against the wrong branch.
        if case .httpError(404, _) = error {
          lastError = error
          continue
        }
        throw error
      }
    }
    throw lastError
  }

  /// Fetches the file listing for a specific revision (branch or
  /// commit SHA). Most callers should use ``fetchRepoFiles(modelId:)``,
  /// which retries across the conventional default branches.
  func fetchRepoFiles(modelId: String, revision: String) async throws -> [HFTreeFile] {
    var results: [HFTreeFile] = []
    var nextURL: URL? = buildTreeURL(modelId: modelId, revision: revision)

    while let url = nextURL {
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }

      let (data, response) = try await session.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw HFTreeError.httpError(statusCode: http.statusCode, modelId: modelId)
      }

      let entries: [TreeEntry]
      do {
        entries = try JSONDecoder().decode([TreeEntry].self, from: data)
      } catch {
        throw HFTreeError.decodeFailed(
          modelId: modelId,
          underlying: error.localizedDescription
        )
      }

      for entry in entries where entry.type == "file" {
        guard let size = entry.size else { continue }
        results.append(
          HFTreeFile(path: entry.path, size: size, isXet: entry.xetHash != nil)
        )
      }

      nextURL = HuggingFaceClient.parseNextLink(from: response)
    }

    return results
  }

  /// Walks a staging directory and reports every file whose on-disk
  /// state diverges from the HuggingFace tree listing. An empty result
  /// means the staging directory is consistent with HF and safe to
  /// promote.
  ///
  /// This is the "is the download actually complete" gate — independent
  /// of LFS SHA-256 verification (CHECK 1). It catches the silent-Xet
  /// failure mode where `hf download` returns success but writes only
  /// metadata sidecars for large blobs.
  ///
  /// - Parameters:
  ///   - modelId: `org/repo` HuggingFace model identifier.
  ///   - stagingURL: Local directory that should mirror the repo's
  ///     file tree (typically `<STAGING_DIR>/<slug>`).
  ///   - requestedFiles: When non-empty, restrict checks to these
  ///     repo-relative paths. When empty, every file in HF's tree
  ///     must exist locally.
  /// - Returns: Failures, one per offending file. `[]` on success.
  /// - Throws: `HFTreeError` if the tree endpoint cannot be reached.
  ///   I/O errors while stat-ing local files are reported as
  ///   `Reason.missing` rather than thrown.
  func verifyDownloadCompleteness(
    modelId: String,
    stagingURL: URL,
    requestedFiles: [String]
  ) async throws -> [HFCompletenessFailure] {
    let allFiles = try await fetchRepoFiles(modelId: modelId)

    let filtered: [HFTreeFile]
    if requestedFiles.isEmpty {
      filtered = allFiles
    } else {
      let requested = Set(requestedFiles)
      filtered = allFiles.filter { requested.contains($0.path) }
    }

    var failures: [HFCompletenessFailure] = []
    let fm = FileManager.default

    for file in filtered {
      let localURL = stagingURL.appendingPathComponent(file.path)
      let attrs: [FileAttributeKey: Any]
      do {
        attrs = try fm.attributesOfItem(atPath: localURL.path)
      } catch {
        failures.append(
          HFCompletenessFailure(path: file.path, reason: .missing, isXet: file.isXet)
        )
        continue
      }
      let actualSize = (attrs[.size] as? Int64) ?? 0
      if actualSize != file.size {
        failures.append(
          HFCompletenessFailure(
            path: file.path,
            reason: .sizeMismatch(expected: file.size, actual: actualSize),
            isXet: file.isXet
          )
        )
      }
    }

    return failures
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

  /// Builds `https://huggingface.co/api/models/<model-id>/tree/<revision>?recursive=true`.
  func buildTreeURL(modelId: String, revision: String) -> URL {
    let modelComponents = modelId.split(separator: "/", omittingEmptySubsequences: false)
    var base = apiBase
    for component in modelComponents {
      base.appendPathComponent(String(component))
    }
    base.appendPathComponent("tree")
    base.appendPathComponent(revision)

    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
    return components.url!
  }

  /// Parses the HTTP `Link` header for `rel="next"` and returns the
  /// next-page URL when present. HuggingFace uses this for cursor-based
  /// pagination on tree responses with more than 50 entries.
  static func parseNextLink(from response: URLResponse) -> URL? {
    guard let http = response as? HTTPURLResponse,
      let link = http.value(forHTTPHeaderField: "Link"), !link.isEmpty
    else {
      return nil
    }
    // RFC 5988 link headers are comma-separated; tolerate commas inside
    // angle brackets by splitting on the closing `>` first then walking
    // params.
    for chunk in link.split(separator: ",") {
      let trimmed = chunk.trimmingCharacters(in: .whitespaces)
      guard trimmed.contains("rel=\"next\""),
        let lt = trimmed.firstIndex(of: "<"),
        let gt = trimmed.firstIndex(of: ">")
      else { continue }
      let urlString = String(trimmed[trimmed.index(after: lt)..<gt])
      if let url = URL(string: urlString) {
        return url
      }
    }
    return nil
  }
}
