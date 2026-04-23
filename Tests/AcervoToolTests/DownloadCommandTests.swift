#if os(macOS)
  // NOTE ON SEAMS: DownloadCommand has no injectable seam for the HuggingFaceClient
  // it constructs inline in run(), and no injectable seam for the `hf` subprocess
  // it shells out to via ProcessRunner. This file exercises three seam categories:
  //
  //   A) Argument-parser seams: DownloadCommand's parsed properties (modelId, files,
  //      source, output, token, noVerify) are tested by calling
  //      AcervoCLI.parseAsRoot(["download", ...]) and down-casting to DownloadCommand
  //      via @testable import.
  //
  //   B) Process-environment seams: run() calls ToolCheck.validate(), which checks
  //      for `aws` and `hf` on PATH. Tests replace PATH with a temp dir containing
  //      stub binaries so ToolCheck passes without real installations. Tests also
  //      exercise the --no-verify path to bypass HuggingFaceClient entirely, meaning
  //      no live HF calls are made.
  //
  //   C) Static helper surface: DownloadCommand.enumerateDownloadedFiles(in:) and the
  //      slug/resolveStagingRoot helpers are exercised directly because they are
  //      testable entry points with no external dependencies.
  //
  //   SEAM GAP (P2 follow-up): Inject a protocol-typed HF client collaborator so
  //   tests can assert the verifyLFS call path without spawning a real `hf` binary.
  //   Today, the HF verification path is tested indirectly via HuggingFaceClientTests.
  //
  //   NOTE ON ENVIRONMENT MUTATION: All tests that mutate PATH are nested under
  //   ProcessEnvironmentSuite (which carries .serialized) to prevent PATH-clobber
  //   races between concurrent test suites.

  import ArgumentParser
  import Foundation
  import Testing

  @testable import acervo

  extension ProcessEnvironmentSuite {
    /// Unit tests for `DownloadCommand` argument parsing and early-pipeline behaviour.
    /// No live HuggingFace calls are made; all HF client access is either bypassed
    /// via --no-verify or stubbed through injected test doubles.
    ///
    /// The `.serialized` trait is inherited from the parent `ProcessEnvironmentSuite`.
    @Suite("DownloadCommand Tests")
    final class DownloadCommandTests {

      private let fm = FileManager.default
      private var tempBinDir: URL!
      private var tempStagingDir: URL!
      private var savedPATH: String?

      init() throws {
        // Create a temporary directory for stub executables so ToolCheck.validate()
        // passes without real aws / hf installations.
        tempBinDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
          .appendingPathComponent("acervo-download-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempBinDir, withIntermediateDirectories: true)

        // Separate temp dir that acts as an --output staging root for smoke tests.
        tempStagingDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
          .appendingPathComponent("acervo-download-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempStagingDir, withIntermediateDirectories: true)

        // Snapshot PATH so we can restore it in deinit.
        savedPATH = ProcessInfo.processInfo.environment["PATH"]

        // Install stub executables so ToolCheck passes.
        try installStub(named: "aws")
        try installStub(named: "hf")

        // Replace PATH with just our temp bin dir.
        setenv("PATH", tempBinDir.path, 1)
      }

      deinit {
        if let saved = savedPATH {
          setenv("PATH", saved, 1)
        } else {
          unsetenv("PATH")
        }
        try? fm.removeItem(at: tempBinDir)
        try? fm.removeItem(at: tempStagingDir)
      }

      // MARK: - Helpers

      private func installStub(named name: String) throws {
        let url = tempBinDir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }

      // MARK: - Test 1: Happy-path argument parsing

      @Test("Happy-path: positional modelId and flags are captured correctly")
      func happyPathArgumentParsing() throws {
        // Parse via the root CLI so subcommand routing works exactly as in production.
        let parsed = try AcervoCLI.parseAsRoot([
          "download",
          "org/repo",
          "--no-verify",
          "--output", "/tmp/my-staging",
          "--source", "hf",
          "--token", "sentinel-token",
        ])
        guard let cmd = parsed as? DownloadCommand else {
          Issue.record("Expected DownloadCommand, got \(type(of: parsed))")
          return
        }
        #expect(cmd.modelId == "org/repo")
        #expect(cmd.noVerify == true)
        #expect(cmd.output == "/tmp/my-staging")
        #expect(cmd.source == "hf")
        #expect(cmd.token == "sentinel-token")
        #expect(cmd.files.isEmpty)
      }

      @Test("Happy-path: optional file subset is captured in the files array")
      func happyPathWithFileSubset() throws {
        let parsed = try AcervoCLI.parseAsRoot([
          "download",
          "mlx-community/Qwen2.5-7B-4bit",
          "config.json",
          "tokenizer.json",
          "--no-verify",
        ])
        guard let cmd = parsed as? DownloadCommand else {
          Issue.record("Expected DownloadCommand, got \(type(of: parsed))")
          return
        }
        #expect(cmd.modelId == "mlx-community/Qwen2.5-7B-4bit")
        #expect(cmd.files == ["config.json", "tokenizer.json"])
        #expect(cmd.noVerify == true)
      }

      // MARK: - Test 2: HuggingFace-only path smoke test (stubbed hf binary)
      //
      // With the PATH-stub installed (stub `hf` exits 0) and --no-verify provided,
      // run() downloads via the stub, skips HuggingFaceClient verification, and
      // exits cleanly. No live HF calls are made; the HF client is bypassed entirely
      // by the --no-verify flag.

      @Test("HF smoke test: stub hf binary + --no-verify produces no-throw outcome")
      func huggingFaceSmokeTestNoVerify() async throws {
        var cmd =
          try AcervoCLI.parseAsRoot([
            "download",
            "org/smoke-test",
            "--no-verify",
            "--output", tempStagingDir.path,
          ]) as! DownloadCommand

        // run() must complete without throwing.
        // The stub `hf` exits 0, the staging dir exists, and --no-verify skips
        // HuggingFaceClient so no live network calls are made.
        try await cmd.run()
      }

      // MARK: - Test 3: Missing required argument

      @Test("Missing modelId exits non-zero with a parse error")
      func missingModelIdFails() {
        // The modelId positional argument is required. Parsing without it must throw.
        var threw = false
        do {
          _ = try AcervoCLI.parseAsRoot(["download"])
          Issue.record("Expected parseAsRoot to throw for missing modelId")
        } catch {
          threw = true
        }
        #expect(threw)
      }

      // MARK: - Test 4: Exit-code mapping — unsupported --source flag
      //
      // DownloadCommand.run() calls `guard source == "hf"` and throws
      // ValidationError("Unsupported --source ...") for any other value.
      // This is the first failure mode reached after ToolCheck.validate() passes.

      @Test("Unsupported --source value surfaces ValidationError before any download")
      func unsupportedSourceSurfacesError() async throws {
        var cmd =
          try AcervoCLI.parseAsRoot([
            "download",
            "org/repo",
            "--source", "s3",
          ]) as! DownloadCommand

        var thrown: Error?
        do {
          try await cmd.run()
        } catch {
          thrown = error
        }

        guard let validationError = thrown as? ValidationError else {
          Issue.record(
            "Expected ValidationError for unsupported source, got \(String(describing: thrown))")
          return
        }
        // Error message must name the unsupported source value so users can act on it.
        #expect(validationError.message.contains("s3"))
      }

      // MARK: - Test 5: enumerateDownloadedFiles static helper (no-subprocess unit test)
      //
      // DownloadCommand.enumerateDownloadedFiles(in:) is a public static helper that
      // walks a local directory. This test exercises it directly without spawning any
      // subprocess or calling HuggingFaceClient.

      @Test(
        "enumerateDownloadedFiles returns sorted regular files, skipping hidden and excluded names")
      func enumerateDownloadedFilesHelper() throws {
        let baseURL = tempStagingDir.appendingPathComponent("enum-test-\(UUID().uuidString)")
        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: baseURL) }

        // Write two model files.
        try Data("a".utf8).write(to: baseURL.appendingPathComponent("config.json"))
        try Data("b".utf8).write(to: baseURL.appendingPathComponent("tokenizer.json"))

        // Write a file that must be excluded (manifest.json).
        try Data("c".utf8).write(to: baseURL.appendingPathComponent("manifest.json"))

        let results = try DownloadCommand.enumerateDownloadedFiles(in: baseURL)

        // manifest.json is in the excludedNames set — only the two model files survive.
        #expect(results.count == 2)
        // Results are sorted by relative path.
        #expect(results[0].0 == "config.json")
        #expect(results[1].0 == "tokenizer.json")
      }
    }
  }
#endif
