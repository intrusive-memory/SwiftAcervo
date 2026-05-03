#if os(macOS)
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  /// Legacy CHECK 4 coverage for `CDNUploader.verifyBeforeUpload`. The
  /// CHECK 2 / CHECK 3 cases this file used to host were lifted into
  /// `Tests/SwiftAcervoTests/ManifestIntegrityTests.swift` so iOS gets
  /// coverage of the library invariants.
  ///
  /// TODO(WU3.S1): Delete this file when WU3 Sortie 1 removes the legacy
  /// `CDNUploader` and the `aws` shell-out path. CHECK 4 of the new
  /// orchestrator (`Acervo.publishModel`) is exercised end-to-end on every
  /// supported platform by `Tests/SwiftAcervoTests/PublishModelTests.swift`,
  /// so removing this macOS-only suite leaves no coverage gap once the
  /// legacy uploader is gone.
  @Suite("Integrity Step Tests")
  struct IntegrityStepTests {

    private func makeTempDir() throws -> URL {
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("acervo-integrity-tests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      return base
    }

    private func write(_ string: String, to url: URL) throws {
      try Data(string.utf8).write(to: url, options: [.atomic])
    }

    @Test("CHECK 4: staging mutation throws stagingMutation without spawning aws")
    func check4StagingMutationThrows() async throws {
      let dir = try makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }

      let configURL = dir.appendingPathComponent("config.json")
      let tokenizerURL = dir.appendingPathComponent("tokenizer.json")
      try write("original config", to: configURL)
      try write("original tokenizer", to: tokenizerURL)

      // Generate a valid manifest first.
      let generator = ManifestGenerator(modelId: "org/repo")
      let manifestURL = try await generator.generate(directory: dir)
      let manifest = try JSONDecoder().decode(
        CDNManifest.self,
        from: Data(contentsOf: manifestURL)
      )

      // Mutate one of the files on disk, post-manifest.
      try write("MUTATED tokenizer bytes", to: tokenizerURL)

      // Construct an uploader pointed at a nonsense aws path so that if
      // verifyBeforeUpload ever reached `runAWS`, the spawn would fail with
      // a completely different error. This gives us a strong signal that
      // CHECK 4 short-circuited correctly.
      let uploader = CDNUploader(
        awsExecutableURL: URL(fileURLWithPath: "/var/empty/never-exists-aws"),
        environment: [:]
      )

      var thrown: Error?
      do {
        try await uploader.verifyBeforeUpload(directory: dir, manifest: manifest)
      } catch {
        thrown = error
      }

      guard
        case .some(AcervoToolError.stagingMutation(let filename, _, _)) = thrown
      else {
        Issue.record(
          "Expected AcervoToolError.stagingMutation, got \(String(describing: thrown))"
        )
        return
      }
      #expect(filename == "tokenizer.json")
    }

    @Test("CHECK 4: clean staging passes verifyBeforeUpload without throwing")
    func check4CleanStagingPasses() async throws {
      let dir = try makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }

      try write("a", to: dir.appendingPathComponent("config.json"))
      try write("b", to: dir.appendingPathComponent("tokenizer.json"))

      let generator = ManifestGenerator(modelId: "org/repo")
      let manifestURL = try await generator.generate(directory: dir)
      let manifest = try JSONDecoder().decode(
        CDNManifest.self,
        from: Data(contentsOf: manifestURL)
      )

      let uploader = CDNUploader(
        awsExecutableURL: URL(fileURLWithPath: "/var/empty/never-exists-aws"),
        environment: [:]
      )
      // Must not throw: CHECK 4 passes for untouched staging.
      try await uploader.verifyBeforeUpload(directory: dir, manifest: manifest)
    }
  }
#endif
