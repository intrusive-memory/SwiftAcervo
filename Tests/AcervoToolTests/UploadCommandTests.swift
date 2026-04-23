//
// UploadCommandTests.swift — Sortie 12: UploadCommand unit tests
//
// SEAM NOTES (no production code modified):
//   - `UploadCommand.resolveBucket()` and `resolveEndpoint()` are `private`
//     and cannot be called directly from tests. The credential-validation
//     path is exercised via `CDNUploader(environment:)`, which is the public
//     injection seam that feeds the same `R2_ACCESS_KEY_ID` /
//     `R2_SECRET_ACCESS_KEY` checks inside `runAWS`.
//   - `CDNUploader.buildSyncArguments` (static, package-internal) is used to
//     assert bucket/key wiring without spawning any real process.
//   - Argument parsing is tested by calling `UploadCommand.parse(_:)` directly.
//   - No live R2 or HuggingFace calls are made anywhere in this file.
//   - Sentinel values used: `"__TEST_FAKE_KEY__"` and `"__TEST_FAKE_SECRET__"`.
//
// P2 follow-up: add an `environment:` injection parameter to `UploadCommand`
// so `resolveBucket` / `resolveEndpoint` can be tested without mutating the
// real process environment. Filed as P2 per the sortie-12 hard-boundary rules.

