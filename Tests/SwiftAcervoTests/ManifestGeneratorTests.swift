import Foundation
import Testing

@testable import SwiftAcervo

/// Unit tests for `ManifestGenerator` covering the happy path plus the
/// CHECK 2 (zero-byte file) and CHECK 3 (post-write verify) guards.
///
/// Cross-platform: `ManifestGenerator` was lifted from `Sources/acervo/`
/// into the `SwiftAcervo` library by WU2 Sortie 2, so these tests run on
/// every platform the library supports (currently macOS + iOS).
@Suite("ManifestGenerator Tests")
struct ManifestGeneratorTests {

  /// Creates a unique temp directory under `NSTemporaryDirectory()` that
  /// callers are responsible for cleaning up.
  private func makeTempDir() throws -> URL {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("acervo-manifest-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private func write(_ string: String, to url: URL) throws {
    try Data(string.utf8).write(to: url, options: [.atomic])
  }

  @Test("Generate produces manifest with correct entries and passes verifyChecksum")
  func generateHappyPath() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let fileA = dir.appendingPathComponent("config.json")
    let fileB = dir.appendingPathComponent("tokenizer.json")
    try write("{\"alpha\": 1}", to: fileA)
    try write("{\"vocab\": [\"a\", \"b\"]}", to: fileB)

    let expectedA = try IntegrityVerification.sha256(of: fileA)
    let expectedB = try IntegrityVerification.sha256(of: fileB)

    let generator = ManifestGenerator(modelId: "org/repo")
    let manifestURL = try await generator.generate(directory: dir)

    #expect(FileManager.default.fileExists(atPath: manifestURL.path))

    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

    #expect(manifest.modelId == "org/repo")
    #expect(manifest.slug == "org_repo")
    #expect(manifest.files.count == 2)

    let entryA = manifest.file(at: "config.json")
    let entryB = manifest.file(at: "tokenizer.json")
    #expect(entryA?.sha256 == expectedA)
    #expect(entryB?.sha256 == expectedB)
    #expect(entryA?.sizeBytes == Int64("{\"alpha\": 1}".utf8.count))
    #expect(entryB?.sizeBytes == Int64("{\"vocab\": [\"a\", \"b\"]}".utf8.count))

    #expect(manifest.verifyChecksum() == true)
  }

  @Test("CHECK 2: zero-byte file in dir throws zeroByteFile and does not write manifest")
  func zeroByteFileTriggersCheck2() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let good = dir.appendingPathComponent("config.json")
    try write("{\"x\": 1}", to: good)

    let empty = dir.appendingPathComponent("empty.bin")
    // Create a zero-byte file directly.
    #expect(FileManager.default.createFile(atPath: empty.path, contents: nil, attributes: nil))

    let manifestURL = dir.appendingPathComponent("manifest.json")
    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

    let generator = ManifestGenerator(modelId: "org/repo")
    var thrown: Error?
    do {
      _ = try await generator.generate(directory: dir)
    } catch {
      thrown = error
    }

    guard case .some(AcervoError.manifestZeroByteFile(let path)) = thrown else {
      Issue.record(
        "Expected AcervoError.manifestZeroByteFile, got \(String(describing: thrown))")
      return
    }
    #expect(path == "empty.bin")

    // CHECK 2 must bail BEFORE writing anything.
    #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
  }

  @Test("Nested subdirs with same basename produce distinct full relative paths")
  func nestedSubdirectoriesProduceDistinctPaths() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Create three files all named `config.json` with distinct
    // contents in three different directories: one at the staging
    // root, one in `text_encoder/`, one in `vae/`. This mirrors the
    // nested-layout HF repos (FLUX.2, etc.) that triggered the
    // basename-only manifest bug from TODO.md P0.
    let textEncoderDir = dir.appendingPathComponent("text_encoder", isDirectory: true)
    let vaeDir = dir.appendingPathComponent("vae", isDirectory: true)
    try FileManager.default.createDirectory(at: textEncoderDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vaeDir, withIntermediateDirectories: true)

    try write("{\"root\": true}", to: dir.appendingPathComponent("config.json"))
    try write("{\"te\": true}", to: textEncoderDir.appendingPathComponent("config.json"))
    try write("{\"vae\": true}", to: vaeDir.appendingPathComponent("config.json"))

    let generator = ManifestGenerator(modelId: "org/repo")
    let manifestURL = try await generator.generate(directory: dir)

    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)

    let paths = manifest.files.map(\.path).sorted()
    #expect(
      paths == ["config.json", "text_encoder/config.json", "vae/config.json"],
      "expected three distinct nested paths, got \(paths)"
    )

    // Distinct content means distinct SHA-256s. If the bug regressed,
    // all three would either collapse to one entry (overwriting each
    // other) or produce duplicate `config.json` paths with three
    // different hashes.
    let shas = Set(manifest.files.map(\.sha256))
    #expect(shas.count == 3, "expected three distinct SHA-256s, got \(shas.count)")

    #expect(manifest.verifyChecksum() == true)
  }

  @Test("relativePath helper throws when the file is outside the base")
  func relativePathHelperThrowsForOutsideBase() throws {
    let base = URL(fileURLWithPath: "/tmp/some-base/path", isDirectory: true)
    let outside = URL(fileURLWithPath: "/var/folders/totally/different/file.txt")

    var thrown: Error?
    do {
      _ = try ManifestGenerator.relativePath(of: outside, under: base)
    } catch {
      thrown = error
    }

    guard case .some(AcervoError.manifestRelativePathOutsideBase(let file, _)) = thrown
    else {
      Issue.record(
        "Expected AcervoError.manifestRelativePathOutsideBase, got \(String(describing: thrown))"
      )
      return
    }
    #expect(file == outside.path)
  }

  @Test("Generated manifest file is sorted and stable")
  func generatedManifestIsSorted() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    try write("a", to: dir.appendingPathComponent("zeta.txt"))
    try write("b", to: dir.appendingPathComponent("alpha.txt"))
    try write("c", to: dir.appendingPathComponent("mu.txt"))

    let generator = ManifestGenerator(modelId: "org/repo")
    _ = try await generator.generate(directory: dir)

    let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: data)
    #expect(manifest.files.map(\.path) == ["alpha.txt", "mu.txt", "zeta.txt"])
    #expect(manifest.verifyChecksum() == true)
  }
}
