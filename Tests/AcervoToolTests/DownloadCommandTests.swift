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
  //      stub binaries so ToolCheck passes without real installations. Tests use
  //      `HuggingFaceClient.defaultSessionOverride` to route HF API calls through
  //      a stubbed `URLSession`, so no live HF calls are made — including the
  //      always-on CHECK 0 completeness step that runs even with --no-verify.
  //
  //   C) Static helper surface: DownloadCommand.enumerateDownloadedFiles(in:) and the
  //      slug/resolveStagingRoot helpers are exercised directly because they are
  //      testable entry points with no external dependencies.
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
        // Drop any stubbed URLSession so other suites get the real shared
        // session back. The `.serialized` suite trait guarantees no other
        // suite is mid-flight while we mutate this static.
        HuggingFaceClient.defaultSessionOverride = nil
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

      // MARK: - Test 2: HuggingFace-only path smoke test (stubbed hf binary + URLSession)
      //
      // With the PATH-stub installed (stub `hf` exits 0), a stubbed `URLSession`
      // returning an empty tree, and --no-verify provided, run() downloads via the
      // stub, completes CHECK 0 against the empty tree, skips LFS verification, and
      // exits cleanly. No live HF calls are made — both `hf` (subprocess) and the
      // HF tree API (URLSession) are stubbed.

      @Test("HF smoke test: stub hf binary + stub HF API + --no-verify produces no-throw outcome")
      func huggingFaceSmokeTestNoVerify() async throws {
        // Use a dedicated stub URLProtocol class scoped to DownloadCommand
        // tests so its static state can't race with `HuggingFaceClient Tests`
        // (which share a different `StubURLProtocol`). Both suites run in
        // their own serialized order, but Swift Testing runs different
        // suites in parallel by default.
        let stubConfig = URLSessionConfiguration.ephemeral
        stubConfig.protocolClasses = [DownloadCommandStubURLProtocol.self]
        HuggingFaceClient.defaultSessionOverride = URLSession(configuration: stubConfig)

        var cmd =
          try AcervoCLI.parseAsRoot([
            "download",
            "org/smoke-test",
            "--no-verify",
            "--output", tempStagingDir.path,
          ]) as! DownloadCommand

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

      // MARK: - Test 5 prelude (dedicated stub URLProtocol)
      //
      // The smoke test installs a dedicated URLProtocol subclass so its
      // static state is fully independent of `StubURLProtocol` (used by
      // HuggingFaceClient Tests). This prevents cross-suite races where
      // both suites run in parallel and stomp on each other's responses.

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

  /// Stand-in for HuggingFace API requests issued by the always-on
  /// CHECK 0 step in `DownloadCommand.run()`. Returns an empty tree
  /// (`[]`) for any `/tree/...` URL, which means CHECK 0 has zero files
  /// to verify and exits cleanly.
  ///
  /// Lives in this file (not the shared HF stub) so its static state is
  /// not shared with `HuggingFaceClient Tests`. Different test suites
  /// run in parallel by default — sharing a global stub causes one
  /// suite's matchers to leak into the other's requests.
  final class DownloadCommandStubURLProtocol: URLProtocol, @unchecked Sendable {

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let url = request.url ?? URL(string: "https://stub.invalid/")!
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data("[]".utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }
#endif
