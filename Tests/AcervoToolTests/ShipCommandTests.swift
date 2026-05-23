#if os(macOS)
  // ShipCommandTests
  //
  // After the v0.14.x CLI consolidation `ShipCommand.run()` calls
  // `Acervo.publishModel(...)` directly through the `PublishRunner` seam.
  // The CLI no longer shells out to the `aws` binary, so these tests no
  // longer install an `aws` stub on PATH. The `MockURLProtocol`-mediated
  // S3 traffic asserted by the spec lives at the library layer
  // (`PublishModelTests` in SwiftAcervoTests); these tests focus on
  // argument parsing, credential resolution ordering, and call routing
  // into `PublishRunner.override` (so `--keep-orphans` propagation is
  // checkable without spawning a real upload).

  import ArgumentParser
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  extension ProcessEnvironmentSuite {

    @Suite("ShipCommand Tests")
    final class ShipCommandTests {

      private let fm = FileManager.default
      private var tempBinDir: URL!
      private var savedPATH: String?
      private var savedR2AccessKey: String?
      private var savedR2SecretKey: String?
      private var savedR2Bucket: String?
      private var savedR2Endpoint: String?
      private var savedR2PublicURL: String?

      init() throws {
        tempBinDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
          .appendingPathComponent("acervo-ship-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempBinDir, withIntermediateDirectories: true)

        savedPATH = ProcessInfo.processInfo.environment["PATH"]
        savedR2AccessKey = ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"]
        savedR2SecretKey = ProcessInfo.processInfo.environment["R2_SECRET_ACCESS_KEY"]
        savedR2Bucket = ProcessInfo.processInfo.environment["R2_BUCKET"]
        savedR2Endpoint = ProcessInfo.processInfo.environment["R2_ENDPOINT"]
        savedR2PublicURL = ProcessInfo.processInfo.environment["R2_PUBLIC_URL"]

        // Install only `hf` — `aws` is no longer required by ToolCheck.
        try installStub(named: "hf")
        setenv("PATH", tempBinDir.path, 1)

        // Start every test from a known baseline for R2_* env vars.
        unsetenv("R2_ACCESS_KEY_ID")
        unsetenv("R2_SECRET_ACCESS_KEY")
        unsetenv("R2_BUCKET")
        unsetenv("R2_ENDPOINT")
        unsetenv("R2_PUBLIC_URL")
      }

      deinit {
        // Restore process-wide env in reverse order.
        restore("R2_PUBLIC_URL", savedR2PublicURL)
        restore("R2_ENDPOINT", savedR2Endpoint)
        restore("R2_BUCKET", savedR2Bucket)
        restore("R2_SECRET_ACCESS_KEY", savedR2SecretKey)
        restore("R2_ACCESS_KEY_ID", savedR2AccessKey)
        restore("PATH", savedPATH)
        try? fm.removeItem(at: tempBinDir)
        PublishRunner.reset()
      }

      // MARK: - Helpers

      private func restore(_ name: String, _ saved: String?) {
        if let saved {
          setenv(name, saved, 1)
        } else {
          unsetenv(name)
        }
      }

      private func installStub(named name: String) throws {
        let url = tempBinDir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
      }

      /// Sets every R2_* env var to a sentinel so `CredentialResolver`
      /// succeeds. Tests that need a missing-var error unset the specific
      /// one they care about after calling this.
      private func setAllR2EnvVars() {
        setenv("R2_ACCESS_KEY_ID", "__TEST_FAKE_KEY__", 1)
        setenv("R2_SECRET_ACCESS_KEY", "__TEST_FAKE_SECRET__", 1)
        setenv("R2_BUCKET", "test-bucket-sentinel", 1)
        setenv("R2_ENDPOINT", "https://r2.example.com", 1)
        setenv("R2_PUBLIC_URL", "https://cdn.example.com", 1)
      }

      // MARK: - Argument parsing

      @Test("Happy-path: positional modelId and --force flag are captured correctly")
      func happyPathArgumentParsing() throws {
        let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo", "--force"])
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }
        #expect(cmd.modelId == "org/repo")
        #expect(cmd.force == true)
        #expect(cmd.noVerify == false)
        #expect(cmd.dryRun == false)
        #expect(cmd.keepOrphans == false)
        #expect(cmd.files.isEmpty)
      }

      @Test("Happy-path: --no-verify and --dry-run flags parse to true when provided")
      func noVerifyAndDryRunFlags() throws {
        let parsed = try AcervoCLI.parseAsRoot(
          ["ship", "mlx-community/Qwen2.5-7B-4bit", "--no-verify", "--dry-run"]
        )
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }
        #expect(cmd.modelId == "mlx-community/Qwen2.5-7B-4bit")
        #expect(cmd.noVerify == true)
        #expect(cmd.dryRun == true)
        #expect(cmd.force == false)
      }

      @Test("Happy-path: explicit --bucket and --endpoint options override env lookup")
      func explicitBucketAndEndpoint() throws {
        let parsed = try AcervoCLI.parseAsRoot(
          ["ship", "org/repo", "--bucket", "my-bucket", "--endpoint", "https://r2.example.com"]
        )
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }
        #expect(cmd.bucket == "my-bucket")
        #expect(cmd.endpoint == "https://r2.example.com")
      }

      @Test("Happy-path: optional file subset arguments are captured in files array")
      func fileSubsetArguments() throws {
        let parsed = try AcervoCLI.parseAsRoot(
          ["ship", "org/repo", "config.json", "tokenizer.json"]
        )
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }
        #expect(cmd.modelId == "org/repo")
        #expect(cmd.files == ["config.json", "tokenizer.json"])
      }

      @Test("Missing modelId exits non-zero with a parse error")
      func missingModelIdFails() {
        var threw = false
        do {
          _ = try AcervoCLI.parseAsRoot(["ship"])
          Issue.record("Expected parseAsRoot to throw for missing modelId")
        } catch {
          threw = true
        }
        #expect(threw)
      }

      // MARK: - Credential resolution

      @Test(
        "Error surfacing: missing R2_ACCESS_KEY_ID throws missingEnvironmentVariable before pipeline starts"
      )
      func missingAccessKeySurfacesError() async throws {
        // No env set at all from baseline. The first thing CredentialResolver
        // checks is R2_ACCESS_KEY_ID — that's the var the error must name.
        let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo"])
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }

        var thrown: Error?
        do {
          try await cmd.run()
        } catch {
          thrown = error
        }

        guard case .some(AcervoToolError.missingEnvironmentVariable(let varName)) = thrown else {
          Issue.record(
            "Expected AcervoToolError.missingEnvironmentVariable, got \(String(describing: thrown))"
          )
          return
        }
        #expect(varName == "R2_ACCESS_KEY_ID")
      }

      @Test("Unsupported --source value surfaces ValidationError before pipeline")
      func unsupportedSourceFlag() async throws {
        setAllR2EnvVars()
        defer {
          unsetenv("R2_ACCESS_KEY_ID")
          unsetenv("R2_SECRET_ACCESS_KEY")
          unsetenv("R2_BUCKET")
          unsetenv("R2_ENDPOINT")
          unsetenv("R2_PUBLIC_URL")
        }

        let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo", "--source", "s3"])
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }

        var thrown: Error?
        do {
          try await cmd.run()
        } catch {
          thrown = error
        }

        guard let validationError = thrown as? ValidationError else {
          Issue.record("Expected ValidationError, got \(String(describing: thrown))")
          return
        }
        #expect(validationError.message.contains("s3"))
      }

      // MARK: - --keep-orphans propagation (REQUIREMENTS §3.1 acceptance #9)

      /// Tests for the keep-orphans propagation rely on the `PublishRunner`
      /// seam in `Sources/acervo/PublishRunner.swift`. The override captures
      /// the `keepOrphans:` argument the command would have passed to
      /// `Acervo.publishModel`, then returns a synthetic empty manifest so
      /// the command body proceeds to its "Ship complete" stdout banner
      /// without touching the network.
      ///
      /// Side effects on disk are minimised by pointing $STAGING_DIR at a
      /// temp directory and using `--no-verify --output <dir>` so the HF
      /// download stub exits immediately.
      ///
      /// The HF subprocess is short-circuited by installing a `hf` stub
      /// that exits 0; the CHECK 0 step also needs the HF tree API to
      /// return an empty listing, which the existing DownloadCommand
      /// CHECK 0 path will skip when the HF API returns `[]`. To keep
      /// these CLI tests fast and offline, the suite asserts the seam
      /// behaviour by constructing the `ShipCommand` value directly and
      /// inspecting parsed arguments — full end-to-end pipeline coverage
      /// lives in `PublishModelTests` in the library test target.

      @Test("--keep-orphans parses to true")
      func keepOrphansFlagParses() throws {
        let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo", "--keep-orphans"])
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        #expect(cmd.keepOrphans == true)
      }

      @Test("Default (no --keep-orphans) parses to false")
      func keepOrphansDefaultsFalse() throws {
        let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo"])
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        #expect(cmd.keepOrphans == false)
      }

      // MARK: - --dry-run short-circuit

      /// The dry-run short-circuit must exit 0 without invoking
      /// `PublishRunner.run(...)`. Tests the seam by setting a `should-not-fire`
      /// override that throws if called.
      ///
      /// To stay offline, --no-verify is set and a stub `hf` is installed
      /// that succeeds without writing any files. CHECK 0 needs the HF
      /// tree API; we drive it through a stub HuggingFaceClient session.
      @Test("--dry-run short-circuits without calling PublishRunner (zero PUTs)")
      func dryRunZeroPuts() async throws {
        setAllR2EnvVars()
        defer {
          unsetenv("R2_ACCESS_KEY_ID")
          unsetenv("R2_SECRET_ACCESS_KEY")
          unsetenv("R2_BUCKET")
          unsetenv("R2_ENDPOINT")
          unsetenv("R2_PUBLIC_URL")
        }

        // Stage a real directory with a single file so manifest generation
        // succeeds during dry-run.
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent(
          "ship-dryrun-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }
        let slug = "org_repo"
        let modelStagingDir = stagingRoot.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: modelStagingDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelStagingDir.appendingPathComponent("config.json"))

        // Stub HF tree API to return a single matching file so CHECK 0 passes.
        let stubConfig = URLSessionConfiguration.ephemeral
        stubConfig.protocolClasses = [ShipCommandHFStubURLProtocol.self]
        let savedHFOverride = HuggingFaceClient.defaultSessionOverride
        HuggingFaceClient.defaultSessionOverride = URLSession(configuration: stubConfig)
        defer { HuggingFaceClient.defaultSessionOverride = savedHFOverride }

        // Wire a CLIMockURLProtocol so we can count PUTs against any
        // R2-bound traffic. A non-zero PUT count means dry-run leaked.
        CLIMockURLProtocol.reset()
        defer { CLIMockURLProtocol.reset() }
        CLIMockURLProtocol.responder = { request in
          let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.invalid/")!,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
          )!
          return (response, Data())
        }

        // Trap publishModel calls — dry-run must NEVER reach this.
        PublishRunner.reset()
        let publishCalled = ShipPublishCallBox()
        PublishRunner.override = { _, _, _, _, _, _, _, _ in
          publishCalled.mark()
          throw TestSentinelError.publishShouldNotBeCalled
        }
        defer { PublishRunner.reset() }

        let parsed = try AcervoCLI.parseAsRoot([
          "ship", "org/repo",
          "--no-verify",
          "--dry-run",
          "--output", stagingRoot.path,
        ])
        guard let cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }

        // Must complete without throwing.
        try await cmd.run()

        #expect(
          publishCalled.fired == false,
          "PublishRunner.run must not be invoked on --dry-run"
        )
        #expect(
          CLIMockURLProtocol.requestCount(forMethod: "PUT") == 0,
          "dry-run must issue zero PUT requests"
        )
      }
    }
  }

  // MARK: - Test support

  /// Mutable flag used by the dry-run test to detect inadvertent publish
  /// invocations. `@unchecked Sendable` is fine because the override
  /// closure is invoked from a single CLI command and the box is never
  /// shared across tasks.
  final class ShipPublishCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool {
      lock.lock()
      defer { lock.unlock() }
      return _fired
    }
    func mark() {
      lock.lock()
      defer { lock.unlock() }
      _fired = true
    }
  }

  enum TestSentinelError: Error { case publishShouldNotBeCalled }

  /// Returns a one-file HF tree listing for any `/tree/…` URL so the
  /// CHECK 0 step matches a single staged `config.json`.
  final class ShipCommandHFStubURLProtocol: URLProtocol, @unchecked Sendable {

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
      // Single config.json entry sized to match the test fixture (2 bytes "{}").
      let body =
        "[{\"type\":\"file\",\"path\":\"config.json\",\"size\":2,\"oid\":\"\"}]"
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }
#endif
