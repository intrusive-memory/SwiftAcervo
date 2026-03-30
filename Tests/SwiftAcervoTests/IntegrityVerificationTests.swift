import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for integrity verification (Sortie 7).
///
/// Uses unique component IDs per test instance to avoid interference
/// with other test suites that use `ComponentRegistry.shared`.
@Suite("Integrity Verification Tests")
struct IntegrityVerificationTests {

  /// Unique suffix per test instance for component ID isolation.
  private let uid = UUID().uuidString.prefix(8)

  // MARK: - SHA-256 Hash Computation

  @Test("SHA-256 of 'Hello, world!' matches known hash")
  func sha256KnownHash() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("hello.txt")
    try Data("Hello, world!".utf8).write(to: fileURL)

    let hash = try IntegrityVerification.sha256(of: fileURL)
    #expect(hash == "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3")
  }

  @Test("SHA-256 of modified content differs from original")
  func sha256DiffersForDifferentContent() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("modified.txt")
    try Data("Hello, world!!".utf8).write(to: fileURL)

    let hash = try IntegrityVerification.sha256(of: fileURL)
    #expect(hash != "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3")
  }

  // MARK: - 4 MB Chunk Size Validation

  /// Verifies SHA-256 output for a file of exactly 4 MB (the new chunk boundary).
  ///
  /// The file contains a deterministic pattern (bytes 0–255 repeating).
  /// The expected hash was computed independently with Python's `hashlib.sha256`.
  @Test("SHA-256 of exactly 4 MB file matches known hash")
  func sha256ExactlyFourMegabytes() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("4mb-exact.bin")
    let size = 4 * 1024 * 1024
    let data = Data(bytes: (0..<size).map { UInt8($0 % 256) }, count: size)
    try data.write(to: fileURL)

    let hash = try IntegrityVerification.sha256(of: fileURL)
    // Reference hash computed with Python hashlib.sha256 on the same pattern
    #expect(hash == "2b07811057df887086f06a67edc6ebf911de8b6741156e7a2eb1416a4b8b1b2e")
  }

  /// Verifies SHA-256 output for a file of 5 MB (spans more than one 4 MB chunk).
  ///
  /// The file contains a deterministic pattern (bytes 0–255 repeating).
  /// The expected hash was computed independently with Python's `hashlib.sha256`.
  @Test("SHA-256 of 5 MB file (spanning two 4 MB chunks) matches known hash")
  func sha256SpansTwoChunks() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("5mb.bin")
    let size = 5 * 1024 * 1024
    let data = Data(bytes: (0..<size).map { UInt8($0 % 256) }, count: size)
    try data.write(to: fileURL)

    let hash = try IntegrityVerification.sha256(of: fileURL)
    // Reference hash computed with Python hashlib.sha256 on the same pattern
    #expect(hash == "2e7cab6314e9614b6f2da12630661c3038e5592025f6534ba5823c3b340a1cb6")
  }

  @Test("SHA-256 returns lowercase hex string of 64 characters")
  func sha256Format() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("format.txt")
    try Data("test".utf8).write(to: fileURL)

    let hash = try IntegrityVerification.sha256(of: fileURL)
    #expect(hash.count == 64)
    let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
    #expect(hash.unicodeScalars.allSatisfy { hexChars.contains($0) })
  }

  // MARK: - File-Level Verification

  @Test("verify with nil checksum returns true (skips verification)")
  func verifyNilChecksumSkips() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    try Data("anything".utf8).write(to: tempDir.appendingPathComponent("file.txt"))

    let file = ComponentFile(relativePath: "file.txt", sha256: nil)
    let result = try IntegrityVerification.verify(file: file, in: tempDir)
    #expect(result == true)
  }

  @Test("verify with correct checksum returns true")
  func verifyCorrectChecksum() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("correct.txt")
    try Data("Hello, world!".utf8).write(to: fileURL)

    let file = ComponentFile(
      relativePath: "correct.txt",
      sha256: "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
    )
    let result = try IntegrityVerification.verify(file: file, in: tempDir)
    #expect(result == true)
  }

  @Test("verify with wrong checksum returns false")
  func verifyWrongChecksum() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let fileURL = tempDir.appendingPathComponent("wrong.txt")
    try Data("Hello, world!".utf8).write(to: fileURL)

    let file = ComponentFile(
      relativePath: "wrong.txt",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"
    )
    let result = try IntegrityVerification.verify(file: file, in: tempDir)
    #expect(result == false)
  }

  // MARK: - Acervo.verifyComponent

  @Test("verifyComponent on a valid component with correct files returns true")
  func verifyComponentValid() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let id = "iv-valid-\(uid)"
    let repoSlug = "org/iv-valid-\(uid)"
    let content = Data("Hello, world!".utf8)

    let componentDir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    try content.write(to: componentDir.appendingPathComponent("model.safetensors"))

    let descriptor = ComponentDescriptor(
      id: id,
      type: .encoder,
      displayName: "Valid",
      repoId: repoSlug,
      files: [
        ComponentFile(
          relativePath: "model.safetensors",
          expectedSizeBytes: Int64(content.count),
          sha256: "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
        )
      ],
      estimatedSizeBytes: Int64(content.count),
      minimumMemoryBytes: 100
    )
    Acervo.register(descriptor)
    defer { Acervo.unregister(id) }

    let result = try Acervo.verifyComponent(id, in: tempDir)
    #expect(result == true)
  }

  @Test("verifyComponent on a component with one corrupted file returns false")
  func verifyComponentCorrupted() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let id = "iv-corrupt-\(uid)"
    let repoSlug = "org/iv-corrupt-\(uid)"
    let corruptContent = Data("CORRUPTED DATA".utf8)

    let componentDir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    try corruptContent.write(to: componentDir.appendingPathComponent("model.safetensors"))

    let descriptor = ComponentDescriptor(
      id: id,
      type: .encoder,
      displayName: "Corrupt",
      repoId: repoSlug,
      files: [
        ComponentFile(
          relativePath: "model.safetensors",
          sha256: "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
        )
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )
    Acervo.register(descriptor)
    defer { Acervo.unregister(id) }

    let result = try Acervo.verifyComponent(id, in: tempDir)
    #expect(result == false)
  }

  @Test("verifyComponent on unregistered component throws componentNotRegistered")
  func verifyComponentUnregistered() throws {
    let id = "iv-unreg-\(uid)"

    do {
      _ = try Acervo.verifyComponent(id)
      Issue.record("Expected componentNotRegistered to be thrown")
    } catch let error as AcervoError {
      if case .componentNotRegistered(let errorId) = error {
        #expect(errorId == id)
      } else {
        Issue.record("Expected componentNotRegistered, got \(error)")
      }
    }
  }

  @Test("verifyComponent on registered but not-downloaded component throws componentNotDownloaded")
  func verifyComponentNotDownloaded() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let id = "iv-not-dl-\(uid)"
    let repoSlug = "org/iv-not-dl-\(uid)"

    let descriptor = ComponentDescriptor(
      id: id,
      type: .encoder,
      displayName: "Not Downloaded",
      repoId: repoSlug,
      files: [ComponentFile(relativePath: "model.safetensors")],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )
    Acervo.register(descriptor)
    defer { Acervo.unregister(id) }

    do {
      _ = try Acervo.verifyComponent(id, in: tempDir)
      Issue.record("Expected componentNotDownloaded to be thrown")
    } catch let error as AcervoError {
      if case .componentNotDownloaded(let errorId) = error {
        #expect(errorId == id)
      } else {
        Issue.record("Expected componentNotDownloaded, got \(error)")
      }
    }
  }

  @Test("verifyComponent with no checksums declared returns true")
  func verifyComponentNoChecksums() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let id = "iv-no-chk-\(uid)"
    let repoSlug = "org/iv-no-chk-\(uid)"

    let componentDir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    try Data("data".utf8).write(to: componentDir.appendingPathComponent("model.safetensors"))

    let descriptor = ComponentDescriptor(
      id: id,
      type: .encoder,
      displayName: "No Checksums",
      repoId: repoSlug,
      files: [ComponentFile(relativePath: "model.safetensors")],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )
    Acervo.register(descriptor)
    defer { Acervo.unregister(id) }

    let result = try Acervo.verifyComponent(id, in: tempDir)
    #expect(result == true)
  }

  // MARK: - Acervo.verifyAllComponents

  @Test("verifyAllComponents returns empty array when valid components pass")
  func verifyAllComponentsAllPass() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let id = "iv-all-pass-\(uid)"
    let repoSlug = "org/iv-all-pass-\(uid)"
    let content = Data("Hello, world!".utf8)

    let dir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try content.write(to: dir.appendingPathComponent("file.txt"))

    Acervo.register(
      ComponentDescriptor(
        id: id,
        type: .encoder,
        displayName: "Pass",
        repoId: repoSlug,
        files: [
          ComponentFile(
            relativePath: "file.txt",
            expectedSizeBytes: Int64(content.count),
            sha256: "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
          )
        ],
        estimatedSizeBytes: Int64(content.count),
        minimumMemoryBytes: 100
      ))
    defer { Acervo.unregister(id) }

    let failures = try Acervo.verifyAllComponents(in: tempDir)
    // Our valid component should not be in failures
    #expect(!failures.contains(id))
  }

  @Test("verifyAllComponents includes IDs of failed components")
  func verifyAllComponentsReturnsFailures() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    // Register a valid component
    let goodId = "iv-good-\(uid)"
    let goodRepo = "org/iv-good-\(uid)"
    let goodContent = Data("Hello, world!".utf8)

    let goodDir = tempDir.appendingPathComponent(Acervo.slugify(goodRepo))
    try FileManager.default.createDirectory(at: goodDir, withIntermediateDirectories: true)
    try goodContent.write(to: goodDir.appendingPathComponent("file.txt"))

    Acervo.register(
      ComponentDescriptor(
        id: goodId,
        type: .encoder,
        displayName: "Good",
        repoId: goodRepo,
        files: [
          ComponentFile(
            relativePath: "file.txt",
            expectedSizeBytes: Int64(goodContent.count),
            sha256: "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3"
          )
        ],
        estimatedSizeBytes: Int64(goodContent.count),
        minimumMemoryBytes: 100
      ))
    defer { Acervo.unregister(goodId) }

    // Register a corrupt component (wrong checksum)
    let badId = "iv-bad-\(uid)"
    let badRepo = "org/iv-bad-\(uid)"
    let badContent = Data("bad data".utf8)

    let badDir = tempDir.appendingPathComponent(Acervo.slugify(badRepo))
    try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
    try badContent.write(to: badDir.appendingPathComponent("file.txt"))

    Acervo.register(
      ComponentDescriptor(
        id: badId,
        type: .decoder,
        displayName: "Bad",
        repoId: badRepo,
        files: [
          ComponentFile(
            relativePath: "file.txt",
            expectedSizeBytes: Int64(badContent.count),
            sha256: "0000000000000000000000000000000000000000000000000000000000000000"
          )
        ],
        estimatedSizeBytes: Int64(badContent.count),
        minimumMemoryBytes: 100
      ))
    defer { Acervo.unregister(badId) }

    let failures = try Acervo.verifyAllComponents(in: tempDir)
    #expect(failures.contains(badId))
    #expect(!failures.contains(goodId))
  }

  @Test("verifyAllComponents skips not-downloaded components")
  func verifyAllComponentsSkipsNotDownloaded() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let id = "iv-not-dl-all-\(uid)"
    let repoSlug = "org/iv-not-dl-all-\(uid)"

    Acervo.register(
      ComponentDescriptor(
        id: id,
        type: .encoder,
        displayName: "Not Downloaded",
        repoId: repoSlug,
        files: [ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 100)],
        estimatedSizeBytes: 100,
        minimumMemoryBytes: 200
      ))
    defer { Acervo.unregister(id) }

    // Not-downloaded components should be skipped, not counted as failures
    let failures = try Acervo.verifyAllComponents(in: tempDir)
    #expect(!failures.contains(id))
  }

  // MARK: - Helpers

  private func makeTempDirectory() throws -> URL {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftAcervoTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
  }

  private func cleanupTempDirectory(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }
}
