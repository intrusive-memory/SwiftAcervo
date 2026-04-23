import Foundation
import Testing

@testable import SwiftAcervo

extension CustomBaseDirectorySuite {

  /// Tests for filesystem edge cases: file permission denial and disk-full simulation.
  ///
  /// All tests use the `customBaseDirectory` isolation pattern from §6 of TESTING_REQUIREMENTS.md.
  /// Nested under `CustomBaseDirectorySuite` (`.serialized`) so writes to
  /// `Acervo.customBaseDirectory` cannot race with sibling suites.
  @Suite("Filesystem Edge Cases")
  struct AcervoFilesystemEdgeCaseTests {

    // MARK: - Shared Helpers

    /// Creates a minimal valid model directory structure under `root`.
    ///
    /// The directory name is the slugified `id` and contains a `config.json` so
    /// that `Acervo.listModels` considers the directory a valid model.
    ///
    /// - Parameters:
    ///   - id: A model identifier in "org/repo" format.
    ///   - root: The temporary base directory to create the model inside.
    /// - Returns: The URL of the newly created model directory.
    @discardableResult
    func makeFakeModel(id: String, in root: URL) throws -> URL {
      let modelDir = root.appendingPathComponent(Acervo.slugify(id))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      // config.json presence is the validity marker
      try "{}".write(
        to: modelDir.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      return modelDir
    }

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

  // MARK: - Symlink Discovery Edge Cases

  /// Tests for symlink behavior in `Acervo.listModels`.
  ///
  /// All tests use the `customBaseDirectory` isolation pattern from §6 of TESTING_REQUIREMENTS.md.
  /// Nested under `CustomBaseDirectorySuite` (`.serialized`) so writes to
  /// `Acervo.customBaseDirectory` cannot race with sibling suites.
  @Suite("Symlink Discovery Edge Cases")
  struct AcervoSymlinkEdgeCaseTests {

    // MARK: - Shared Helpers

    /// Creates a minimal valid model directory structure under `root`.
    ///
    /// The directory name is the slugified `id` and contains a `config.json` so
    /// that `Acervo.listModels` considers the directory a valid model.
    @discardableResult
    func makeFakeModel(id: String, in root: URL) throws -> URL {
      let modelDir = root.appendingPathComponent(Acervo.slugify(id))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      try "{}".write(
        to: modelDir.appendingPathComponent("config.json"),
        atomically: true,
        encoding: .utf8
      )
      return modelDir
    }

    // MARK: - Symlink in Model Directory is Not Double-Counted

    /// Verifies that a symlink pointing to a valid model directory does not cause
    /// `listModels` to throw or crash, and does not double-count the real model.
    ///
    /// Behavior contract: `contentsOfDirectory(at:includingPropertiesForKeys:options:)`
    /// returns the symlink's own URL (not the resolved target). Calling
    /// `resourceValues(forKeys: [.isDirectoryKey])` on that URL returns
    /// `isDirectory == false` (the symlink is a symlink, not a directory), so
    /// `listModels` silently skips symlink entries via the `guard` on line 261.
    ///
    /// The real model directory (placed outside `customBaseDirectory`) is not
    /// scanned, so the result is 0 models — no crash, no double-count.
    @Test("symlink in model directory does not cause double-count or error in listModels")
    func symlinkToValidModelIsSkippedWithoutError() throws {
      // tempRoot is where Acervo will scan — it will contain the symlink only.
      let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-test-\(UUID())")
      try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempRoot) }

      Acervo.customBaseDirectory = tempRoot
      defer { Acervo.customBaseDirectory = nil }

      // realModelRoot is outside tempRoot so the real model dir is not scanned directly.
      let realModelRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-real-\(UUID())")
      try FileManager.default.createDirectory(at: realModelRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: realModelRoot) }

      let realModelDir = try makeFakeModel(id: "test-org/symlinked-model", in: realModelRoot)

      // Create a symlink inside tempRoot pointing to the real model directory.
      let symlinkPath =
        tempRoot
        .appendingPathComponent(Acervo.slugify("test-org/symlinked-model"))
        .path
      try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: realModelDir.path
      )

