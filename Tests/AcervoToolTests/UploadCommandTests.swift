#if os(macOS)
  // UploadCommandTests
  //
  // After the v0.14.x CLI consolidation `UploadCommand.run()` delegates
  // every CDN-side step to `Acervo.publishModel(...)` via the
  // `PublishRunner` seam. The CLI no longer spawns any `aws` subprocess,
  // so these tests focus on argument parsing, credential resolution,
  // call routing into `PublishRunner.override`, and the `--dry-run`
  // short-circuit (which must not invoke `PublishRunner`).

  import ArgumentParser
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  extension ProcessEnvironmentSuite {

    @Suite("UploadCommand Tests")
    final class UploadCommandTests {

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
          .appendingPathComponent("acervo-upload-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempBinDir, withIntermediateDirectories: true)

        savedPATH = ProcessInfo.processInfo.environment["PATH"]
        savedR2AccessKey = ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"]
        savedR2SecretKey = ProcessInfo.processInfo.environment["R2_SECRET_ACCESS_KEY"]
        savedR2Bucket = ProcessInfo.processInfo.environment["R2_BUCKET"]
        savedR2Endpoint = ProcessInfo.processInfo.environment["R2_ENDPOINT"]
        savedR2PublicURL = ProcessInfo.processInfo.environment["R2_PUBLIC_URL"]

        try installStub(named: "hf")
        setenv("PATH", tempBinDir.path, 1)

        unsetenv("R2_ACCESS_KEY_ID")
        unsetenv("R2_SECRET_ACCESS_KEY")
        unsetenv("R2_BUCKET")
        unsetenv("R2_ENDPOINT")
        unsetenv("R2_PUBLIC_URL")
      }

      deinit {
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

      private func setAllR2EnvVars() {
        setenv("R2_ACCESS_KEY_ID", "__TEST_FAKE_KEY__", 1)
        setenv("R2_SECRET_ACCESS_KEY", "__TEST_FAKE_SECRET__", 1)
        setenv("R2_BUCKET", "test-bucket-sentinel", 1)
        setenv("R2_ENDPOINT", "https://r2.example.com", 1)
        setenv("R2_PUBLIC_URL", "https://cdn.example.com", 1)
      }

      private func makeStagingDirectory(slug: String) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent(
          "upload-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let modelDir = root.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))
        return modelDir
      }

      // MARK: - Argument parsing

      @Test("Happy-path argv parsing captures all flags correctly")
      func happyPathArgvParsing() async throws {
        let cmd = try await UploadCommand.parse([
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
        #expect(cmd.keepOrphans == false)
      }

      @Test("Missing required modelId argument causes argument-parse error")
      func missingRequiredModelIdArgument() async throws {
        var thrown: Error?
        do {
          _ = try await UploadCommand.parse([])
        } catch {
          thrown = error
        }
        #expect(thrown != nil)
      }

      @Test("Missing required directory argument causes argument-parse error")
      func missingRequiredDirectoryArgument() async throws {
        var thrown: Error?
        do {
          _ = try await UploadCommand.parse(["org/mymodel"])
        } catch {
          thrown = error
        }
        #expect(thrown != nil)
      }

      // MARK: - Credential resolution

      @Test(
        "Error surfacing: missing R2_ACCESS_KEY_ID throws missingEnvironmentVariable before pipeline starts"
      )
      func missingAccessKeySurfacesError() async throws {
        let parsed = try await AcervoCLI.parseAsRoot(["upload", "org/repo", "/tmp/anywhere"])
        guard let cmd = parsed as? UploadCommand else {
          Issue.record("Expected UploadCommand")
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

      // MARK: - --keep-orphans propagation

      @Test("--keep-orphans parses to true")
      func keepOrphansFlagParses() async throws {
        let cmd = try await UploadCommand.parse([
          "org/repo", "/tmp/staging", "--keep-orphans",
        ])
        #expect(cmd.keepOrphans == true)
      }

      @Test("Default (no --keep-orphans) parses to false")
      func keepOrphansDefaultsFalse() async throws {
        let cmd = try await UploadCommand.parse(["org/repo", "/tmp/staging"])
        #expect(cmd.keepOrphans == false)
      }

      /// End-to-end seam test: with `--keep-orphans`, the value the CLI hands
      /// to `PublishRunner.run(...)` is `true`. Without the flag it is `false`.
      /// Asserts call routing without spawning any network traffic.
      @Test("--keep-orphans propagates to PublishRunner with keepOrphans: true")
      func keepOrphansPropagatesTrue() async throws {
        try await assertKeepOrphans(passingFlag: true, expected: true)
      }

      @Test("Omitting --keep-orphans propagates keepOrphans: false to PublishRunner")
      func keepOrphansPropagatesFalse() async throws {
        try await assertKeepOrphans(passingFlag: false, expected: false)
      }

      private func assertKeepOrphans(passingFlag: Bool, expected: Bool) async throws {
        setAllR2EnvVars()
        defer {
          unsetenv("R2_ACCESS_KEY_ID")
          unsetenv("R2_SECRET_ACCESS_KEY")
          unsetenv("R2_BUCKET")
          unsetenv("R2_ENDPOINT")
          unsetenv("R2_PUBLIC_URL")
        }

        let modelDir = try makeStagingDirectory(slug: "org_repo")
        defer { try? fm.removeItem(at: modelDir.deletingLastPathComponent()) }

        let capture = KeepOrphansCaptureBox()
        PublishRunner.reset()
        PublishRunner.override = { _, _, _, keepOrphans, _, _, _, _ in
          capture.set(keepOrphans)
          // Return a synthetic manifest so the command body completes cleanly.
          return CDNManifest(
            manifestVersion: 1,
            modelId: "org/repo",
            slug: "org_repo",
            updatedAt: "1970-01-01T00:00:00Z",
            files: [],
            manifestChecksum: ""
          )
        }
        defer { PublishRunner.reset() }

        var args = ["upload", "org/repo", modelDir.path]
        if passingFlag { args.append("--keep-orphans") }

        let parsed = try await AcervoCLI.parseAsRoot(args)
        guard let cmd = parsed as? UploadCommand else {
          Issue.record("Expected UploadCommand")
          return
        }
        try await cmd.run()

        #expect(capture.value == expected)
      }

      // MARK: - --dry-run short-circuit

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

        let modelDir = try makeStagingDirectory(slug: "org_repo")
        defer { try? fm.removeItem(at: modelDir.deletingLastPathComponent()) }

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

        let called = ShipPublishCallBox()
        PublishRunner.reset()
        PublishRunner.override = { _, _, _, _, _, _, _, _ in
          called.mark()
          throw TestSentinelError.publishShouldNotBeCalled
        }
        defer { PublishRunner.reset() }

        let parsed = try await AcervoCLI.parseAsRoot([
          "upload", "org/repo", modelDir.path, "--dry-run",
        ])
        guard let cmd = parsed as? UploadCommand else {
          Issue.record("Expected UploadCommand")
          return
        }
        try await cmd.run()

        #expect(
          called.fired == false,
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

  /// Thread-safe capture of the `keepOrphans` value the CLI hands to
  /// `PublishRunner.run(...)`.
  final class KeepOrphansCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?
    var value: Bool? {
      lock.lock()
      defer { lock.unlock() }
      return _value
    }
    func set(_ v: Bool) {
      lock.lock()
      defer { lock.unlock() }
      _value = v
    }
  }
#endif
