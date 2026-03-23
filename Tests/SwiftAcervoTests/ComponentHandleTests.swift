import Foundation
import Testing

@testable import SwiftAcervo

@Suite("ComponentHandle Tests")
struct ComponentHandleTests {

  // MARK: - url(for:)

  @Test("url(for:) returns URL for an existing file")
  func urlForExistingFile() throws {
    let (handle, tempDir) = try makeHandleWithFiles()
    defer { cleanupTempDirectory(tempDir) }

    let url = try handle.url(for: "model.safetensors")
    #expect(url.lastPathComponent == "model.safetensors")
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("url(for:) throws componentFileNotFound for missing file")
  func urlForMissingFile() throws {
    let (handle, tempDir) = try makeHandleWithFiles()
    defer { cleanupTempDirectory(tempDir) }

    #expect(throws: AcervoError.self) {
      try handle.url(for: "nonexistent.txt")
    }
  }

  @Test("url(for:) resolves subdirectory paths")
  func urlForSubdirectoryPath() throws {
    let (handle, tempDir) = try makeHandleWithSubdirectory()
    defer { cleanupTempDirectory(tempDir) }

    let url = try handle.url(for: "subdir/nested.json")
    #expect(url.lastPathComponent == "nested.json")
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - url(matching:)

  @Test("url(matching:) finds file by suffix")
  func urlMatchingSuffix() throws {
    let (handle, tempDir) = try makeHandleWithFiles()
    defer { cleanupTempDirectory(tempDir) }

    let url = try handle.url(matching: ".json")
    #expect(url.lastPathComponent == "config.json")
  }

  @Test("url(matching:) throws componentFileNotFound for no match")
  func urlMatchingNoMatch() throws {
    let (handle, tempDir) = try makeHandleWithFiles()
    defer { cleanupTempDirectory(tempDir) }

    #expect(throws: AcervoError.self) {
      try handle.url(matching: ".xyz")
    }
  }

  @Test("url(matching:) returns first match from descriptor file order")
  func urlMatchingReturnsFirstMatch() throws {
    let (handle, tempDir) = try makeHandleWithShardedFiles()
    defer { cleanupTempDirectory(tempDir) }

    // The first .safetensors file in the descriptor should be returned
    let url = try handle.url(matching: ".safetensors")
    #expect(url.lastPathComponent.hasSuffix(".safetensors"))
  }

  // MARK: - urls(matching:)

  @Test("urls(matching:) returns all files matching suffix")
  func urlsMatchingReturnsAll() throws {
    let (handle, tempDir) = try makeHandleWithShardedFiles()
    defer { cleanupTempDirectory(tempDir) }

    let urls = try handle.urls(matching: ".safetensors")
    // model.safetensors + 3 shards = 4 files
    #expect(urls.count == 4)
    for url in urls {
      #expect(url.lastPathComponent.hasSuffix(".safetensors"))
      #expect(FileManager.default.fileExists(atPath: url.path))
    }
  }