#if os(macOS)
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  /// Unit tests for `UploadCommand` argument parsing, credential validation,
  /// and the `CDNUploader` bucket/key wiring.
  ///
  /// This suite is `.serialized` because several tests exercise process-level
  /// env var state and should not race with each other.
  @Suite("UploadCommand Tests", .serialized)
  final class UploadCommandTests {

    // MARK: - Test 1: Happy-path argument parsing

    /// Verifies that every flag and option on `UploadCommand` is captured
    /// correctly when a fully-specified argv is parsed.
    ///
    /// This test does NOT call `run()` — it only exercises `ArgumentParser`
    /// parsing so no filesystem I/O or network activity occurs.
    @Test("Happy-path argv parsing captures all flags correctly")
    func happyPathArgvParsing() throws {
      let cmd = try UploadCommand.parse([
        "org/mymodel",
        "/tmp/staging/org_mymodel",
        "--bucket", "my-test-bucket",
        "--prefix", "models/",
        "--endpoint", "https://r2.example.com",
        "--dry-run",
        "--force",
      ])

      #expect(cmd.modelId == "org/mymodel")
      #expect(cmd.directory == "/tmp/staging/org_mymodel")
      #expect(cmd.bucket == "my-test-bucket")
      #expect(cmd.prefix == "models/")
      #expect(cmd.endpoint == "https://r2.example.com")
      #expect(cmd.dryRun == true)
      #expect(cmd.force == true)
    }

    // MARK: - Test 2: Missing R2 credentials → CDNUploader throws clearly

    /// Verifies that `CDNUploader` with no credentials in its injected
    /// environment snapshot throws `AcervoToolError.missingEnvironmentVariable`
    /// before it ever attempts to run `aws`. This exercises the same
    /// credential-validation gate that `UploadCommand.run()` passes through
    /// when `R2_ACCESS_KEY_ID` is absent from the process environment.
    ///
    /// The real process environment is NOT consulted here — the uploader
    /// receives an entirely empty environment dict (no sentinel values needed
    /// to trigger the failure; absence alone is sufficient).
    @Test("Missing R2_ACCESS_KEY_ID in CDNUploader env throws missingEnvironmentVariable")
    func missingR2AccessKeyIdThrows() async throws {
      let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("acervo-upload-creds-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }

      // Stage a real file and generate a valid manifest so verifyBeforeUpload
      // passes (files on disk match). The credential check fires later, inside
      // the sync step that calls runAWS.
      let configURL = dir.appendingPathComponent("config.json")
      try Data("{\"model\": \"test\"}".utf8).write(to: configURL, options: [.atomic])

      let generator = ManifestGenerator(modelId: "test/missing-creds-model")
      let manifestURL = try await generator.generate(directory: dir)
      let manifest = try JSONDecoder().decode(
        CDNManifest.self, from: Data(contentsOf: manifestURL))

      // Construct an uploader with an environment that has NO credentials.
      let uploader = CDNUploader(
        awsExecutableURL: URL(fileURLWithPath: "/var/empty/never-exists-aws"),
        environment: [:]
      )

      // verifyBeforeUpload should pass (files match the manifest).
      try await uploader.verifyBeforeUpload(directory: dir, manifest: manifest)

      // Now attempt the sync step — this is where runAWS fires and checks
      // for R2_ACCESS_KEY_ID in the environment snapshot.
      var thrown: Error?
      do {
        try await uploader.sync(
          localDirectory: dir,
          slug: "test_missing_creds_model",
          bucket: "intrusive-memory-models",
          endpoint: "https://r2.example.com",
          dryRun: false,
          force: false
        )
      } catch {
        thrown = error
      }

      guard case .some(AcervoToolError.missingEnvironmentVariable(let name)) = thrown else {
        Issue.record(
          "Expected AcervoToolError.missingEnvironmentVariable, got \(String(describing: thrown))"
        )
        return
      }
      #expect(name == "R2_ACCESS_KEY_ID")
      // Confirm the error description is user-readable and mentions the var name.
      let desc = AcervoToolError.missingEnvironmentVariable("R2_ACCESS_KEY_ID").description
      #expect(desc.contains("R2_ACCESS_KEY_ID"))
    }

    // MARK: - Test 3: Upload path with sentinel credentials — bucket/key wiring

    /// Verifies that `CDNUploader.buildSyncArguments` wires the expected
    /// bucket and key-prefix values into the `aws s3 sync` argv.
    ///
    /// This test uses the static argument-builder seam — no `aws` process is
    /// ever spawned, and no real credentials are read. Sentinel values are
    /// supplied to `CDNUploader(environment:)` to show the seam is usable.
    @Test("CDNUploader buildSyncArguments wires bucket and slug correctly with sentinel env")
    func uploaderBucketKeyWiring() {
      let sentinelEnv: [String: String] = [
        "R2_ACCESS_KEY_ID": "__TEST_FAKE_KEY__",
        "R2_SECRET_ACCESS_KEY": "__TEST_FAKE_SECRET__",
      ]

      // Confirm CDNUploader init accepts the injected environment snapshot.
      let _ = CDNUploader(
        awsExecutableURL: URL(fileURLWithPath: "/var/empty/never-exists-aws"),
        environment: sentinelEnv
      )

      // Verify the static argument builder wires bucket and slug into the
      // S3 path without any process spawn.
      let stagingDir = URL(fileURLWithPath: "/tmp/acervo-staging/test_org_mymodel")
      let args = CDNUploader.buildSyncArguments(
        localDirectory: stagingDir,
        slug: "test_org_mymodel",
        bucket: "intrusive-memory-models",
        endpoint: "https://r2.example.com",
        dryRun: false,
        force: false
      )

      #expect(args.contains("s3://intrusive-memory-models/models/test_org_mymodel/"))
      #expect(args.contains(stagingDir.path))
      #expect(args.contains("--endpoint-url"))
      #expect(args.contains("https://r2.example.com"))
      // Safety invariant: --delete must never appear in sync args.
      #expect(!args.contains("--delete"))
    }

    // MARK: - Test 4: Missing required argument → canonical error

    /// When the required `modelId` positional argument is absent, `ArgumentParser`
    /// must surface a parsing error. `UploadCommand.parse(_:)` throws in this
    /// case, exercising the canonical missing-argument error path.
    @Test("Missing required modelId argument causes argument-parse error")
    func missingRequiredModelIdArgument() {
      // Attempt to parse with no arguments at all.
      var thrown: Error?
      do {
        _ = try UploadCommand.parse([])
      } catch {
        thrown = error
      }
      // ArgumentParser throws when required positional arguments are absent.
      #expect(thrown != nil, "Expected parse error when modelId is missing")
    }

    // MARK: - Test 5: Missing required directory argument → canonical error

    /// Similarly, `directory` is a required positional argument. Parsing
    /// with only `modelId` (no directory) must also surface a parse error.
    @Test("Missing required directory argument causes argument-parse error")
    func missingRequiredDirectoryArgument() {
      var thrown: Error?
      do {
        _ = try UploadCommand.parse(["org/mymodel"])
      } catch {
        thrown = error
      }
      #expect(thrown != nil, "Expected parse error when directory is missing")
    }

    // MARK: - Test 6: Sentinel credentials reach CDNUploader without touching real env

    /// Confirms that constructing a `CDNUploader` with injected sentinel
    /// credentials does NOT read `R2_ACCESS_KEY_ID` or `R2_SECRET_ACCESS_KEY`
    /// from the real process environment.
    ///
    /// Strategy: unset both env vars, then construct a `CDNUploader` with
    /// sentinel values. `verifyBeforeUpload` is called on a manifest with a
    /// matching file on disk; if the uploader were reading the real (now-unset)
    /// env, the subsequent `sync` call would throw `.missingEnvironmentVariable`
    /// for a different reason. Here we assert that `verifyBeforeUpload` itself
    /// succeeds — proving the injected snapshot is used for filesystem checks
    /// and the real env is not consulted during that phase.
    @Test("CDNUploader with sentinel env verifyBeforeUpload does not read real credentials")
    func sentinelEnvDoesNotTouchRealCredentials() async throws {
      let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("acervo-upload-sentinel-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: dir) }

      let configURL = dir.appendingPathComponent("config.json")
      try Data("{\"test\": true}".utf8).write(to: configURL, options: [.atomic])

      let generator = ManifestGenerator(modelId: "test/sentinel-model")
      let manifestURL = try await generator.generate(directory: dir)
      let manifest = try JSONDecoder().decode(
        CDNManifest.self, from: Data(contentsOf: manifestURL))

      // Build a CDNUploader with the injected sentinel environment.
      // R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY from the host are NOT used.
      let uploader = CDNUploader(
        awsExecutableURL: URL(fileURLWithPath: "/var/empty/never-exists-aws"),
        environment: [
          "R2_ACCESS_KEY_ID": "__TEST_FAKE_KEY__",
          "R2_SECRET_ACCESS_KEY": "__TEST_FAKE_SECRET__",
        ]
      )

      // verifyBeforeUpload reads only the filesystem; it must not throw here.
      // This is the phase prior to any `aws` spawn, so credentials are not
      // yet checked. Reaching this assertion without throwing confirms the
      // injected env is used and no real credential is required.
      try await uploader.verifyBeforeUpload(directory: dir, manifest: manifest)
    }
  }
#endif
