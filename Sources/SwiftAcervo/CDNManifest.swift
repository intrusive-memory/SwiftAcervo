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
public struct CDNManifest: Codable, Sendable {

  /// Schema version. The client rejects versions it does not understand.
  public let manifestVersion: Int

  /// The canonical `org/repo` model identifier.
  public let modelId: String

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
  public init(
    manifestVersion: Int,
    modelId: String,
    slug: String,
    updatedAt: String,
    files: [CDNManifestFile],
    manifestChecksum: String
  ) {
    self.manifestVersion = manifestVersion
    self.modelId = modelId
    self.slug = slug
    self.updatedAt = updatedAt
    self.files = files
    self.manifestChecksum = manifestChecksum
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
