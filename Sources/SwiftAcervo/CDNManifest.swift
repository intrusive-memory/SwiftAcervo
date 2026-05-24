// CDNManifest.swift
// SwiftAcervo
//
// Per-model manifest type for CDN-hosted model files.
//
// Each model on the CDN has a `manifest.json` that declares the
// complete file list, SHA-256 checksums, and sizes. The client
// downloads the manifest first, validates its integrity, then
// uses it to drive file downloads with per-file verification.

import CryptoKit
import Foundation

/// JSON manifest for a model hosted on the CDN.
///
/// The manifest lives at `{cdnBase}/models/{slug}/manifest.json`
/// alongside the model files. It is the single source of truth
/// for what files exist and their expected checksums.
///
/// ## Multi-component models
///
/// SwiftAcervo's slug-keyed API (`flux2-klein-4b`, `pixart-sigma-xl`, …) may
/// resolve to either a **single-component** or a **multi-component** model.
///
/// - **Single-component**: `components == [primaryRepo]` and `primaryRepo`
///   equals the sole HF repo string for that slug.
/// - **Multi-component**: `components` lists every HF repo string belonging
///   to the slug (transformer, VAE, text-encoder, …). **Every component's
///   manifest carries the SAME `primaryRepo` value** — the slug-level
///   "canonical main" repo declared in the uploader's spec file. A VAE
///   component manifest does NOT carry the VAE's own HF repo string in
///   `primaryRepo`; it carries the shared spec-level value. This invariant
///   is what lets consumers fan out across components and aggregate state
///   under one logical slug.
public struct CDNManifest: Codable, Sendable {

  /// Schema version. The client rejects versions it does not understand.
  public let manifestVersion: Int

  /// The canonical `org/repo` model identifier this manifest describes.
  ///
  /// For single-component models, equals the slug-level identifier. For
  /// multi-component models, this is the component's own HF repo (so the
  /// per-file CDN path resolves), while `primaryRepo` carries the
  /// slug-level shared value.
  public let modelId: String

  /// The slug-level "canonical main" repo for this manifest's slug. Required.
  ///
  /// - Single-component slug: equals the sole HF repo string and therefore
  ///   `modelId`.
  /// - Multi-component slug: every component manifest carries the **same**
  ///   `primaryRepo` (the value supplied by the uploader's spec file). The
  ///   VAE component's `primaryRepo` is not the VAE's own repo — it is the
  ///   shared slug-level primary.
  public let primaryRepo: String

  /// Every HF repo string belonging to this manifest's slug. Required.
  ///
  /// - Single-component slug: `[primaryRepo]`.
  /// - Multi-component slug: the full set, in the order declared by the
  ///   uploader's spec file. Every entry is a manifest-resolvable repo.
  public let components: [String]

  /// The `org_repo` filesystem slug (mirrors local directory naming).
  public let slug: String

  /// ISO-8601 timestamp of the last manifest update.
  public let updatedAt: String

  /// Every downloadable file in this model, with checksums and sizes.
  public let files: [CDNManifestFile]

  /// SHA-256 of all file checksums concatenated in sorted order.
  /// Verifies manifest integrity without cryptographic signing.
  public let manifestChecksum: String

  /// Memberwise initializer for constructing manifests programmatically.
  ///
  /// `primaryRepo` and `components` are required on the wire. The in-memory
  /// initializer applies the single-component defaults (`primaryRepo ==
  /// modelId`, `components == [modelId]`) when omitted, so library callers
  /// constructing a manifest for a single-repo model don't need to repeat
  /// themselves.
  public init(
    manifestVersion: Int,
    modelId: String,
    slug: String,
    updatedAt: String,
    files: [CDNManifestFile],
    manifestChecksum: String,
    primaryRepo: String? = nil,
    components: [String]? = nil
  ) {
    self.manifestVersion = manifestVersion
    self.modelId = modelId
    self.slug = slug
    self.updatedAt = updatedAt
    self.files = files
    self.manifestChecksum = manifestChecksum
    self.primaryRepo = primaryRepo ?? modelId
    self.components = components ?? [modelId]
  }

  // MARK: - Codable

  private enum CodingKeys: String, CodingKey {
    case manifestVersion
    case modelId
    case primaryRepo
    case components
    case slug
    case updatedAt
    case files
    case manifestChecksum
  }

