//
// ShipDryRunTests.swift — Sortie 5: acervo ship --dry-run CLI tests
//
// Tests cover:
//   (a) --slug <slug> --dry-run on a single-repo model:
//       manifest has modelId == slug, primaryRepo == repo, components == [repo]
//   (b) --spec <path> --dry-run:
//       N manifests, all sharing the same modelId, primaryRepo, and components array
//
// No live network, no R2 credentials required. All assertions are pure
// functions of fixture files + CLI flags — fully deterministic.
//
// Test plan: SwiftAcervo-macOS.xctestplan (AcervoToolTests target, already registered).

#if os(macOS)
  import ArgumentParser
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  // MARK: - ShipDryRunTests

  extension ProcessEnvironmentSuite {
    @Suite("ShipCommand Dry-Run Tests", .serialized)
    final class ShipDryRunTests {

      private let fm = FileManager.default

      // MARK: - Fixture helpers

      /// Creates a unique tempdir under NSTemporaryDirectory().
      private func makeTempDir(tag: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
          .appendingPathComponent("acervo-shipdr-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
      }

      /// Writes `content` to `url`.
      private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: [.atomic])
      }

      /// Populates a staging directory for a single component repo with
      /// two non-empty fixture files and returns the staging URL.
      ///
      /// The staging dir follows the `<stagingRoot>/<org>_<repo>` convention
      /// that ShipCommand uses (slug = modelId.replacingOccurrences(of: "/", with: "_")).
      private func makeComponentStagingDir(
        in stagingRoot: URL,
        modelId: String
      ) throws -> URL {
        let slug = modelId.replacingOccurrences(of: "/", with: "_")
        let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try write(#"{"model_type":"test"}"#, to: stagingURL.appendingPathComponent("config.json"))
        try write("FAKE_WEIGHTS", to: stagingURL.appendingPathComponent("weights.safetensors"))
        return stagingURL
      }

      // MARK: - Test (a): --slug --dry-run (single-component)

      /// Verify that `--slug <slug> --dry-run` on a single-component model:
      ///   - Generates exactly one manifest.
      ///   - The manifest carries `modelId == slug`.
      ///   - The manifest carries `primaryRepo == <HF repo>`.
      ///   - The manifest carries `components == [<HF repo>]`.
      ///   - No R2 credentials required; no HF download occurs.
      @Test("--slug <slug> --dry-run: manifest modelId == slug, primaryRepo == repo, components == [repo]")
      func slugDryRun() async throws {
        let stagingRoot = try makeTempDir(tag: "slug-staging")
        let outputDir = try makeTempDir(tag: "slug-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "org/my-model"
        let explicitSlug = "my-model-slug"

        // Stage fixture files for the component.
        _ = try makeComponentStagingDir(in: stagingRoot, modelId: hfRepo)

        // Parse the command with --slug, --dry-run, --output-dir, and --output
        // (staging root override). No R2 or HF credentials needed.
        let parsed = try AcervoCLI.parseAsRoot([
          "ship",
          hfRepo,
          "--slug", explicitSlug,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }

        // Execute the command (dry-run: no network, no aws).
        try await cmd.run()

        // Locate the written manifest.
        let outputFiles = try fm.contentsOfDirectory(
          at: outputDir,
          includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(
          outputFiles.count == 1,
          "Expected exactly one manifest file; got \(outputFiles.map(\.lastPathComponent))"
        )

        guard let manifestURL = outputFiles.first else { return }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

        // --- Core assertions ---
        #expect(
          manifest.modelId == explicitSlug,
          "Expected modelId == '\(explicitSlug)', got '\(manifest.modelId)'"
        )
        #expect(
          manifest.primaryRepo == hfRepo,
          "Expected primaryRepo == '\(hfRepo)', got '\(manifest.primaryRepo)'"
        )
        #expect(
          manifest.components == [hfRepo],
          "Expected components == ['\(hfRepo)'], got \(manifest.components)"
        )
        // Sanity: manifest is self-consistent.
        #expect(manifest.verifyChecksum(), "Manifest checksum must be valid")
        // Files were staged so manifest must not be empty.
        #expect(manifest.files.count > 0, "Manifest must contain staged files")
      }

      // MARK: - Test (b): --spec --dry-run (multi-component)

      /// Verify that `--spec <path> --dry-run` on a multi-component spec:
      ///   - Generates exactly N manifests (one per component).
      ///   - Every manifest carries `modelId == spec.modelId`.
      ///   - Every manifest carries `primaryRepo == spec.primaryRepo`.
      ///   - Every manifest carries `components == spec.components` (the full array).
      ///   - No R2 credentials required; no HF download occurs.
      @Test("--spec --dry-run: N manifests all share the same modelId, primaryRepo, components")
      func specDryRun() async throws {
        let stagingRoot = try makeTempDir(tag: "spec-staging")
        let outputDir = try makeTempDir(tag: "spec-out")
        let specDir = try makeTempDir(tag: "spec-def")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
          try? fm.removeItem(at: specDir)
        }

        // Three-component spec (mirrors the Flux2 Klein 4B shape from the plan).
        let specModelId = "flux2-klein-4b"
        let specPrimaryRepo = "black-forest-labs/FLUX.2-klein-4B"
        let specComponents = [
          "black-forest-labs/FLUX.2-klein-4B",
          "black-forest-labs/FLUX.2-vae",
          "google/t5-v1_1-xxl",
        ]

        // Write the spec JSON file.
        let specPayload = """
          {
            "modelId": "\(specModelId)",
            "primaryRepo": "\(specPrimaryRepo)",
            "components": \(specComponents.map { "\"\($0)\"" }.joined(separator: ", ", prefix: "[", suffix: "]"))
          }
          """
        let specURL = specDir.appendingPathComponent("flux2-spec.json")
        try write(specPayload, to: specURL)

        // Stage fixture files for each component.
        for componentRepo in specComponents {
          _ = try makeComponentStagingDir(in: stagingRoot, modelId: componentRepo)
        }

        // Parse and run the command.
        let parsed = try AcervoCLI.parseAsRoot([
          "ship",
          "--spec", specURL.path,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }

        try await cmd.run()

        // Collect all written manifests.
        let outputFiles = try fm.contentsOfDirectory(
          at: outputDir,
          includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(
          outputFiles.count == specComponents.count,
          "Expected \(specComponents.count) manifests; got \(outputFiles.map(\.lastPathComponent))"
        )

        // Verify every manifest carries the shared triple.
        for manifestURL in outputFiles {
          let data = try Data(contentsOf: manifestURL)
          let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

          #expect(
            manifest.modelId == specModelId,
            "\(manifestURL.lastPathComponent): expected modelId == '\(specModelId)', got '\(manifest.modelId)'"
          )
          #expect(
            manifest.primaryRepo == specPrimaryRepo,
            "\(manifestURL.lastPathComponent): expected primaryRepo == '\(specPrimaryRepo)', got '\(manifest.primaryRepo)'"
          )
          #expect(
            manifest.components == specComponents,
            "\(manifestURL.lastPathComponent): expected components \(specComponents), got \(manifest.components)"
          )
          #expect(manifest.verifyChecksum(), "\(manifestURL.lastPathComponent): manifest checksum must be valid")
          #expect(manifest.files.count > 0, "\(manifestURL.lastPathComponent): must contain staged files")
        }
      }

      // MARK: - Test (c): --dry-run does not need R2 credentials

      /// Verify that `--dry-run` never calls `resolveBucket()` or `resolveEndpoint()`,
      /// so the command succeeds even when R2_BUCKET and R2_ENDPOINT are unset.
      @Test("--dry-run succeeds without R2 credentials")
      func dryRunRequiresNoR2Credentials() async throws {
        let stagingRoot = try makeTempDir(tag: "nocred-staging")
        let outputDir = try makeTempDir(tag: "nocred-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "test-org/test-model"
        _ = try makeComponentStagingDir(in: stagingRoot, modelId: hfRepo)

        // Remove R2 credentials from environment.
        let savedBucket = ProcessInfo.processInfo.environment["R2_BUCKET"]
        let savedEndpoint = ProcessInfo.processInfo.environment["R2_ENDPOINT"]
        unsetenv("R2_BUCKET")
        unsetenv("R2_ENDPOINT")
        defer {
          if let b = savedBucket { setenv("R2_BUCKET", b, 1) } else { unsetenv("R2_BUCKET") }
          if let e = savedEndpoint { setenv("R2_ENDPOINT", e, 1) } else { unsetenv("R2_ENDPOINT") }
        }

        let parsed = try AcervoCLI.parseAsRoot([
          "ship",
          hfRepo,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }

        // Must not throw — no R2 interaction occurs in dry-run mode.
        var thrown: Error?
        do {
          try await cmd.run()
        } catch {
          thrown = error
        }
        #expect(thrown == nil, "Dry-run must not throw even when R2 credentials are absent; got \(String(describing: thrown))")

        let outputFiles = try fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
          .filter { $0.pathExtension == "json" }
        #expect(outputFiles.count == 1, "Expected one manifest in output dir")
      }

      // MARK: - Test (d): --slug and --spec parse correctly

      @Test("--slug and --spec flags parse to the expected properties")
      func flagParsing() throws {
        let parsedSlug = try AcervoCLI.parseAsRoot([
          "ship", "org/repo",
          "--slug", "my-slug",
          "--dry-run",
        ])
        guard let cmdSlug = parsedSlug as? ShipCommand else {
          Issue.record("Expected ShipCommand"); return
        }
        #expect(cmdSlug.slug == "my-slug")
        #expect(cmdSlug.dryRun == true)

        let parsedSpec = try AcervoCLI.parseAsRoot([
          "ship",
          "--spec", "/tmp/spec.json",
          "--dry-run",
        ])
        guard let cmdSpec = parsedSpec as? ShipCommand else {
          Issue.record("Expected ShipCommand"); return
        }
        #expect(cmdSpec.spec == "/tmp/spec.json")
        #expect(cmdSpec.dryRun == true)
        #expect(cmdSpec.modelId == nil)
      }
    }
  }

  // MARK: - String+joined convenience

  private extension Array where Element == String {
    func joined(separator: String, prefix: String, suffix: String) -> String {
      prefix + self.joined(separator: separator) + suffix
    }
  }
#endif
