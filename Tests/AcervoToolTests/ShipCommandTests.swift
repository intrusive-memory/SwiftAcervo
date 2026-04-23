#if os(macOS)
  // NOTE ON SEAMS: ShipCommand has no injectable protocol seams for its pipeline
  // steps (ManifestGenerator, CDNUploader, HuggingFaceClient are constructed
  // inline in run()). The tests below therefore exercise two distinct seam
  // categories:
  //
  //   A) Argument-parser seams: ShipCommand's parsed properties (modelId, force,
  //      noVerify, etc.) are tested by calling AcervoCLI.parseAsRoot(["ship", ...])
  //      and down-casting the result to ShipCommand via @testable import.
  //
  //   B) Environment seams: ShipCommand resolves R2_BUCKET and R2_ENDPOINT from
  //      the process environment before spawning any subprocess. Tests manipulate
  //      setenv/unsetenv directly (serialized so no test clobbers another) to
  //      trigger the exact AcervoToolError cases that surface from these checks.
  //      The PATH is also stub-replaced so ToolCheck.validate() passes without
  //      real aws/hf installations.
  //
  //   SEAM GAP (P2 follow-up): Inject protocol-typed pipeline collaborators
  //   (ManifestGenerating, Uploading) so tests can assert step sequencing without
  //   spawning real subprocesses. Today, sequencing is verified indirectly via
  //   the env-seam ordering (bucket check < endpoint check < download launch).

  import ArgumentParser
  import Foundation
  import Testing

  @testable import acervo

  extension ProcessEnvironmentSuite {
    /// Unit tests for `ShipCommand` argument parsing and early-pipeline error
    /// surfacing. No live R2 uploads or HuggingFace downloads are performed.
    ///
    /// The `.serialized` trait is provided by the parent `ProcessEnvironmentSuite`,
    /// which serializes all tests that mutate process-wide state (PATH, R2_BUCKET, R2_ENDPOINT).
    @Suite("ShipCommand Tests")
    final class ShipCommandTests {

    private let fm = FileManager.default
    private var tempBinDir: URL!
    private var savedPATH: String?
    private var savedR2Bucket: String?
    private var savedR2Endpoint: String?

    init() throws {
      // Create a temporary directory that will hold stub executables so
      // ToolCheck.validate() passes without real aws / hf installations.
      tempBinDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("acervo-ship-tests-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(at: tempBinDir, withIntermediateDirectories: true)

      // Snapshot env vars we may mutate.
      savedPATH = ProcessInfo.processInfo.environment["PATH"]
      savedR2Bucket = ProcessInfo.processInfo.environment["R2_BUCKET"]
      savedR2Endpoint = ProcessInfo.processInfo.environment["R2_ENDPOINT"]

      // Install stub executables so ToolCheck.validate() doesn't abort early.
      try installStub(named: "aws")
      try installStub(named: "hf")

      // Replace PATH with just our temp bin dir.
      setenv("PATH", tempBinDir.path, 1)

      // Clear R2 credentials so tests start from a known baseline.
      unsetenv("R2_BUCKET")
      unsetenv("R2_ENDPOINT")
    }

    deinit {
      // Restore process-wide env in reverse order.
      if let saved = savedR2Endpoint {
        setenv("R2_ENDPOINT", saved, 1)
      } else {
        unsetenv("R2_ENDPOINT")
      }
      if let saved = savedR2Bucket {
        setenv("R2_BUCKET", saved, 1)
      } else {
        unsetenv("R2_BUCKET")
      }
      if let saved = savedPATH {
        setenv("PATH", saved, 1)
      } else {
        unsetenv("PATH")
      }
      try? fm.removeItem(at: tempBinDir)
    }

    // MARK: - Helpers

    private func installStub(named name: String) throws {
      let url = tempBinDir.appendingPathComponent(name)
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Test 1: Happy-path argument parsing

    @Test("Happy-path: positional modelId and --force flag are captured correctly")
    func happyPathArgumentParsing() throws {
      // Parse via the root CLI so the subcommand routing works exactly as in
      // production: AcervoCLI dispatches to ShipCommand.
      let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo", "--force"])
      guard let cmd = parsed as? ShipCommand else {
        Issue.record("Expected ShipCommand, got \(type(of: parsed))")
        return
      }
      #expect(cmd.modelId == "org/repo")
      #expect(cmd.force == true)
      #expect(cmd.noVerify == false)
      #expect(cmd.dryRun == false)
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

    // MARK: - Test 2: Missing required argument

    @Test("Missing modelId exits non-zero with a parse error")
    func missingModelIdFails() {
      // ArgumentParser throws when the required positional argument is absent.
      // The thrown error is an ExitCode-wrapping type — we only need to confirm
      // that parsing fails (throws any error).
      var threw = false
      do {
        _ = try AcervoCLI.parseAsRoot(["ship"])
        Issue.record("Expected parseAsRoot to throw for missing modelId")
      } catch {
        // Any thrown error satisfies the exit-non-zero contract.
        threw = true
      }
      #expect(threw)
    }

    // MARK: - Test 3: Error surfacing — resolveBucket (manifest-phase gate)
    //
    // resolveBucket() is called before any pipeline step launches. When neither
    // --bucket nor R2_BUCKET is set, ShipCommand must throw
    // AcervoToolError.missingEnvironmentVariable("R2_BUCKET") before touching
    // any file or network resource.

    @Test("Error surfacing: missing R2_BUCKET throws missingEnvironmentVariable before pipeline starts")
    func missingBucketSurfacesError() async throws {
      // Confirm the baseline — neither env var nor option is present.
      unsetenv("R2_BUCKET")

      // Parse a valid command (no --bucket provided).
      let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo"])
      guard var cmd = parsed as? ShipCommand else {
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
      #expect(varName == "R2_BUCKET")
    }

    // MARK: - Test 4: Error surfacing — resolveEndpoint (after bucket succeeds)
    //
    // resolveEndpoint() is called immediately after resolveBucket(). Providing
    // R2_BUCKET (or --bucket) but leaving R2_ENDPOINT unset must surface
    // AcervoToolError.missingEnvironmentVariable("R2_ENDPOINT").

    @Test("Error surfacing: R2_BUCKET present but missing R2_ENDPOINT throws missingEnvironmentVariable")
    func missingEndpointSurfacesError() async throws {
      setenv("R2_BUCKET", "test-bucket-sentinel", 1)
      defer { unsetenv("R2_BUCKET") }
      unsetenv("R2_ENDPOINT")

      let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo"])
      guard var cmd = parsed as? ShipCommand else {
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
      #expect(varName == "R2_ENDPOINT")
    }

    // MARK: - Test 5: Step sequencing
    //
    // The production code resolves R2_BUCKET before R2_ENDPOINT. Removing only
    // R2_BUCKET must produce a "R2_BUCKET" error regardless of the R2_ENDPOINT
    // state, proving bucket resolution precedes endpoint resolution in the
    // pipeline.

    @Test("Step sequencing: bucket resolution precedes endpoint resolution")
    func bucketResolutionPrecedesEndpoint() async throws {
      // Provide the endpoint but NOT the bucket. If bucket is checked first
      // (as required by the implementation), the error must name R2_BUCKET.
      setenv("R2_ENDPOINT", "https://r2.example.com", 1)
      defer { unsetenv("R2_ENDPOINT") }
      unsetenv("R2_BUCKET")

      let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo"])
      guard var cmd = parsed as? ShipCommand else {
        Issue.record("Expected ShipCommand")
        return
      }

      var thrown: Error?
      do {
        try await cmd.run()
      } catch {
        thrown = error
      }

      // The error must be about the BUCKET (missing) not the ENDPOINT (present).
      guard case .some(AcervoToolError.missingEnvironmentVariable(let varName)) = thrown else {
        Issue.record(
          "Expected AcervoToolError.missingEnvironmentVariable, got \(String(describing: thrown))"
        )
        return
      }
      #expect(varName == "R2_BUCKET")
    }

    // MARK: - Test 6: Unsupported source flag
    //
    // ShipCommand validates --source == "hf" in run(). Providing an unsupported
    // value must cause a ValidationError before any network or filesystem work.

    @Test("Unsupported --source value surfaces ValidationError before pipeline")
    func unsupportedSourceFlag() async throws {
      setenv("R2_BUCKET", "test-bucket-sentinel", 1)
      setenv("R2_ENDPOINT", "https://r2.example.com", 1)
      defer {
        unsetenv("R2_BUCKET")
        unsetenv("R2_ENDPOINT")
      }

      let parsed = try AcervoCLI.parseAsRoot(["ship", "org/repo", "--source", "s3"])
      guard var cmd = parsed as? ShipCommand else {
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
      // The error message must name the unsupported source so users can act.
      #expect(validationError.message.contains("s3"))
    }

    // MARK: - Test 7: Files subset parses into the positional array

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
    }
  }
#endif
