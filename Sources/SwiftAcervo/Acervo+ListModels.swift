// Acervo+ListModels.swift
// SwiftAcervo
//
// Bucket enumeration: `listModels(credentials:)` returns the slug of every
// model directory present under the CDN's `models/` prefix. This is a raw
// directory listing — it makes NO claim about model validity, completeness,
// or manifest presence. A returned slug only means "an object key exists
// under models/<slug>/ in the bucket". Validity checks (config.json,
// manifest verification, etc.) are deliberately deferred to other APIs.
//
// Like the rest of the CDN-mutation surface, the library never reads
// credentials from the environment; the caller (typically the `acervo` CLI)
// resolves them and passes an explicit `AcervoCDNCredentials`.

import Foundation

extension Acervo {

  /// The CDN key prefix under which every model directory lives.
  /// Mirrors the layout written by `publishModel` (`models/<slug>/…`).
  static let cdnModelsPrefix = "models/"

  /// Lists the slug of every model directory present under the CDN's
  /// `models/` prefix.
  ///
  /// This performs a delimiter-grouped `ListObjectsV2` against the bucket and
  /// returns the immediate sub-directory names (slugs) it finds — nothing
  /// more. It does **not** download anything, fetch manifests, or validate
  /// that any listed model is complete or usable. Treat the result as a raw
  /// inventory of directory names.
  ///
  /// - Parameter credentials: S3 credentials and addressing for the CDN
  ///   bucket. The signed `listObjects` API is used, so read access to the
  ///   bucket is required.
  /// - Returns: The model slugs (e.g. `"mlx-community_Qwen2.5-7B-Instruct-4bit"`),
  ///   sorted case-insensitively. Empty if the bucket has no models.
  /// - Throws: `AcervoError.cdnAuthorizationFailed(operation:)` on 401/403,
  ///   or `AcervoError.cdnOperationFailed(...)` for any other listing failure.
  ///
  /// - Note: This is the CDN counterpart to the local `listModels()` in
  ///   `Acervo+Discovery.swift` (which enumerates the on-disk shared models
  ///   directory and returns `[AcervoModel]`). The distinct name avoids
  ///   conflating "what's on the CDN" with "what's downloaded locally".
  public static func listCDNModels(
    credentials: AcervoCDNCredentials
  ) async throws -> [String] {
    let client = S3CDNClient(credentials: credentials)
    return try await _listCDNModels(client: client)
  }

  /// Test-facing core. Public callers go through `listCDNModels(credentials:)`
  /// which builds the live `S3CDNClient`; tests inject a client configured
  /// against `MockURLProtocol`.
  static func _listCDNModels(client: S3CDNClient) async throws -> [String] {
    let prefix = cdnModelsPrefix
    let rawPrefixes = try await client.listCommonPrefixes(
      prefix: prefix,
      delimiter: "/"
    )

    // Each CommonPrefix is `models/<slug>/`; reduce it to the bare slug.
    let slugs = rawPrefixes.compactMap { raw -> String? in
      var s = raw
      if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
      if s.hasSuffix("/") { s.removeLast() }
      return s.isEmpty ? nil : s
    }

    return slugs.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }
}