      // Call listModels(in:) directly to avoid racing on the global customBaseDirectory.
      // The symlink is skipped (isDirectory == false for the symlink URL), so the
      // result is empty — no double-count, no crash.
      let models = try Acervo.listModels(in: tempRoot)
      #expect(
        models.count == 0,
        "Symlink entry must not be counted as a model; got \(models.count)"
      )
    }

    // MARK: - Broken Symlink is Silently Skipped

    /// Verifies that a broken symlink (pointing to a nonexistent target) in the
    /// model directory does not cause `listModels` to crash or throw.
    ///
    /// Behavior contract: `try? itemURL.resourceValues(forKeys: [.isDirectoryKey])`
    /// returns `nil` for a broken symlink, so the guard fails silently and the
    /// entry is skipped. `listModels` returns partial results (empty in this case).
    @Test("broken symlink in model directory is silently skipped by listModels")
    func brokenSymlinkIsSilentlySkipped() throws {
      let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-test-\(UUID())")
      try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempRoot) }

      Acervo.customBaseDirectory = tempRoot
      defer { Acervo.customBaseDirectory = nil }

      // Create a symlink whose destination does not exist.
      let brokenSymlinkPath =
        tempRoot
        .appendingPathComponent("test-org_broken-model")
        .path
      let nonexistentTarget =
        tempRoot
        .appendingPathComponent("does-not-exist-\(UUID())")
        .path
      try FileManager.default.createSymbolicLink(
        atPath: brokenSymlinkPath,
        withDestinationPath: nonexistentTarget
      )

      // Call listModels(in:) directly to avoid racing on the global customBaseDirectory.
      // listModels must not throw — it should skip the broken symlink and return
      // an empty array (partial results).
      let models = try Acervo.listModels(in: tempRoot)
      #expect(
        models.isEmpty,
        "Expected empty results when broken symlink is present, got \(models.count) model(s)"
      )
    }

    // MARK: - Deleting a Symlinked Model Entry

    /// Verifies that removing a symlink entry via `FileManager.removeItem` leaves the
    /// real model data intact, and that `listModels` remains clean before and after.
    ///
    /// Behavior contract: `FileManager.default.removeItem(at:)` on a symlink removes
    /// only the symlink itself — not the target directory. Since `listModels` skips
    /// symlinks (they do not pass the `isDirectory == true` guard), both before and
    /// after symlink removal the scan result is empty. The real `config.json` must
    /// remain accessible on disk after the symlink is deleted.
    @Test("deleting a symlinked model entry removes only the symlink, not the real data")
    func deletingSymlinkLeavesRealDataIntact() throws {
      let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-test-\(UUID())")
      try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempRoot) }

      Acervo.customBaseDirectory = tempRoot
      defer { Acervo.customBaseDirectory = nil }

      // Create the real model directory outside tempRoot.
      let realModelRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-real-\(UUID())")
      try FileManager.default.createDirectory(at: realModelRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: realModelRoot) }

      let realModelDir = try makeFakeModel(id: "test-org/real-model", in: realModelRoot)

      // Place a symlink inside tempRoot (the scan directory) pointing to the real dir.
      let symlinkURL = tempRoot.appendingPathComponent(Acervo.slugify("test-org/real-model"))
      try FileManager.default.createSymbolicLink(
        atPath: symlinkURL.path,
        withDestinationPath: realModelDir.path
      )

      // Call listModels(in:) directly to avoid racing on the global customBaseDirectory.
      // listModels skips the symlink (isDirectory == false for symlink URLs), so
      // result is empty before removal too.
      let modelsBefore = try Acervo.listModels(in: tempRoot)
      #expect(
        modelsBefore.isEmpty,
        "Symlink entry must be skipped by listModels, got \(modelsBefore.count)"
      )

      // Remove the symlink entry only — must not throw even though target still exists.
      try FileManager.default.removeItem(at: symlinkURL)

      // After removing the symlink, listModels must still return empty.
      let modelsAfter = try Acervo.listModels(in: tempRoot)
      #expect(
        modelsAfter.isEmpty,
        "Expected 0 models after symlink removal, got \(modelsAfter.count)"
      )

      // The real model directory and its config.json must still exist on disk.
      let configStillExists = FileManager.default.fileExists(
        atPath: realModelDir.appendingPathComponent("config.json").path
      )
      #expect(configStillExists, "Real model data must survive symlink deletion")
    }
  }

}  // extension CustomBaseDirectorySuite
