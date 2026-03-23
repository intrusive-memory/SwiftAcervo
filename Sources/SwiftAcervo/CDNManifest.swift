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
struct CDNManifest: Codable, Sendable {

    /// Schema version. The client rejects versions it does not understand.
    let manifestVersion: Int

    /// The canonical `org/repo` model identifier.
    let modelId: String

    /// The `org_repo` filesystem slug (mirrors local directory naming).
    let slug: String

    /// ISO-8601 timestamp of the last manifest update.
    let updatedAt: String

    /// Every downloadable file in this model, with checksums and sizes.
    let files: [CDNManifestFile]

    /// SHA-256 of all file checksums concatenated in sorted order.
    /// Verifies manifest integrity without cryptographic signing.
    let manifestChecksum: String
}

/// A single file entry in a CDN manifest.
struct CDNManifestFile: Codable, Sendable {

    /// Relative path within the model directory (e.g., "config.json"
    /// or "speech_tokenizer/config.json").
    let path: String

    /// Lowercase hex SHA-256 digest (64 characters). Required.
    let sha256: String

    /// Exact file size in bytes. Required.
    let sizeBytes: Int64
}

// MARK: - Manifest Validation

extension CDNManifest {

    /// The only manifest version this client understands.
    static let supportedVersion = 1

    /// Verifies the `manifestChecksum` field against the file checksums.
    ///
    /// Computes: sort all `files[].sha256` lexicographically, concatenate,
    /// SHA-256 the result, and compare to `manifestChecksum`.
    ///
    /// - Returns: `true` if the checksum matches.
    func verifyChecksum() -> Bool {
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
    static func computeChecksum(from fileChecksums: [String]) -> String {
        let sorted = fileChecksums.sorted()
        let concatenated = sorted.joined()
        let digest = SHA256.hash(data: Data(concatenated.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Looks up a file entry by its relative path.
    ///
    /// - Parameter path: The relative file path to search for.
    /// - Returns: The manifest file entry, or `nil` if not found.
    func file(at path: String) -> CDNManifestFile? {
        files.first { $0.path == path }
    }
}
