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
/// descriptors. It is used both post-download and pre-access to ensure
/// file integrity.
///
/// This type is internal to SwiftAcervo. External consumers interact with
/// integrity verification through `Acervo.verifyComponent(_:)` and
/// `Acervo.verifyAllComponents()`.
struct IntegrityVerification: Sendable {

    /// Computes the SHA-256 hash of a file and returns it as a lowercase hex string.
    ///
    /// - Parameter fileURL: The URL of the file to hash.
    /// - Returns: The SHA-256 hash as a lowercase hexadecimal string (64 characters).
    /// - Throws: Errors from reading the file data.
    static func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
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
}
