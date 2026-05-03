#if os(macOS)
  // DeleteCommandTests
  //
  // Coverage for the `acervo delete` subcommand. Focuses on argument
  // parsing, scope-flag validation, and the env-var resolution that
  // happens before any CDN traffic. The actual S3 mutation surface is
  // covered by SwiftAcervoTests/DeleteFromCDNTests.swift.

  import ArgumentParser
  import Foundation
  import Testing

  @testable import acervo

  extension ProcessEnvironmentSuite {

    @Suite("DeleteCommand Tests")
    final class DeleteCommandTests {

      // MARK: - Argument parsing

      @Test("Missing scope flags fails validation at parse")
      func missingScopeFlags() throws {
        // No --local / --staging / --cache / --cdn — parseAsRoot runs the
        // command's validate() and surfaces the failure as CommandError.
        do {
          _ = try AcervoCLI.parseAsRoot(["delete", "org/repo"])
          Issue.record("parseAsRoot should have thrown")
        } catch {
          // expected — any error here counts; ArgumentParser wraps the
          // ValidationError in a CommandError.
        }
      }

      @Test("--local + --dry-run + modelId parse and validate")
      func localScopeParses() throws {
        let parsed = try AcervoCLI.parseAsRoot([
          "delete", "org/repo", "--local", "--dry-run",
        ])
        guard let cmd = parsed as? DeleteCommand else {
          Issue.record("expected DeleteCommand")
          return
        }
        #expect(cmd.modelId == "org/repo")
        #expect(cmd.local == true)
        #expect(cmd.staging == false)
        #expect(cmd.cache == false)
        #expect(cmd.cdn == false)
        #expect(cmd.dryRun == true)
        #expect(cmd.yes == false)
        try cmd.validate()
      }

      @Test("--staging --cache --cdn --yes coexist")
      func multiScopeParses() throws {
        let parsed = try AcervoCLI.parseAsRoot([
          "delete", "org/repo",
          "--staging", "--cache", "--cdn", "--yes",
        ])
        guard let cmd = parsed as? DeleteCommand else {
          Issue.record("expected DeleteCommand")
          return
        }
        #expect(cmd.staging == true)
        #expect(cmd.cache == true)
        #expect(cmd.cdn == true)
        #expect(cmd.yes == true)
        try cmd.validate()
      }

      // MARK: - --staging behavior

      @Test("--staging --dry-run does not delete the staging directory")
      func dryRunStagingPreservesDirectory() async throws {
        let fm = FileManager.default
        // Use an isolated STAGING_DIR override.
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent(
          "delete-cmd-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        // Create the per-model staging directory.
        let modelDir = stagingRoot.appendingPathComponent("org_repo")
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let marker = modelDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: marker)

        let savedStagingDir = ProcessInfo.processInfo.environment["STAGING_DIR"]
        setenv("STAGING_DIR", stagingRoot.path, 1)
        defer {
          if let savedStagingDir {
            setenv("STAGING_DIR", savedStagingDir, 1)
          } else {
            unsetenv("STAGING_DIR")
          }
        }

        let parsed = try AcervoCLI.parseAsRoot([
          "delete", "org/repo", "--staging", "--dry-run",
        ])
        guard let cmd = parsed as? DeleteCommand else {
          Issue.record("expected DeleteCommand")
          return
        }
        try cmd.validate()
        try await cmd.run()

        // Marker file must still exist.
        #expect(fm.fileExists(atPath: marker.path))
      }

      @Test("--staging actually removes the directory")
      func stagingDeletesDirectory() async throws {
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent(
          "delete-cmd-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let modelDir = stagingRoot.appendingPathComponent("org_repo")
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let marker = modelDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: marker)

        let savedStagingDir = ProcessInfo.processInfo.environment["STAGING_DIR"]
        setenv("STAGING_DIR", stagingRoot.path, 1)
        defer {
          if let savedStagingDir {
            setenv("STAGING_DIR", savedStagingDir, 1)
          } else {
            unsetenv("STAGING_DIR")
          }
        }

        let parsed = try AcervoCLI.parseAsRoot([
          "delete", "org/repo", "--staging",
        ])
        guard let cmd = parsed as? DeleteCommand else {
          Issue.record("expected DeleteCommand")
          return
        }
        try cmd.validate()
        try await cmd.run()

        #expect(!fm.fileExists(atPath: modelDir.path))
      }

      // MARK: - --cdn env resolution

      @Test("--cdn without R2 env vars throws missingEnvironmentVariable")
      func cdnNoEnvVars() async throws {
        // Snapshot and clear all R2 env vars.
        let names = [
          "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY",
          "R2_ENDPOINT", "R2_PUBLIC_URL", "R2_BUCKET",
        ]
        let saved: [(String, String?)] = names.map { name in
          (name, ProcessInfo.processInfo.environment[name])
        }
        for (name, _) in saved { unsetenv(name) }
        defer {
          for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
          }
        }

        let parsed = try AcervoCLI.parseAsRoot([
          "delete", "org/repo", "--cdn", "--yes",
        ])
        guard let cmd = parsed as? DeleteCommand else {
          Issue.record("expected DeleteCommand")
          return
        }
        try cmd.validate()
        await #expect(throws: AcervoToolError.self) {
          try await cmd.run()
        }
      }
    }
  }
#endif
