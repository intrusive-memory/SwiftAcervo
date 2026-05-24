//
// ShipDryRunTests.swift — Sortie DC-1: acervo ship --slug / --spec / --dry-run / --output-dir
//
// Restores the QM01 S5 deliverable on top of the v0.15.0 PublishRunner
// architecture. The legacy CDNUploader has been deleted; these tests
// drive the dry-run path that bypasses PublishRunner entirely and assert
// the generated manifest carries the expected slug-registry triple.
//
// Cases covered (mirrors the parked QM01 S5 plan with v0.15.0 wiring):
//   (a) --slug <slug> --dry-run on a single-component model:
//       manifest.modelId == slug, manifest.primaryRepo == hfRepo,
//       manifest.components == [hfRepo].
//   (b) --spec <path> --dry-run: N manifests, every one carries the
//       same modelId / primaryRepo / components triple.
//   (c) --dry-run succeeds without R2 credentials in the environment
//       (no CredentialResolver.resolve() call on the dry-run path).
//   (d) --slug and --spec parse to the expected properties; --spec
//       leaves the positional modelId as nil.
//   (e) PublishRunner.override never fires during --dry-run (no R2 PUTs).
//   (f) Generator nested-path emission: a staged tree with subdirectories
//       produces files[].path entries of depth >= 1 in the dry-run
//       manifest, with HuggingFace cruft excluded.
//
// No live network. No R2 credentials required. Fully deterministic.
//
// Test plan: SwiftAcervo-macOS.xctestplan (AcervoToolTests target).

