// LocalAccessTests.swift
// SwiftAcervoTests
//
// Tests for AcervoManager.withLocalAccess(_:perform:) and LocalHandle.
// Covers the four cases from TODO.md:
//   1. Valid directory URL — closure receives handle, resolves files by suffix
//   2. Valid single-file URL — url(matching:) matches the file's own suffix
//   3. Non-existent URL — throws AcervoError.localPathNotFound
//   4. Concurrent calls with distinct URLs — no data races

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Local Access Tests")
struct LocalAccessTests {

  // MARK: - Helpers

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftAcervoLocalTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func removeTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  // MARK: - 1. Valid directory URL

  @Test("withLocalAccess with directory — handle resolves files by suffix")
  func validDirectoryAccess() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    // Create test files
    let safetensors = tempDir.appendingPathComponent("adapter.safetensors")
    let config = tempDir.appendingPathComponent("config.json")
    try Data("weights".utf8).write(to: safetensors)
    try Data("{}".utf8).write(to: config)

    let result = try await AcervoManager.shared.withLocalAccess(tempDir) { handle in
      #expect(handle.rootURL == tempDir)

      let weightsURL = try handle.url(matching: ".safetensors")
      #expect(weightsURL.lastPathComponent == "adapter.safetensors")
      #expect(FileManager.default.fileExists(atPath: weightsURL.path))

      let configURL = try handle.url(matching: ".json")
      #expect(configURL.lastPathComponent == "config.json")

      let allSafetensors = try handle.urls(matching: ".safetensors")
      #expect(allSafetensors.count == 1)

      return "directory-ok"
    }

    #expect(result == "directory-ok")
  }

  @Test("withLocalAccess directory — url(for:) resolves relative path")
  func validDirectoryRelativePath() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let target = tempDir.appendingPathComponent("model.safetensors")
    try Data("w".utf8).write(to: target)

    let resolved = try await AcervoManager.shared.withLocalAccess(tempDir) { handle in
      try handle.url(for: "model.safetensors")
    }

    #expect(resolved.lastPathComponent == "model.safetensors")
  }

  @Test("withLocalAccess directory — urls(matching:) returns all matches sorted")
  func directoryMultipleMatches() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    try Data("a".utf8).write(to: tempDir.appendingPathComponent("shard-02.safetensors"))
    try Data("b".utf8).write(to: tempDir.appendingPathComponent("shard-01.safetensors"))
    try Data("c".utf8).write(to: tempDir.appendingPathComponent("config.json"))

    let urls = try await AcervoManager.shared.withLocalAccess(tempDir) { handle in
      try handle.urls(matching: ".safetensors")
    }

    #expect(urls.count == 2)
    // Sorted by path — shard-01 comes before shard-02
    #expect(urls[0].lastPathComponent == "shard-01.safetensors")
    #expect(urls[1].lastPathComponent == "shard-02.safetensors")
  }

  @Test("withLocalAccess directory — url(matching:) throws when no match")
  func directoryNoMatchThrows() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    try Data("{}".utf8).write(to: tempDir.appendingPathComponent("config.json"))

    do {
      _ = try await AcervoManager.shared.withLocalAccess(tempDir) { handle in
        try handle.url(matching: ".safetensors")
      }
      #expect(Bool(false), "Expected localPathNotFound")
    } catch let error as AcervoError {
      guard case .localPathNotFound = error else {
        #expect(Bool(false), "Expected localPathNotFound, got \(error)")
        return
      }
    }
  }

  // MARK: - 2. Valid single-file URL

  @Test("withLocalAccess with single file — url(matching:) matches own suffix")
  func validSingleFileAccess() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let fileURL = tempDir.appendingPathComponent("lora.safetensors")
    try Data("lora-weights".utf8).write(to: fileURL)

    let result = try await AcervoManager.shared.withLocalAccess(fileURL) { handle in
      #expect(handle.rootURL == fileURL)

      let matched = try handle.url(matching: ".safetensors")
      #expect(matched == fileURL)

      let all = try handle.urls(matching: ".safetensors")
      #expect(all.count == 1)
      #expect(all[0] == fileURL)

      return "file-ok"
    }

    #expect(result == "file-ok")
  }

  @Test("withLocalAccess single file — url(for: '.') returns rootURL")
  func singleFileDotRelativePath() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let fileURL = tempDir.appendingPathComponent("weights.safetensors")
    try Data("w".utf8).write(to: fileURL)

    let resolved = try await AcervoManager.shared.withLocalAccess(fileURL) { handle in
      try handle.url(for: ".")
    }
    #expect(resolved == fileURL)
  }

  @Test("withLocalAccess single file — url(for: '') returns rootURL")
  func singleFileEmptyRelativePath() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let fileURL = tempDir.appendingPathComponent("weights.safetensors")
    try Data("w".utf8).write(to: fileURL)

    let resolved = try await AcervoManager.shared.withLocalAccess(fileURL) { handle in
      try handle.url(for: "")
    }
    #expect(resolved == fileURL)
  }

  @Test("withLocalAccess single file — url(matching:) returns empty for wrong suffix")
  func singleFileWrongSuffix() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let fileURL = tempDir.appendingPathComponent("model.safetensors")
    try Data("w".utf8).write(to: fileURL)

    let result = try await AcervoManager.shared.withLocalAccess(fileURL) { handle in
      try handle.urls(matching: ".json")
    }
    #expect(result.isEmpty)
  }

  // MARK: - 3. Non-existent URL

  @Test("withLocalAccess with non-existent URL throws localPathNotFound")
  func nonExistentURLThrows() async throws {
    let missing = URL(fileURLWithPath: "/tmp/acervo-test-does-not-exist-\(UUID().uuidString)")

    do {
      _ = try await AcervoManager.shared.withLocalAccess(missing) { _ in "should not reach" }
      #expect(Bool(false), "Expected localPathNotFound error")
    } catch let error as AcervoError {
      guard case .localPathNotFound(let url) = error else {
        #expect(Bool(false), "Expected localPathNotFound, got \(error)")
        return
      }
      #expect(url == missing)
    }
  }

  @Test("AcervoError.localPathNotFound has correct errorDescription")
  func errorDescription() {
    let url = URL(fileURLWithPath: "/tmp/nonexistent/path")
    let error = AcervoError.localPathNotFound(url: url)
    #expect(error.errorDescription == "Local path not found: /tmp/nonexistent/path")
  }

  // MARK: - 4. Concurrent calls — no data races

  @Test("withLocalAccess concurrent calls with distinct URLs — no data races")
  func concurrentDistinctURLs() async throws {
    let count = 8
    var dirs: [URL] = []
    for i in 0..<count {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftAcervoLocalConcurrent-\(i)-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data("weights-\(i)".utf8).write(to: dir.appendingPathComponent("model-\(i).safetensors"))
      dirs.append(dir)
    }
    defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    let manager = AcervoManager.shared

    try await withThrowingTaskGroup(of: String.self) { group in
      for dir in dirs {
        group.addTask {
          try await manager.withLocalAccess(dir) { handle in
            let url = try handle.url(matching: ".safetensors")
            return url.lastPathComponent
          }
        }
      }
      var names: [String] = []
      for try await name in group {
        names.append(name)
      }
      #expect(names.count == count)
      for i in 0..<count {
        #expect(names.contains("model-\(i).safetensors"))
      }
    }
  }
}
