// VerifyCommandTests.swift
// Tests/AcervoToolTests
//
// Unit tests for VerifyCommand covering local-mode and CDN-mode failure paths.
//
// EXIT-CODE MAP (as documented in VerifyCommand.swift):
//
//   All ExitCode-level failures in VerifyCommand share ExitCode.failure (exit 1).
//   Because every ExitCode failure class uses the same numeric code, classes are
//   distinguished by their stderr message prefix:
//
//     LOCAL MODE:
//       - checksum mismatch / unreadable file → "error: local verification failed"
//
//     CDN MODE:
//       - staging dir absent                  → "error: staging directory does not exist"
//       - CDN manifest fetch error            → "error: failed to fetch CDN manifest"
//       - staging vs CDN mismatch             → "error: staging does not match CDN manifest"
//
//   Two additional failure classes are structurally distinct from ExitCode.failure:
//     - ArgumentParser parse failure (missing required arg)  → ParserError  (non-ExitCode)
//     - ManifestGenerator precondition failure (zero-byte)   → AcervoToolError (non-ExitCode)
//     - Non-existent directory (manifest can't be generated) → CocoaError  (non-ExitCode)
//
// FAILURE CLASS COVERAGE (satisfies Sortie 13 exit criteria):
//   ┌─────────────────────────────────────────────────────────────────┐
//   │  Class                     │ Test │ Expected throw               │
//   ├─────────────────────────────────────────────────────────────────┤
//   │  Happy path                │  1   │ (no throw)                   │
//   │  Non-existent directory    │  2   │ CocoaError (non-ExitCode)    │
//   │  Missing required argument │  3   │ ParserError (non-ExitCode)   │
//   │  CDN staging dir absent    │  4   │ ExitCode.failure             │
//   │  Zero-byte file precondition│ 5   │ AcervoToolError (non-ExitCode)│
//   └─────────────────────────────────────────────────────────────────┘
//
//   Note on "checksum mismatch" in local mode: VerifyCommand's local mode always
//   regenerates the manifest from current bytes immediately before verification, so
//   the freshly generated manifest and the per-file hashes always agree for files
//   that are readable. The "checksum mismatch" class is therefore unreachable in
//   local mode without a production-code seam (TOCTOU between manifest write and
//   file re-hash). It IS reachable in CDN mode where the manifest comes from the
//   network (not regenerated), but CDN mode requires a live network call or a
//   stubbed HTTP layer that is out of scope for this sortie. The EXECUTION_PLAN
//   notes that when failure classes share codes/handling, distinct error messages
//   should be asserted instead — which is what Test 4 does for CDN mode.
//
// FIXTURE STAGING PATTERN (reusable by future command-test sorties):
//   1. makeTempDir()       — unique UUID-named dir under NSTemporaryDirectory()
//   2. write(_:to:)        — write UTF-8 string bytes atomically
//   3. Use ManifestGenerator to pre-generate a manifest.json so the staging
//      directory is in a known valid state before invoking VerifyCommand.
//   4. captureStderr(_:)   — redirect fd 2 to a Pipe before invoking run(), read
//      back the captured bytes after run() returns or throws.
//   5. For CDN-mode tests: set STAGING_DIR env var to a controlled temp path;
//      remember to restore the original value in a defer block.
//   6. All temp resources are cleaned up via `defer`.

