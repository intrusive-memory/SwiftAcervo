import Foundation
import Testing

@testable import SwiftAcervo

/// Cross-platform checks for the manifest integrity invariants that
/// `Acervo.publishModel` relies on. CHECK 4 (post-manifest staging
/// mutation detection) is exercised end-to-end via `PublishModelTests`,
/// which runs the full `Acervo.publishModel` orchestrator on every
/// supported platform.
///
/// Originally lived in `Tests/AcervoToolTests/IntegrityStepTests.swift`;
/// the CHECK 2 / CHECK 3 cases moved here so iOS gets coverage of the
/// same invariants. The legacy `CDNUploader.verifyBeforeUpload` CHECK 4
/// case stayed in `AcervoToolTests` because it depends on macOS-only
/// `CDNUploader`, which WU3 Sortie 1 will delete in favour of the
/// library-owned `Acervo.publishModel` path.
@Suite("Manifest Integrity Tests")
struct ManifestIntegrityTests {

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

    guard case .some(AcervoError.manifestZeroByteFile) = thrown else {
      Issue.record(
        "Expected AcervoError.manifestZeroByteFile, got \(String(describing: thrown))")
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
    let roundTrip = try JSONDecoder().decode(
      CDNManifest.self, from: Data(contentsOf: manifestURL))
    #expect(roundTrip.verifyChecksum() == false)
  }
}
