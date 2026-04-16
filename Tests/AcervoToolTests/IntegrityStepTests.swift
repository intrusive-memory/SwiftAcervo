#if os(macOS)
import Foundation
import Testing

@testable import SwiftAcervo
@testable import acervo

/// End-to-end-ish unit tests for CHECK 2, CHECK 3, and CHECK 4 that do
/// not require any network or external process to exercise the integrity
/// pipeline.
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

  // MARK: - CHECK 2

  @Test("CHECK 2: zero-byte file causes throw before manifest.json is written")
  func check2ZeroByteFileThrowsBeforeWrite() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    try write("some content", to: dir.appendingPathComponent("config.json"))
    // A second non-empty file so the scan has a mix.
    try write("tokenizer data", to: dir.appendingPathComponent("tokenizer.json"))
    // And the offender.
    #expect(
      FileManager.default.createFile(
        atPath: dir.appendingPathComponent("empty.bin").path,
        contents: nil,
        attributes: nil
      )
    )

    let manifestURL = dir.appendingPathComponent("manifest.json")
    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

    let generator = ManifestGenerator(modelId: "org/repo")
    var thrown: Error?
    do {
      _ = try await generator.generate(directory: dir)
    } catch {
      thrown = error
    }

    guard case .some(AcervoToolError.zeroByteFile) = thrown else {
      Issue.record("Expected AcervoToolError.zeroByteFile, got \(String(describing: thrown))")
      return
    }

    // The manifest MUST NOT exist after a CHECK 2 failure.
    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
  }

  // MARK: - CHECK 3

  @Test("CHECK 3: corrupting manifestChecksum causes verifyChecksum() to return false")
  func check3CorruptedManifestFailsVerifyChecksum() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    try write("{\"k\": 1}", to: dir.appendingPathComponent("config.json"))
    try write("abcdef", to: dir.appendingPathComponent("tokenizer.json"))

    let generator = ManifestGenerator(modelId: "org/repo")
    let manifestURL = try await generator.generate(directory: dir)

    // Decode, corrupt the manifestChecksum, re-encode, rewrite.
    let originalData = try Data(contentsOf: manifestURL)
    var json = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
    json["manifestChecksum"] = String(repeating: "0", count: 64)
    let corruptedData = try JSONSerialization.data(
      withJSONObject: json,
      options: [.sortedKeys, .prettyPrinted]
    )
    try corruptedData.write(to: manifestURL, options: [.atomic])

    // Re-read and call verifyChecksum() directly.
    let roundTrip = try JSONDecoder().decode(CDNManifest.self, from: Data(contentsOf: manifestURL))
    #expect(roundTrip.verifyChecksum() == false)
  }

  // MARK: - CHECK 4

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
