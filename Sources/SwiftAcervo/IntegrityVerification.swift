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
  static let chunkSize = 4_194_304

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
  ///
  /// NOTE (Sortie 5a): Telemetry is intentionally NOT emitted here. This
  /// method is called from the synchronous public API chain
  /// `Acervo.verifyComponent` → `verify`. Making `verify` async would
  /// cascade to `verifyComponent` (a public API) and break callers. The
  /// telemetry surface for verify-on-read is wired at
  /// `verifyAgainstManifest`, which is the manifest-driven path actually
  /// used during downloads. Telemetry parameter is retained for future
  /// async-bridge wiring.
  static func verify(
    file: ComponentFile,
    in directory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) throws -> Bool {
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

  /// Returns the size of a file in bytes if it exists, or `nil` if absent.
  ///
  /// This helper distinguishes "file absent" (returns `nil`) from "file
  /// exists with size 0" (returns `0`). It never throws — any I/O glitch
  /// when reading file attributes is translated to `nil` and reported at
  /// debug log level. Used by the resumable-download path in
  /// `AcervoDownloader.streamDownloadFile` to classify the state of a
  /// `.part` file before deciding whether to send a `Range` header.
  ///
  /// - Parameter fileURL: The URL of the file to probe.
  /// - Returns: The file size in bytes, or `nil` if the file does not exist.
  static func partialFileSize(at fileURL: URL) -> Int64? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else {
      return nil
    }
    do {
      return try fileSize(at: fileURL)
    } catch {
      // File exists per `fileExists` but attributes lookup failed. Treat as
      // absent for resume-classification purposes; the downstream code will
      // start fresh.
      return nil
    }
  }

  /// Returns `true` when a file's on-disk size matches the size declared in
  /// its `CDNManifestFile` entry.
  ///
  /// This is the canonical "is this individual file present and intact (by
  /// size)" predicate. It deliberately does NOT recompute the SHA-256 — that
  /// would be prohibitively expensive for a synchronous availability probe.
  /// It is shared by the per-file cache-hit check in
  /// `AcervoDownloader.downloadFiles` and by the model-level aggregator
  /// `allManifestFilesPresentBySize(manifest:in:)`.
  ///
  /// Never throws; "no file" yields `false`.
  ///
  /// - Parameters:
  ///   - file: The manifest entry describing the expected file (path + size).
  ///   - directory: The base directory inside which `file.path` resolves.
  /// - Returns: `true` iff the file exists and its size in bytes equals
  ///   `file.sizeBytes`.
  static func fileMatchesManifestEntry(
    _ file: CDNManifestFile,
    in directory: URL
  ) -> Bool {
    let url = directory.appendingPathComponent(file.path)
    return partialFileSize(at: url) == file.sizeBytes
  }

  /// Returns `true` when EVERY file declared in `manifest.files` is on disk
  /// at the recorded size, anchored at `directory`.
  ///
  /// Short-circuits on the first miss. Emits no telemetry; this is a pure
  /// predicate used by `Acervo.isModelAvailable(_:)` to answer the
  /// "is this model usable right now?" question without network I/O.
  ///
  /// - Parameters:
  ///   - manifest: The CDN manifest to compare against.
  ///   - directory: The model's on-disk directory (e.g.,
  ///     `{baseDirectory}/{slug}`).
  /// - Returns: `true` iff every entry in `manifest.files` satisfies
  ///   `fileMatchesManifestEntry(_:in:)`.
  static func allManifestFilesPresentBySize(
    manifest: CDNManifest,
    in directory: URL
  ) -> Bool {
    for file in manifest.files {
      guard fileMatchesManifestEntry(file, in: directory) else {
        return false
      }
    }
    return true
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
  ///
  /// NOTE (Sortie 5a): The method is `async` to allow telemetry emission of
  /// `integrityVerifyStart`/`integrityVerifyComplete`. On the failure paths
  /// the complete event (with `passed: false`) is emitted IMMEDIATELY before
  /// the throw so observers see the verdict before the exception propagates.
  /// `modelID` is not in scope here (the manifestFile carries only the
  /// relative path); empty string is used and consumers correlate via
  /// `fileName`.
  static func verifyAgainstManifest(
    fileURL: URL,
    manifestFile: CDNManifestFile,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    // Integrity start: emit before any I/O so observers see the verification
    // begin even if the file read fails. Payload construction is skipped when
    // no reporter is attached.
    let verifyStart = Date()
    if let telemetry {
      await telemetry.capture(
        .integrityVerifyStart(
          modelID: "",  // not threaded through verifyAgainstManifest signature
          fileName: manifestFile.path,
          expectedSHA: manifestFile.sha256,
          declaredBytes: manifestFile.sizeBytes
        )
      )
    }

    // Fast check: file size
    let actualSize = try fileSize(at: fileURL)
    if actualSize != manifestFile.sizeBytes {
      // Emit integrity-complete with passed:false BEFORE removing the file
      // and throwing — this ordering is consumed by Sortie 5b adjacency.
      // `actualSHA` is unavailable on the size-mismatch path; empty string
      // signals "not computed".
      if let telemetry {
        let durationSeconds = Date().timeIntervalSince(verifyStart)
        await telemetry.capture(
          .integrityVerifyComplete(
            modelID: "",
            fileName: manifestFile.path,
            actualSHA: "",
            actualBytes: actualSize,
            passed: false,
            durationSeconds: durationSeconds
          )
        )
      }
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
      // Emit integrity-complete with passed:false BEFORE the throw.
      if let telemetry {
        let durationSeconds = Date().timeIntervalSince(verifyStart)
        await telemetry.capture(
          .integrityVerifyComplete(
            modelID: "",
            fileName: manifestFile.path,
            actualSHA: actualHash,
            actualBytes: actualSize,
            passed: false,
            durationSeconds: durationSeconds
          )
        )
      }
      try? FileManager.default.removeItem(at: fileURL)
      throw AcervoError.integrityCheckFailed(
        file: manifestFile.path,
        expected: manifestFile.sha256,
        actual: actualHash
      )
    }

    // Success path: emit passed:true completion.
    if let telemetry {
      let durationSeconds = Date().timeIntervalSince(verifyStart)
      await telemetry.capture(
        .integrityVerifyComplete(
          modelID: "",
          fileName: manifestFile.path,
          actualSHA: actualHash,
          actualBytes: actualSize,
          passed: true,
          durationSeconds: durationSeconds
        )
      )
    }
  }
}
