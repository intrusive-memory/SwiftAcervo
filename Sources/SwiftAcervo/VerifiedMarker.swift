// VerifiedMarker.swift
// SwiftAcervo
//
// Sortie A2 of OPERATION INTEGRITY CHECKPOINT (C3 · R2 · R3).
//
// A `.acervo-verified.json` marker is written into a model's local
// directory after a passing full-SHA-256 audit (see
// `Acervo.verifyIntegrity(_:)` and the download-completion wiring in
// `AcervoDownloader`). It records the manifest checksum the model was
// verified against and the timestamp of the audit.
//
// Its purpose (REQUIREMENTS R3): let later availability checks skip the
// expensive re-hash while the *local manifest checksum is unchanged*. A
// fast-path in `Acervo.availability(_:verifyHashes:)` /
// `Acervo.isModelAvailable(_:)` trusts a model whose stored
// `manifestChecksum` matches the local manifest, and re-audits when it
// does not match (or when no marker exists).
//
// ## Why `manifestChecksum` is the freshness key
//
// `CDNManifest.manifestChecksum` is the SHA-256 of all per-file SHA-256
// digests concatenated in sorted order (see
// `CDNManifest.computeChecksum(from:)`). It is therefore a stable,
// deterministic fingerprint of the manifest's *content* — independent of
// JSON key order, whitespace, or the `updatedAt` timestamp. If any file's
// expected hash, set of files, or any byte the manifest declares changes,
// the checksum changes; if the manifest is byte-for-byte the same model
// declaration, the checksum is identical. That makes it the correct value
// to stamp into the marker and to compare against on the fast-path: a
// matching checksum means "the same set of bytes we already fully
// verified", a mismatch means "the manifest changed — re-audit".

import Foundation

/// On-disk record of a passing full-hash integrity audit for a model.
///
/// Serialized to `<modelDir>/.acervo-verified.json`. `Codable` for
/// round-tripping and `Sendable` so it can cross actor boundaries.
struct VerifiedMarker: Codable, Sendable, Equatable {

  /// The local manifest's `manifestChecksum` at the moment the audit
  /// passed. The availability fast-path trusts the model only while the
  /// current local manifest's checksum still equals this value.
  let manifestChecksum: String

  /// When the passing full-hash audit completed.
  let verifiedAt: Date

  init(manifestChecksum: String, verifiedAt: Date = Date()) {
    self.manifestChecksum = manifestChecksum
    self.verifiedAt = verifiedAt
  }

  /// The fixed filename the marker is serialized to inside a model dir.
  static let filename = ".acervo-verified.json"

  /// The marker URL for a given model directory.
  static func url(in modelDir: URL) -> URL {
    modelDir.appendingPathComponent(filename)
  }

  /// Reads and decodes the marker from `<modelDir>/.acervo-verified.json`.
  ///
  /// Returns `nil` when the file is absent or undecodable (a corrupt
  /// marker is treated as "no marker" so the caller re-audits rather than
  /// trusting garbage).
  static func read(in modelDir: URL) -> VerifiedMarker? {
    let url = url(in: modelDir)
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? Self.decoder.decode(VerifiedMarker.self, from: data)
  }

  /// Encodes and writes the marker into `<modelDir>/.acervo-verified.json`.
  ///
  /// Creates the model directory if it does not already exist. Throws on
  /// an underlying filesystem or encoding failure.
  func write(in modelDir: URL) throws {
    try FileManager.default.createDirectory(
      at: modelDir,
      withIntermediateDirectories: true
    )
    let data = try Self.encoder.encode(self)
    try data.write(to: Self.url(in: modelDir), options: .atomic)
  }

  // MARK: - Coders (ISO-8601 dates, stable key order)

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}