  /// Strict decode. `primaryRepo` and `components` are required on the wire.
  /// A manifest missing either field throws `DecodingError.keyNotFound`.
  /// There is no migration shim — out-of-spec manifests fail to decode.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.manifestVersion = try container.decode(Int.self, forKey: .manifestVersion)
    self.modelId = try container.decode(String.self, forKey: .modelId)
    self.primaryRepo = try container.decode(String.self, forKey: .primaryRepo)
    self.components = try container.decode([String].self, forKey: .components)
    self.slug = try container.decode(String.self, forKey: .slug)
    self.updatedAt = try container.decode(String.self, forKey: .updatedAt)
    self.files = try container.decode([CDNManifestFile].self, forKey: .files)
    self.manifestChecksum = try container.decode(String.self, forKey: .manifestChecksum)
  }
}

/// A single file entry in a CDN manifest.
public struct CDNManifestFile: Codable, Sendable {

  /// Relative path within the model directory (e.g., "config.json"
  /// or "speech_tokenizer/config.json").
  public let path: String

  /// Lowercase hex SHA-256 digest (64 characters). Required.
  public let sha256: String

  /// Exact file size in bytes. Required.
  public let sizeBytes: Int64

  /// Memberwise initializer.
  public init(path: String, sha256: String, sizeBytes: Int64) {
    self.path = path
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
  }

  private enum CodingKeys: String, CodingKey {
    case path, sha256, sizeBytes
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawPath = try container.decode(String.self, forKey: .path)
    self.path = try Self.validatedRelativePath(rawPath)
    self.sha256 = try container.decode(String.self, forKey: .sha256)
    self.sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
  }

  /// Normalizes and validates a manifest-supplied relative path.
  ///
  /// Strips any leading `/` characters, then rejects the path if it is
  /// empty or contains an empty / `.` / `..` component. This is the trust
  /// boundary that prevents a malicious manifest from writing outside the
  /// model directory via path traversal.
  static func validatedRelativePath(_ raw: String) throws -> String {
    let trimmed: Substring = raw.first == "/" ? raw.dropFirst() : Substring(raw)
    guard !trimmed.isEmpty else {
      throw AcervoError.invalidManifestPath(raw)
    }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    for component in components {
      guard !component.isEmpty, component != ".", component != ".." else {
        throw AcervoError.invalidManifestPath(raw)
      }
    }
    return String(trimmed)
  }
}

// MARK: - Manifest Validation

extension CDNManifest {

  /// The only manifest version this client understands.
  public static let supportedVersion = 1

  /// Verifies the `manifestChecksum` field against the file checksums.
  ///
  /// Computes: sort all `files[].sha256` lexicographically, concatenate,
  /// SHA-256 the result, and compare to `manifestChecksum`.
  ///
  /// - Returns: `true` if the checksum matches.
  public func verifyChecksum() -> Bool {
    let computed = Self.computeChecksum(from: files.map(\.sha256))
    return computed == manifestChecksum
  }

  /// Computes the manifest checksum from an array of file SHA-256 hashes.
  ///
  /// This is the canonical algorithm: sort lexicographically, concatenate,
  /// then SHA-256 the concatenation.
  ///
  /// - Parameter fileChecksums: The SHA-256 hashes of all files in the manifest.
  /// - Returns: The computed manifest checksum as a lowercase hex string.
  public static func computeChecksum(from fileChecksums: [String]) -> String {
    let sorted = fileChecksums.sorted()
    let concatenated = sorted.joined()
    let digest = SHA256.hash(data: Data(concatenated.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Looks up a file entry by its relative path.
  ///
  /// - Parameter path: The relative file path to search for.
  /// - Returns: The manifest file entry, or `nil` if not found.
  public func file(at path: String) -> CDNManifestFile? {
    files.first { $0.path == path }
  }

  /// Validates this manifest against the requested model ID.
  ///
  /// Checks that the manifest version is supported and that the `modelId`
  /// field matches the requested model. Call after decoding and before using
  /// the manifest for downloads.
  ///
  /// - Parameter requestedModelId: The `org/repo` model identifier the caller
  ///   requested. Must match the manifest's `modelId` field.
  /// - Throws: `AcervoError.manifestVersionUnsupported` if `manifestVersion`
  ///   is not `supportedVersion`, or `AcervoError.manifestModelIdMismatch` if
  ///   `modelId` does not match `requestedModelId`.
  func validate(for requestedModelId: String) throws {
    guard manifestVersion == Self.supportedVersion else {
      throw AcervoError.manifestVersionUnsupported(manifestVersion)
    }
    guard modelId == requestedModelId else {
      throw AcervoError.manifestModelIdMismatch(expected: requestedModelId, actual: modelId)
    }
  }
}