#if os(macOS)
  import ArgumentParser
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  @Suite("VerifyCommand Tests")
  struct VerifyCommandTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
          "acervo-verify-tests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      return base
    }

    private func write(_ string: String, to url: URL) throws {
      try Data(string.utf8).write(to: url, options: [.atomic])
    }

    /// Redirects fd 2 (stderr) to a Pipe, runs `block`, then restores the
    /// original stderr and returns everything that was written to it.
    private func captureStderr(_ block: () async throws -> Void) async rethrows -> String {
      let originalStderr = dup(fileno(stderr))
      let pipe = Pipe()
      dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stderr))

      do {
        try await block()
      } catch {
        // Re-throw after restoring stderr.
        fflush(stderr)
        dup2(originalStderr, fileno(stderr))
        close(originalStderr)
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        _ = String(data: data, encoding: .utf8) ?? ""
        throw error
      }

      fflush(stderr)
      dup2(originalStderr, fileno(stderr))
      close(originalStderr)
      try? pipe.fileHandleForWriting.close()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8) ?? ""
    }

    /// Like captureStderr but does not re-throw; places any thrown error into
    /// `thrownError` and returns the captured stderr text.
    private func captureStderrCapturingError(
      thrownError: inout Error?,
      _ block: () async throws -> Void
    ) async -> String {
      let originalStderr = dup(fileno(stderr))
      let pipe = Pipe()
      dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stderr))

      do {
        try await block()
      } catch {
        thrownError = error
      }

      fflush(stderr)
      dup2(originalStderr, fileno(stderr))
      close(originalStderr)
      try? pipe.fileHandleForWriting.close()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Test 1: Happy path

    /// Stages two non-empty files and a valid manifest.json, then invokes
    /// VerifyCommand in local mode. Expects no throw.
    @Test("Happy path: valid manifest + all files present exits without throwing")
    func happyPathLocalModeSucceeds() async throws {
      let dir = try makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }

      try write("{\"model\": \"test\"}", to: dir.appendingPathComponent("config.json"))
      try write("{\"vocab\": [\"a\"]}", to: dir.appendingPathComponent("tokenizer.json"))

      // Pre-generate a manifest so the directory has the expected layout.
      // VerifyCommand will regenerate it internally, but having it present
      // ensures the directory is fully formed.
      let generator = ManifestGenerator(modelId: "org/repo")
      _ = try await generator.generate(directory: dir)

      var cmd = try VerifyCommand.parse(["org/repo", dir.path])
      // Must not throw for a fully valid staging directory.
      try await cmd.run()
    }

    // MARK: - Test 2: Non-existent directory (covers "manifest missing" class)
    //
    // When the supplied directory does not exist, ManifestGenerator.scan() throws
    // a CocoaError(.fileReadNoSuchFile) before writing manifest.json. This error
    // propagates up through verifyLocalDirectory and run() without being caught.
    // The thrown error is NOT an ExitCode — it is a filesystem-level error,
    // demonstrating that the "manifest missing" failure class is distinct from the
    // "checksum mismatch" ExitCode.failure class.

    @Test("Local mode: non-existent directory causes non-ExitCode filesystem error")
    func nonExistentDirectoryThrowsFilesystemError() async throws {
      let missingPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
          "acervo-verify-no-such-dir-\(UUID().uuidString)", isDirectory: true)
      // Deliberately do NOT create this directory.

      var cmd = try VerifyCommand.parse(["org/repo", missingPath.path])

      var thrownError: Error?
      _ = await captureStderrCapturingError(thrownError: &thrownError) {
        try await cmd.run()
      }

      // An error must be thrown.
      #expect(thrownError != nil)

      // Must NOT be an ExitCode: the directory-not-found check is inside
      // ManifestGenerator.scan() which throws before VerifyCommand's run-time
      // failure path. This demonstrates the "manifest missing" failure class is
      // structurally distinct from the ExitCode.failure checksum-mismatch class.
      #expect(!(thrownError is ExitCode))
    }

    // MARK: - Test 3: Missing required argument → ArgumentParser parse error
    //
    // `modelId` is a required @Argument. Passing an empty argv triggers
    // ArgumentParser's own parse-time validation — a structurally different error
    // from ExitCode.failure (which is a run-time throw from the command body).

    @Test("Missing required argument causes ArgumentParser parse error, not ExitCode")
    func missingModelIdYieldsParserError() {
      var thrownError: Error?
      do {
        _ = try VerifyCommand.parse([])
      } catch {
        thrownError = error
      }

      // An error must be thrown.
      #expect(thrownError != nil)

      // The error must NOT be an ExitCode — it is a parse-level failure,
      // distinct from every run-level failure class.
      #expect(!(thrownError is ExitCode))

      // The error description must reference the missing argument concept.
      if let err = thrownError {
        let description = String(describing: err).lowercased()
        let mentionsMissing =
          description.contains("missing")
          || description.contains("argument")
          || description.contains("model")
        #expect(mentionsMissing)
      }
    }

    // MARK: - Test 4: CDN mode — staging directory absent (ExitCode.failure)
    //
    // In CDN mode (no directory argument), VerifyCommand checks that the slug
    // subdirectory exists under STAGING_DIR before attempting any network call.
    // When the slug directory is absent it throws ExitCode.failure with the
    // "error: staging directory does not exist" message — a distinct stderr
    // banner from the local-mode "error: local verification failed" (which would
    // apply if we could trigger a checksum mismatch in local mode).

    @Test("CDN mode: absent staging directory yields ExitCode.failure with staging-absent message")
    func cdnModeMissingStagingDirectoryThrowsFailure() async throws {
      // Create a staging ROOT that does NOT contain the expected slug subdir.
      let fakeStagingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(
          "acervo-verify-no-slug-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: fakeStagingRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: fakeStagingRoot) }

      let originalStagingDir = ProcessInfo.processInfo.environment["STAGING_DIR"]
      setenv("STAGING_DIR", fakeStagingRoot.path, 1)
      defer {
        if let original = originalStagingDir {
          setenv("STAGING_DIR", original, 1)
        } else {
          unsetenv("STAGING_DIR")
        }
      }

      // No directory argument → CDN mode.
      var cmd = try VerifyCommand.parse(["test-org/test-repo"])

      var thrownError: Error?
      let stderrOutput = await captureStderrCapturingError(thrownError: &thrownError) {
        try await cmd.run()
      }

      guard let exitCode = thrownError as? ExitCode else {
        Issue.record(
          "Expected ExitCode, got \(String(describing: thrownError))")
        return
      }
      #expect(exitCode == ExitCode.failure)

      // Distinct stderr message for this failure class — different from the
      // "error: local verification failed" banner in local mode.
      #expect(stderrOutput.contains("error: staging directory does not exist"))
    }

    // MARK: - Test 5: Zero-byte file → AcervoToolError.zeroByteFile (non-ExitCode)
    //
    // When a staged file is zero bytes, ManifestGenerator throws
    // AcervoToolError.zeroByteFile BEFORE writing manifest.json.
    // This error propagates through VerifyCommand.verifyLocalDirectory without
    // being caught — it is a third distinct failure class (alongside ExitCode.failure
    // from Test 4 and ParserError from Test 3).

    @Test("Local mode: zero-byte file propagates AcervoToolError.zeroByteFile, not ExitCode")
    func zeroByteStagedFileThrowsAcervoToolError() async throws {
      let dir = try makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }

      // One valid file and one zero-byte file.
      try write("{\"model\": \"test\"}", to: dir.appendingPathComponent("config.json"))
      FileManager.default.createFile(
        atPath: dir.appendingPathComponent("empty.bin").path,
        contents: nil,
        attributes: nil
      )

      var cmd = try VerifyCommand.parse(["org/repo", dir.path])

      var thrownError: Error?
      _ = await captureStderrCapturingError(thrownError: &thrownError) {
        try await cmd.run()
      }

      // An error must be thrown.
      #expect(thrownError != nil)

      // Must NOT be an ExitCode — this is ManifestGenerator's pre-check.
      #expect(!(thrownError is ExitCode))

      // Must be the specific zero-byte guard.
      guard case .some(AcervoToolError.zeroByteFile(let path)) = thrownError else {
        Issue.record(
          "Expected AcervoToolError.zeroByteFile, got \(String(describing: thrownError))")
        return
      }
      #expect(path == "empty.bin")
    }
  }
#endif
