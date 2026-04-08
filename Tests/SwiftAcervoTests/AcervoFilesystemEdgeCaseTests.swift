import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for filesystem edge cases: file permission denial and disk-full simulation.
///
/// All tests use the `customBaseDirectory` isolation pattern from §6 of TESTING_REQUIREMENTS.md.
@Suite("Filesystem Edge Cases")
struct AcervoFilesystemEdgeCaseTests {

  // MARK: - File Permission Denial

  /// Verifies that `Acervo.listModels()` throws a descriptive error (not a crash)
  /// when the model directory is non-readable/non-executable (permissions 0o000).
  ///
  /// This covers §7 priority 3: "No test for file permission denial on model directory."
  @Test("listModels throws when model directory is non-readable")
  func listModelsThrowsOnNonReadableDirectory() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("acervo-test-\(UUID())")
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

    // Restore permissions before cleanup so defer { removeItem } can succeed.
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: tempRoot.path
      )
      try? FileManager.default.removeItem(at: tempRoot)
    }

    Acervo.customBaseDirectory = tempRoot
    defer { Acervo.customBaseDirectory = nil }

    // Remove all permissions so contentsOfDirectory will fail with a permission error.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: tempRoot.path
    )

    // listModels() must throw — not crash — when the directory is unreadable.
    // The exact error type depends on the OS (typically CocoaError / NSFileReadNoPermissionError),
    // but any thrown error satisfies the requirement.
    #expect(throws: (any Error).self) {
      _ = try Acervo.listModels()
    }
  }

  // MARK: - Disk-Full Simulation

  /// Verifies that `AcervoDownloader.ensureDirectory(at:)` throws
  /// `AcervoError.directoryCreationFailed` when a regular file already occupies
  /// the target path, making directory creation impossible.
  ///
  /// This covers §7 priority 2: "No test for disk-full condition during download."
  ///
  /// NOTE: True disk-full simulation requires a ramdisk; this test verifies error
  /// handling for a path-creation failure as the closest unit-testable equivalent.
  @Test("ensureDirectory throws directoryCreationFailed when path is occupied by a file")
  func ensureDirectoryThrowsWhenPathIsFile() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("acervo-test-\(UUID())")
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    Acervo.customBaseDirectory = tempRoot
    defer { Acervo.customBaseDirectory = nil }

    // Place a regular file at the path where we will try to create a directory.
    // FileManager cannot create a directory at a path already occupied by a file,
    // simulating the error path that would occur during a disk-full or other
    // filesystem write failure.
    let blockedPath = tempRoot.appendingPathComponent("org_blocked-model")
    try Data("this is a file, not a directory".utf8).write(to: blockedPath)

    // AcervoDownloader.ensureDirectory must throw .directoryCreationFailed.
    // AcervoError is not Equatable, so we inspect the thrown error via a typed catch.
    #expect(throws: AcervoError.self) {
      try AcervoDownloader.ensureDirectory(at: blockedPath)
    }
    do {
      try AcervoDownloader.ensureDirectory(at: blockedPath)
    } catch let error as AcervoError {
      if case .directoryCreationFailed(let path) = error {
        #expect(path == blockedPath.path)
      } else {
        Issue.record("Expected .directoryCreationFailed but got \(error)")
      }
    } catch {
      Issue.record("Expected AcervoError but got \(error)")
    }
  }
}