  @Test("urls(matching:) throws componentFileNotFound for no matches")
  func urlsMatchingNoMatch() throws {
    let (handle, tempDir) = try makeHandleWithFiles()
    defer { cleanupTempDirectory(tempDir) }

    #expect(throws: AcervoError.self) {
      try handle.urls(matching: ".xyz")
    }
  }

  @Test("urls(matching:) with .json returns only json files")
  func urlsMatchingJsonOnly() throws {
    let (handle, tempDir) = try makeHandleWithShardedFiles()
    defer { cleanupTempDirectory(tempDir) }

    let urls = try handle.urls(matching: ".json")
    #expect(urls.count == 1)
    #expect(urls.first?.lastPathComponent == "config.json")
  }

  // MARK: - availableFiles()

  @Test("availableFiles returns only files present on disk")
  func availableFilesReturnsExisting() throws {
    let (handle, tempDir) = try makeHandleWithPartialFiles()
    defer { cleanupTempDirectory(tempDir) }

    let available = handle.availableFiles()
    #expect(available.count == 1)
    #expect(available.contains("config.json"))
    #expect(!available.contains("missing.safetensors"))
  }

  @Test("availableFiles returns all files when all exist")
  func availableFilesReturnsAllWhenComplete() throws {
    let (handle, tempDir) = try makeHandleWithFiles()
    defer { cleanupTempDirectory(tempDir) }

    let available = handle.availableFiles()
    #expect(available.count == 2)
    #expect(available.contains("model.safetensors"))
    #expect(available.contains("config.json"))
  }

  @Test("availableFiles returns empty when no files exist")
  func availableFilesEmptyWhenNoneExist() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let componentDir = tempDir.appendingPathComponent("org_empty-repo")
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

    let descriptor = ComponentDescriptor(
      id: "empty",
      type: .encoder,
      displayName: "Empty",
      huggingFaceRepo: "org/empty-repo",
      files: [
        ComponentFile(relativePath: "model.safetensors"),
        ComponentFile(relativePath: "config.json"),
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    let handle = ComponentHandle(descriptor: descriptor, baseDirectory: componentDir)
    let available = handle.availableFiles()
    #expect(available.isEmpty)
  }

  // MARK: - Internal initializer

  @Test("ComponentHandle preserves descriptor and baseDirectory")
  func handlePreservesProperties() throws {
    let tempDir = try makeTempDirectory()
    defer { cleanupTempDirectory(tempDir) }

    let descriptor = ComponentDescriptor(
      id: "test-comp",
      type: .backbone,
      displayName: "Test",
      huggingFaceRepo: "org/repo",
      files: [],
      estimatedSizeBytes: 0,
      minimumMemoryBytes: 0
    )

    let handle = ComponentHandle(descriptor: descriptor, baseDirectory: tempDir)
    #expect(handle.descriptor.id == "test-comp")
    #expect(handle.baseDirectory == tempDir)
  }

  // MARK: - Helpers

  /// Creates a handle with basic files (model.safetensors + config.json).
  private func makeHandleWithFiles() throws -> (ComponentHandle, URL) {
    let tempDir = try makeTempDirectory()
    let componentDir = tempDir.appendingPathComponent("org_test-repo")
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

    try Data("model data here".utf8).write(
      to: componentDir.appendingPathComponent("model.safetensors"))
    try Data("{}".utf8).write(to: componentDir.appendingPathComponent("config.json"))

    let descriptor = ComponentDescriptor(
      id: "test-handle",
      type: .encoder,
      displayName: "Test Handle",
      huggingFaceRepo: "org/test-repo",
      files: [
        ComponentFile(relativePath: "model.safetensors"),
        ComponentFile(relativePath: "config.json"),
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    let handle = ComponentHandle(descriptor: descriptor, baseDirectory: componentDir)
    return (handle, tempDir)
  }

  /// Creates a handle with sharded files for testing urls(matching:).
  private func makeHandleWithShardedFiles() throws -> (ComponentHandle, URL) {
    let tempDir = try makeTempDirectory()
    let componentDir = tempDir.appendingPathComponent("org_sharded-repo")
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

    let shardNames = [
      "model.safetensors",
      "model-00001-of-00003.safetensors",
      "model-00002-of-00003.safetensors",
      "model-00003-of-00003.safetensors",
      "config.json",
    ]

    for name in shardNames {
      try Data("data".utf8).write(to: componentDir.appendingPathComponent(name))
    }

    let descriptor = ComponentDescriptor(
      id: "sharded-handle",
      type: .backbone,
      displayName: "Sharded Handle",
      huggingFaceRepo: "org/sharded-repo",
      files: shardNames.map { ComponentFile(relativePath: $0) },
      estimatedSizeBytes: 1000,
      minimumMemoryBytes: 2000
    )

    let handle = ComponentHandle(descriptor: descriptor, baseDirectory: componentDir)
    return (handle, tempDir)
  }

  /// Creates a handle with a subdirectory structure.
  private func makeHandleWithSubdirectory() throws -> (ComponentHandle, URL) {
    let tempDir = try makeTempDirectory()
    let componentDir = tempDir.appendingPathComponent("org_subdir-repo")
    let subdir = componentDir.appendingPathComponent("subdir")
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

    try Data("{}".utf8).write(to: subdir.appendingPathComponent("nested.json"))

    let descriptor = ComponentDescriptor(
      id: "subdir-handle",
      type: .tokenizer,
      displayName: "Subdir Handle",
      huggingFaceRepo: "org/subdir-repo",
      files: [
        ComponentFile(relativePath: "subdir/nested.json")
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    let handle = ComponentHandle(descriptor: descriptor, baseDirectory: componentDir)
    return (handle, tempDir)
  }

  /// Creates a handle where only some descriptor files exist on disk.
  private func makeHandleWithPartialFiles() throws -> (ComponentHandle, URL) {
    let tempDir = try makeTempDirectory()
    let componentDir = tempDir.appendingPathComponent("org_partial-repo")
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

    // Only create config.json, not missing.safetensors
    try Data("{}".utf8).write(to: componentDir.appendingPathComponent("config.json"))

    let descriptor = ComponentDescriptor(
      id: "partial-handle",
      type: .encoder,
      displayName: "Partial Handle",
      huggingFaceRepo: "org/partial-repo",
      files: [
        ComponentFile(relativePath: "config.json"),
        ComponentFile(relativePath: "missing.safetensors"),
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    let handle = ComponentHandle(descriptor: descriptor, baseDirectory: componentDir)
    return (handle, tempDir)
  }

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