#if os(macOS)
  import ArgumentParser
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  extension ProcessEnvironmentSuite {
    @Suite("ShipCommand Dry-Run Tests", .serialized)
    final class ShipDryRunTests {

      private let fm = FileManager.default

      // MARK: - Fixture helpers

      /// Creates a unique tempdir under NSTemporaryDirectory().
      private func makeTempDir(tag: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
          .appendingPathComponent(
            "acervo-shipdr-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
      }

      /// Writes `content` to `url`.
      private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: [.atomic])
      }

      /// Populates a staging directory under `stagingRoot/<slug>` with two
      /// non-empty fixture files (config.json and weights.safetensors).
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

      @Test(
        "--slug --dry-run: manifest.modelId == slug, primaryRepo == repo, components == [repo]"
      )
      func slugDryRun() async throws {
        let stagingRoot = try makeTempDir(tag: "slug-staging")
        let outputDir = try makeTempDir(tag: "slug-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "org/my-model"
        let explicitSlug = "my-model-slug"

        _ = try makeComponentStagingDir(in: stagingRoot, modelId: hfRepo)

        let parsed = try AcervoCLI.parseAsRoot([
          "ship", hfRepo,
          "--slug", explicitSlug,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }

        try await cmd.run()

        let outputFiles = try fm.contentsOfDirectory(
          at: outputDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(
          outputFiles.count == 1,
          "Expected exactly one manifest file; got \(outputFiles.map(\.lastPathComponent))"
        )

        guard let manifestURL = outputFiles.first else { return }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

        #expect(manifest.modelId == explicitSlug)
        #expect(manifest.primaryRepo == hfRepo)
        #expect(manifest.components == [hfRepo])
        #expect(manifest.verifyChecksum())
        #expect(manifest.files.count == 2)
      }

      // MARK: - Test (b): --spec --dry-run (multi-component)

      @Test(
        "--spec --dry-run: N manifests all share the same modelId, primaryRepo, components"
      )
      func specDryRun() async throws {
        let stagingRoot = try makeTempDir(tag: "spec-staging")
        let outputDir = try makeTempDir(tag: "spec-out")
        let specDir = try makeTempDir(tag: "spec-def")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
          try? fm.removeItem(at: specDir)
        }

        let specModelId = "flux2-klein-4b"
        let specPrimaryRepo = "black-forest-labs/FLUX.2-klein-4B"
        // Use three distinct fake HF repos so we can verify N manifests
        // land in --output-dir with the shared triple.
        let specComponents = [
          "black-forest-labs/FLUX.2-klein-4B",
          "black-forest-labs/FLUX.2-aux-1",
          "black-forest-labs/FLUX.2-aux-2",
        ]

        let componentsJSON = "[" + specComponents.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let specPayload = """
          {
            "modelId": "\(specModelId)",
            "primaryRepo": "\(specPrimaryRepo)",
            "components": \(componentsJSON)
          }
          """
        let specURL = specDir.appendingPathComponent("flux2-spec.json")
        try write(specPayload, to: specURL)

        for componentRepo in specComponents {
          _ = try makeComponentStagingDir(in: stagingRoot, modelId: componentRepo)
        }

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

        let outputFiles = try fm.contentsOfDirectory(
          at: outputDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        #expect(
          outputFiles.count == specComponents.count,
          "Expected \(specComponents.count) manifests; got \(outputFiles.map(\.lastPathComponent))"
        )

        for manifestURL in outputFiles {
          let data = try Data(contentsOf: manifestURL)
          let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

          #expect(manifest.modelId == specModelId)
          #expect(manifest.primaryRepo == specPrimaryRepo)
          #expect(manifest.components == specComponents)
          #expect(manifest.verifyChecksum())
          #expect(manifest.files.count == 2)
        }
      }

      // MARK: - Test (c): --dry-run requires no R2 credentials

      @Test("--dry-run succeeds without R2 credentials in the environment")
      func dryRunRequiresNoR2Credentials() async throws {
        let stagingRoot = try makeTempDir(tag: "nocred-staging")
        let outputDir = try makeTempDir(tag: "nocred-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "test-org/test-model"
        _ = try makeComponentStagingDir(in: stagingRoot, modelId: hfRepo)

        // Wipe every R2_* var. The dry-run path must NOT call
        // CredentialResolver.resolve(), so unset state must not throw.
        let savedKey = ProcessInfo.processInfo.environment["R2_ACCESS_KEY_ID"]
        let savedSecret = ProcessInfo.processInfo.environment["R2_SECRET_ACCESS_KEY"]
        let savedBucket = ProcessInfo.processInfo.environment["R2_BUCKET"]
        let savedEndpoint = ProcessInfo.processInfo.environment["R2_ENDPOINT"]
        let savedPublicURL = ProcessInfo.processInfo.environment["R2_PUBLIC_URL"]
        unsetenv("R2_ACCESS_KEY_ID")
        unsetenv("R2_SECRET_ACCESS_KEY")
        unsetenv("R2_BUCKET")
        unsetenv("R2_ENDPOINT")
        unsetenv("R2_PUBLIC_URL")
        defer {
          if let v = savedKey { setenv("R2_ACCESS_KEY_ID", v, 1) }
          if let v = savedSecret { setenv("R2_SECRET_ACCESS_KEY", v, 1) }
          if let v = savedBucket { setenv("R2_BUCKET", v, 1) }
          if let v = savedEndpoint { setenv("R2_ENDPOINT", v, 1) }
          if let v = savedPublicURL { setenv("R2_PUBLIC_URL", v, 1) }
        }

        let parsed = try AcervoCLI.parseAsRoot([
          "ship", hfRepo,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand, got \(type(of: parsed))")
          return
        }

        var thrown: Error?
        do {
          try await cmd.run()
        } catch {
          thrown = error
        }
        #expect(
          thrown == nil,
          "Dry-run must not throw even when R2 credentials are absent; got \(String(describing: thrown))"
        )

        let outputFiles = try fm.contentsOfDirectory(
          at: outputDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(outputFiles.count == 1)
      }

      // MARK: - Test (d): flag parsing

      @Test("--slug and --spec flags parse to the expected properties")
      func flagParsing() throws {
        let parsedSlug = try AcervoCLI.parseAsRoot([
          "ship", "org/repo",
          "--slug", "my-slug",
          "--dry-run",
        ])
        guard let cmdSlug = parsedSlug as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        #expect(cmdSlug.slug == "my-slug")
        #expect(cmdSlug.dryRun == true)
        #expect(cmdSlug.modelId == "org/repo")

        let parsedSpec = try AcervoCLI.parseAsRoot([
          "ship",
          "--spec", "/tmp/spec.json",
          "--dry-run",
          "--output-dir", "/tmp/manifests",
        ])
        guard let cmdSpec = parsedSpec as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        #expect(cmdSpec.spec == "/tmp/spec.json")
        #expect(cmdSpec.dryRun == true)
        #expect(cmdSpec.outputDir == "/tmp/manifests")
        #expect(cmdSpec.modelId == nil)
      }

      // MARK: - Test (e): dry-run never invokes PublishRunner

      @Test("--dry-run never invokes PublishRunner (zero R2 PUTs)")
      func dryRunSkipsPublishRunner() async throws {
        let stagingRoot = try makeTempDir(tag: "nopub-staging")
        let outputDir = try makeTempDir(tag: "nopub-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "org/my-model"
        _ = try makeComponentStagingDir(in: stagingRoot, modelId: hfRepo)

        // Trap PublishRunner — dry-run must never fire it.
        let called = ShipDryRunCallBox()
        PublishRunner.reset()
        PublishRunner.override = { _, _, _, _, _, _, _, _ in
          called.mark()
          throw DryRunSentinelError.publishShouldNotFire
        }
        defer { PublishRunner.reset() }

        let parsed = try AcervoCLI.parseAsRoot([
          "ship", hfRepo,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }

        try await cmd.run()

        #expect(
          called.fired == false,
          "PublishRunner.run must not fire on --dry-run"
        )
      }

      // MARK: - Test (f): generator emits nested-path entries

      /// A staged repo with subdirectories should produce manifest entries
      /// of depth >= 1 in the dry-run output, with HuggingFace cruft
      /// (`.cache/`, `.gitattributes`, `.gitignore`, `*.lock`, `*.metadata`)
      /// excluded. This is DC-1's dovetail with REQUIREMENTS §2's
      /// nested-path clause for diffusers-style repos (FLUX.2 etc).
      @Test(
        "Generator emits files[].path entries of depth >= 1 when the staged repo has subdirectories"
      )
      func nestedPathEmission() async throws {
        let stagingRoot = try makeTempDir(tag: "nested-staging")
        let outputDir = try makeTempDir(tag: "nested-out")
        defer {
          try? fm.removeItem(at: stagingRoot)
          try? fm.removeItem(at: outputDir)
        }

        let hfRepo = "org/flux2-like"
        let slug = hfRepo.replacingOccurrences(of: "/", with: "_")
        let stagingURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)
        try fm.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        // Top-level files.
        try write(
          "{\"model_index\": true}", to: stagingURL.appendingPathComponent("model_index.json"))
        try write("not a real readme", to: stagingURL.appendingPathComponent("README.md"))

        // Nested subdirectories (transformer/, vae/, text_encoder/).
        let transformerDir = stagingURL.appendingPathComponent("transformer", isDirectory: true)
        let vaeDir = stagingURL.appendingPathComponent("vae", isDirectory: true)
        let teDir = stagingURL.appendingPathComponent("text_encoder", isDirectory: true)
        try fm.createDirectory(at: transformerDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: vaeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: teDir, withIntermediateDirectories: true)

        try write("{\"t\": 1}", to: transformerDir.appendingPathComponent("config.json"))
        try write(
          "FAKE_TRANSFORMER_WEIGHTS",
          to: transformerDir.appendingPathComponent("diffusion_pytorch_model.safetensors")
        )
        try write("{\"v\": 1}", to: vaeDir.appendingPathComponent("config.json"))
        try write("FAKE_VAE_WEIGHTS", to: vaeDir.appendingPathComponent("model.safetensors"))
        try write("{\"te\": 1}", to: teDir.appendingPathComponent("config.json"))
        try write(
          "FAKE_TE_SHARD_1",
          to: teDir.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        // HuggingFace cruft that MUST be excluded.
        try write("attrs", to: stagingURL.appendingPathComponent(".gitattributes"))
        try write("ignored", to: stagingURL.appendingPathComponent(".gitignore"))
        try write("lock data", to: stagingURL.appendingPathComponent("upload.lock"))
        try write("meta data", to: stagingURL.appendingPathComponent("download.metadata"))
        // .DS_Store at the root and a lock inside a subdir.
        try write("ds", to: stagingURL.appendingPathComponent(".DS_Store"))
        try write("nested lock", to: vaeDir.appendingPathComponent("upload.lock"))

        let parsed = try AcervoCLI.parseAsRoot([
          "ship", hfRepo,
          "--dry-run",
          "--output-dir", outputDir.path,
          "--output", stagingRoot.path,
        ])
        guard var cmd = parsed as? ShipCommand else {
          Issue.record("Expected ShipCommand")
          return
        }
        try await cmd.run()

        let outputFiles = try fm.contentsOfDirectory(
          at: outputDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        #expect(outputFiles.count == 1)
        guard let manifestURL = outputFiles.first else { return }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

        let paths = Set(manifest.files.map(\.path))

        // Top-level files present.
        #expect(paths.contains("model_index.json"))
        #expect(paths.contains("README.md"))

        // Nested files present with full relative paths (depth >= 1).
        #expect(paths.contains("transformer/config.json"))
        #expect(paths.contains("transformer/diffusion_pytorch_model.safetensors"))
        #expect(paths.contains("vae/config.json"))
        #expect(paths.contains("vae/model.safetensors"))
        #expect(paths.contains("text_encoder/config.json"))
        #expect(paths.contains("text_encoder/model-00001-of-00002.safetensors"))

        // Depth >= 1 assertion: at least one emitted path contains a slash.
        let nestedPaths = paths.filter { $0.contains("/") }
        #expect(
          nestedPaths.count >= 1,
          "Expected at least one nested-path entry (depth >= 1); got paths: \(paths.sorted())"
        )

        // HuggingFace cruft excluded.
        #expect(!paths.contains(".gitattributes"))
        #expect(!paths.contains(".gitignore"))
        #expect(!paths.contains("upload.lock"))
        #expect(!paths.contains("download.metadata"))
        #expect(!paths.contains(".DS_Store"))
        #expect(!paths.contains("vae/upload.lock"))

        #expect(manifest.verifyChecksum())
      }
    }
  }

  // MARK: - Test support

  /// Mutable flag used by the dry-run-skips-PublishRunner test.
  final class ShipDryRunCallBox: @unchecked Sendable {
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

  enum DryRunSentinelError: Error { case publishShouldNotFire }
#endif
