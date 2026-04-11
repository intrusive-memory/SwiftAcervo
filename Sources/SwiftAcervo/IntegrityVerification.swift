// IntegrityVerification.swift
// SwiftAcervo
//
// Internal SHA-256 checksum verification helper for component files.
// Uses CryptoKit (a system framework on macOS 26+ / iOS 26+) to
// compute file hashes. This is NOT an external dependency.

import CryptoKit
import Foundation

/// Internal helper for SHA-256 integrity verification of component files.
///
/// `IntegrityVerification` provides static methods to compute file hashes
/// and verify them against expected values declared in `ComponentFile`
/// descriptors or CDN manifests. It is used both post-download and
/// pre-access to ensure file integrity.
///
/// This type is internal to SwiftAcervo. External consumers interact with
/// integrity verification through `Acervo.verifyComponent(_:)` and
/// `Acervo.verifyAllComponents()`.
public struct IntegrityVerification: Sendable {

  /// Size of chunks used for streaming SHA-256 computation.
  /// 4 MB balances memory usage and I/O efficiency.
  private static let chunkSize = 4_194_304

  /// Computes the SHA-256 hash of a file using streaming reads.
  ///
  /// Reads the file in 4 MB chunks to avoid loading multi-gigabyte
  /// model files entirely into memory.
  ///
  /// - Parameter fileURL: The URL of the file to hash.
  /// - Returns: The SHA-256 hash as a lowercase hexadecimal string (64 characters).
  /// - Throws: Errors from opening or reading the file.
  public static func sha256(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
      let chunk = handle.readData(ofLength: chunkSize)
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Verifies a single component file against its declared SHA-256 checksum.
  ///
  /// If the file's `sha256` property is `nil`, verification is skipped and
  /// the method returns `true` (backward compatible with files that do not
  /// declare checksums).
  ///
  /// - Parameters:
  ///   - file: The component file descriptor containing the expected checksum.
  ///   - directory: The base directory containing the file.
  /// - Returns: `true` if the checksum matches or is not declared; `false` if it mismatches.
  /// - Throws: Errors from reading the file data.
  static func verify(file: ComponentFile, in directory: URL) throws -> Bool {
    guard let expectedHash = file.sha256 else {
      // No checksum declared -- skip verification
      return true
    }

    let fileURL = directory.appendingPathComponent(file.relativePath)
    let actualHash = try sha256(of: fileURL)
    return actualHash == expectedHash
  }

  /// Returns the size of a file in bytes.
  ///
  /// - Parameter fileURL: The URL of the file to measure.
  /// - Returns: The file size in bytes.
  /// - Throws: Errors from reading file attributes.
  static func fileSize(at fileURL: URL) throws -> Int64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    return attrs[.size] as? Int64 ?? 0
  }

  /// Verifies a downloaded file against its manifest entry.
  ///
  /// Checks size first (fast), then SHA-256 (slow but definitive).
  /// If either check fails, the file is deleted and an appropriate
  /// error is thrown.
  ///
  /// - Parameters:
  ///   - fileURL: The local file to verify.
  ///   - manifestFile: The manifest entry with expected size and hash.
  /// - Throws: `AcervoError.downloadSizeMismatch` or `AcervoError.integrityCheckFailed`.
  static func verifyAgainstManifest(
    fileURL: URL,
    manifestFile: CDNManifestFile
  ) throws {
    // Fast check: file size
    let actualSize = try fileSize(at: fileURL)
    if actualSize != manifestFile.sizeBytes {
      try? FileManager.default.removeItem(at: fileURL)
      throw AcervoError.downloadSizeMismatch(
        fileName: manifestFile.path,
        expected: manifestFile.sizeBytes,
        actual: actualSize
      )
    }

    // Definitive check: SHA-256
    let actualHash = try sha256(of: fileURL)
    if actualHash != manifestFile.sha256 {
      try? FileManager.default.removeItem(at: fileURL)
      throw AcervoError.integrityCheckFailed(
        file: manifestFile.path,
        expected: manifestFile.sha256,
        actual: actualHash
      )
    }
  }
}
