#if os(macOS)
  import Foundation
  import XCTest

  @testable import SwiftAcervo
  @testable import acervo

  /// Integration tests for `HuggingFaceClient` that hit the live HuggingFace LFS API.
  ///
  /// All tests skip when `HF_TOKEN` is absent from the environment so that
  /// the suite exits 0 in CI environments without credentials.
  final class HuggingFaceDownloadTests: XCTestCase {

    /// A small public model that only has `config.json`. Using
    /// `facebook/opt-125m` because it is publicly available and tiny enough
    /// that verifying the config file completes quickly.
    private let testModelId = "facebook/opt-125m"
    private let testFilename = "config.json"

    private var tempDir: URL!

    override func setUp() async throws {
      try await super.setUp()
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("acervo-hf-integration-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      tempDir = base
    }

    override func tearDown() async throws {
      if let dir = tempDir {
        try? FileManager.default.removeItem(at: dir)
      }
      try await super.tearDown()
    }

    /// Downloads `config.json` from a small public model and verifies that
    /// CHECK 1 passes against the live HuggingFace LFS API.
    func testVerifyLFSPassesForValidDownload() async throws {
      guard ProcessInfo.processInfo.environment["HF_TOKEN"] != nil else {
        throw XCTSkip("HF_TOKEN not set")
      }

      // Download config.json using huggingface-cli.
      let stagedFile = tempDir.appendingPathComponent(testFilename)
      try downloadFile(modelId: testModelId, filename: testFilename, into: tempDir)

      // Compute the local SHA-256.
      let actualSHA256 = try IntegrityVerification.sha256(of: stagedFile)

      // Verify CHECK 1 against the live HF API — should pass without throwing.
      let client = HuggingFaceClient()
      try await client.verifyLFS(
        modelId: testModelId,
        filename: testFilename,
        actualSHA256: actualSHA256,
        stagingURL: stagedFile
      )

      // The file must still exist: verifyLFS only deletes on mismatch.
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: stagedFile.path),
        "Staging file must survive a successful CHECK 1"
      )
    }

    /// Writes corrupt bytes into a copy of a downloaded file and verifies that
    /// `HFIntegrityError.checksumMismatch` is thrown (CHECK 1 negative path).
    func testVerifyLFSThrowsChecksumMismatchForCorruptFile() async throws {
      guard ProcessInfo.processInfo.environment["HF_TOKEN"] != nil else {
        throw XCTSkip("HF_TOKEN not set")
      }

      // Download the real file first.
      let originalFile = tempDir.appendingPathComponent(testFilename)
      try downloadFile(modelId: testModelId, filename: testFilename, into: tempDir)

      // Derive the correct hash, then corrupt the file in a copy so we
      // exercise the mismatch branch without needing the original bytes.
      let corruptDir = tempDir.appendingPathComponent("corrupt-copy", isDirectory: true)
      try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
      let corruptFile = corruptDir.appendingPathComponent(testFilename)
      try Data("this is intentionally wrong bytes".utf8).write(to: corruptFile)

      // The corrupt file's SHA-256 differs from what HuggingFace advertises.
      let corruptSHA256 = try IntegrityVerification.sha256(of: corruptFile)

      let client = HuggingFaceClient()
      do {
        try await client.verifyLFS(
          modelId: testModelId,
          filename: testFilename,
          actualSHA256: corruptSHA256,
          stagingURL: corruptFile
        )
        XCTFail("Expected HFIntegrityError.checksumMismatch but no error was thrown")
      } catch HFIntegrityError.checksumMismatch(let filename, _, _) {
        XCTAssertEqual(filename, testFilename)
        // The staging file should have been deleted on mismatch.
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: corruptFile.path),
          "verifyLFS must remove the staging file on checksumMismatch"
        )
      } catch {
        XCTFail("Expected HFIntegrityError.checksumMismatch but got: \(error)")
      }

      // The original file should still exist.
      XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
    }

    // MARK: - Helpers

    /// Shells out to `huggingface-cli download` to fetch a single file.
    private func downloadFile(modelId: String, filename: String, into directory: URL) throws {
      var environment = ProcessInfo.processInfo.environment
      // HF_TOKEN is already in the environment; no need to set it explicitly.
      environment["TRANSFORMERS_VERBOSITY"] = "error"

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "huggingface-cli",
        "download",
        modelId,
        filename,
        "--local-dir",
        directory.path,
      ]
      process.environment = environment

      let stderrPipe = Pipe()
      process.standardError = stderrPipe
      process.standardOutput = Pipe()

      try process.run()
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      guard process.terminationStatus == 0 else {
        let stderr = String(data: stderrData, encoding: .utf8) ?? "<non-utf8>"
        throw NSError(
          domain: "HuggingFaceDownloadTests",
          code: Int(process.terminationStatus),
          userInfo: [NSLocalizedDescriptionKey: "huggingface-cli failed: \(stderr)"]
        )
      }
    }
  }
#endif
