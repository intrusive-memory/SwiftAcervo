// DownloadFinalizer.swift
// SwiftAcervo
//
// Installs a file delivered by a background download task (iOS #81).
//
// A background `URLSessionDownloadTask` hands back a temporary file the OS owns.
// Before it can count as part of a model it must be integrity-checked and moved
// into the model directory in the App Group container. This step is factored out
// of the transport so it is pure file I/O — no `URLSession` — and therefore
// fully unit-testable on macOS CI. The iOS delegate (Phase 2b) calls it from
// `urlSession(_:downloadTask:didFinishDownloadingTo:)` and records the result in
// the `DownloadLedger`.

import Foundation

/// Verifies and installs a file delivered by a background download.
public enum DownloadFinalizer {

  /// Moves a delivered temp file into `destination` after optional SHA-256
  /// verification.
  ///
  /// - On SHA match (or when `expectedSHA256` is `nil`): the destination's
  ///   parent directory is created if needed and the file is moved into place,
  ///   replacing any existing file there.
  /// - On SHA mismatch: the delivered file is deleted and
  ///   ``AcervoError/integrityCheckFailed(file:expected:actual:)`` is thrown;
  ///   `destination` is left untouched.
  ///
  /// The delivered file is always consumed on the verification path — moved on
  /// success, deleted on mismatch — so a caller never has to clean it up itself.
  ///
  /// - Parameters:
  ///   - deliveredFile: The OS-owned temp file from `didFinishDownloadingTo`.
  ///   - destination: The final absolute URL within the model directory.
  ///   - expectedSHA256: The manifest checksum (lowercase hex), or `nil` to skip
  ///     verification.
  /// - Throws: ``AcervoError/integrityCheckFailed`` on mismatch, or a
  ///   `FileManager` error if the move fails.
  public static func finalize(
    deliveredFile: URL,
    destination: URL,
    expectedSHA256: String?
  ) throws {
    if let expected = expectedSHA256 {
      let actual = try IntegrityVerification.sha256(of: deliveredFile)
      guard actual == expected else {
        // Corrupt/incomplete delivery: drop it so a re-enqueue starts clean.
        try? FileManager.default.removeItem(at: deliveredFile)
        throw AcervoError.integrityCheckFailed(
          file: destination.lastPathComponent,
          expected: expected,
          actual: actual
        )
      }
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // Replace any existing file at the destination so a re-download overwrites
    // cleanly (moveItem fails if the destination already exists).
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: deliveredFile, to: destination)
  }
}
