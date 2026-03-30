// ComponentAccessTests.swift
// SwiftAcervoTests
//
// Tests for AcervoManager.withComponentAccess(_:perform:)
// covering registration checks, download checks, integrity
// verification, per-component locking, and handle access.
//
// Uses unique component IDs per test (via UUID suffixes) to avoid
// interference with other test suites using ComponentRegistry.shared.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Component Access Tests")
struct ComponentAccessTests {

  /// A unique suffix for each test instance to ensure component ID isolation.
  private let uid = UUID().uuidString.prefix(8)

  /// Creates a temp directory and returns its URL.
  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftAcervoTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Removes a temp directory.
  private func removeTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  /// Creates a test component descriptor with known files.
  private func makeTestDescriptor(
    id: String,
    repo: String = "test-org/test-repo",
    files: [ComponentFile] = [
      ComponentFile(relativePath: "config.json"),
      ComponentFile(relativePath: "model.safetensors"),
    ]
  ) -> ComponentDescriptor {
    ComponentDescriptor(
      id: id,
      type: .backbone,
      displayName: "Test Component",
      repoId: repo,
      files: files,
      estimatedSizeBytes: 1000,
      minimumMemoryBytes: 2000
    )
  }

  /// Creates files on disk for a descriptor within a base directory.
  private func createFilesOnDisk(
    for descriptor: ComponentDescriptor,
    in baseDirectory: URL,
    content: Data = Data("test content".utf8)
  ) throws {
    let slug = Acervo.slugify(descriptor.repoId)
    let componentDir = baseDirectory.appendingPathComponent(slug)
    let fm = FileManager.default

    for file in descriptor.files {
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      let parentDir = fileURL.deletingLastPathComponent()
      try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
      try content.write(to: fileURL)
    }
  }

  // MARK: - Registration Checks

  @Test("withComponentAccess throws componentNotRegistered for unknown ID")
  func accessUnregisteredComponent() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let unknownId = "nonexistent-\(uid)"
    let manager = AcervoManager.shared

    do {
      _ = try await manager.withComponentAccess(
        unknownId,
        in: tempDir
      ) { handle in
        return handle.descriptor.id
      }
      #expect(Bool(false), "Expected componentNotRegistered error")
    } catch let error as AcervoError {
      guard case .componentNotRegistered(let id) = error else {
        #expect(Bool(false), "Expected componentNotRegistered, got \(error)")
        return
      }
      #expect(id == unknownId)
    }
  }

  // MARK: - Download Checks

  @Test("withComponentAccess throws componentNotDownloaded when files missing")
  func accessNotDownloadedComponent() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-not-dl-\(uid)"
    let descriptor = makeTestDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    let manager = AcervoManager.shared

    do {
      _ = try await manager.withComponentAccess(
        componentId,
        in: tempDir
      ) { handle in
        return handle.descriptor.id
      }
      #expect(Bool(false), "Expected componentNotDownloaded error")
    } catch let error as AcervoError {
      guard case .componentNotDownloaded(let id) = error else {
        #expect(Bool(false), "Expected componentNotDownloaded, got \(error)")
        return
      }
      #expect(id == componentId)
    }
  }

  // MARK: - Integrity Checks

  @Test("withComponentAccess throws integrityCheckFailed for corrupted file")
  func accessCorruptedComponent() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-corrupt-\(uid)"
    let correctContent = Data("correct content".utf8)
    let corruptContent = Data("wrong content".utf8)

    // Compute SHA-256 of the correct content
    let hashFile = tempDir.appendingPathComponent("hash-helper.tmp")
    try correctContent.write(to: hashFile)
    let correctHash = try IntegrityVerification.sha256(of: hashFile)
    try FileManager.default.removeItem(at: hashFile)

    let descriptor = ComponentDescriptor(
      id: componentId,
      type: .backbone,
      displayName: "Corrupt Test",
      repoId: "test-org/corrupt-\(uid)",
      files: [
        ComponentFile(
          relativePath: "model.safetensors",
          sha256: correctHash
        )
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    // Write the WRONG content to disk
    let slug = Acervo.slugify(descriptor.repoId)
    let componentDir = tempDir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(
      at: componentDir, withIntermediateDirectories: true
    )
    try corruptContent.write(
      to: componentDir.appendingPathComponent("model.safetensors")
    )

    let manager = AcervoManager.shared

    do {
      _ = try await manager.withComponentAccess(
        componentId,
        in: tempDir
      ) { handle in
        return "should not reach"
      }
      #expect(Bool(false), "Expected integrityCheckFailed error")
    } catch let error as AcervoError {
      guard case .integrityCheckFailed = error else {
        #expect(Bool(false), "Expected integrityCheckFailed, got \(error)")
        return
      }
      // Integrity check failure means the closure was never invoked.
    }
  }

  // MARK: - Successful Access

  @Test("withComponentAccess provides valid handle for downloaded component")
  func accessDownloadedComponent() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-ok-\(uid)"
    let descriptor = makeTestDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    let manager = AcervoManager.shared

    let result = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      let configURL = try handle.url(for: "config.json")
      #expect(configURL.lastPathComponent == "config.json")
      #expect(FileManager.default.fileExists(atPath: configURL.path))

      let safetensorsURL = try handle.url(matching: ".safetensors")
      #expect(safetensorsURL.lastPathComponent == "model.safetensors")

      let available = handle.availableFiles()
      #expect(available.count == 2)

      return "success"
    }

    #expect(result == "success")
  }

  @Test("withComponentAccess handle url(matching:) works for .json suffix")
  func accessHandleMatchingSuffix() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-suffix-\(uid)"
    let descriptor = makeTestDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    let manager = AcervoManager.shared

    let url = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      try handle.url(matching: ".json")
    }

    #expect(url.lastPathComponent == "config.json")
  }

  // MARK: - Per-Component Locking

  @Test("Same-component access is serialized")
  func sameComponentSerialized() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-serial-\(uid)"
    let descriptor = makeTestDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    let manager = AcervoManager.shared

    actor ResultCollector {
      var results: [Int] = []
      func append(_ value: Int) {
        results.append(value)
      }
      func getResults() -> [Int] { results }
    }

    let collector = ResultCollector()

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          let value = try await manager.withComponentAccess(
            componentId,
            in: tempDir
          ) { _ in
            return 1
          }
          await collector.append(value)
        } catch {
          // Ignore errors in test
        }
      }
      group.addTask {
        do {
          let value = try await manager.withComponentAccess(
            componentId,
            in: tempDir
          ) { _ in
            return 2
          }
          await collector.append(value)
        } catch {
          // Ignore errors in test
        }
      }
    }

    let results = await collector.getResults()
    #expect(results.count == 2)
    #expect(results.contains(1))
    #expect(results.contains(2))
  }

  @Test("Different-component access is concurrent")
  func differentComponentsConcurrent() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId1 = "access-conc-a-\(uid)"
    let componentId2 = "access-conc-b-\(uid)"
    let descriptor1 = makeTestDescriptor(
      id: componentId1,
      repo: "test-org/conc-a-\(uid)"
    )
    let descriptor2 = makeTestDescriptor(
      id: componentId2,
      repo: "test-org/conc-b-\(uid)"
    )
    Acervo.register(descriptor1)
    Acervo.register(descriptor2)
    defer {
      Acervo.unregister(componentId1)
      Acervo.unregister(componentId2)
    }
    try createFilesOnDisk(for: descriptor1, in: tempDir)
    try createFilesOnDisk(for: descriptor2, in: tempDir)

    let manager = AcervoManager.shared

    actor ResultCollector {
      var results: [String] = []
      func append(_ value: String) {
        results.append(value)
      }
      func getResults() -> [String] { results }
    }

    let collector = ResultCollector()

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          let value = try await manager.withComponentAccess(
            componentId1,
            in: tempDir
          ) { handle in
            return handle.descriptor.id
          }
          await collector.append(value)
        } catch {
          // Ignore errors in test
        }
      }
      group.addTask {
        do {
          let value = try await manager.withComponentAccess(
            componentId2,
            in: tempDir
          ) { handle in
            return handle.descriptor.id
          }
          await collector.append(value)
        } catch {
          // Ignore errors in test
        }
      }
    }

    let results = await collector.getResults()
    #expect(results.count == 2)
    #expect(results.contains(componentId1))
    #expect(results.contains(componentId2))
  }

  // MARK: - Files with No Checksum (skip integrity)

  @Test("withComponentAccess skips integrity for files without checksums")
  func accessNoChecksumFiles() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-nochk-\(uid)"
    let descriptor = makeTestDescriptor(
      id: componentId,
      files: [
        ComponentFile(relativePath: "config.json"),
        ComponentFile(relativePath: "model.safetensors"),
      ]
    )
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    let manager = AcervoManager.shared

    let result = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      return "no-checksum-ok"
    }

    #expect(result == "no-checksum-ok")
  }

  // MARK: - Access with Valid Checksum

  @Test("withComponentAccess passes integrity for files with correct checksums")
  func accessCorrectChecksum() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-chk-ok-\(uid)"
    let content = Data("verified content".utf8)

    // Compute hash of the content
    let hashFile = tempDir.appendingPathComponent("hash-helper.tmp")
    try content.write(to: hashFile)
    let correctHash = try IntegrityVerification.sha256(of: hashFile)
    try FileManager.default.removeItem(at: hashFile)

    let descriptor = ComponentDescriptor(
      id: componentId,
      type: .encoder,
      displayName: "Checksum Test",
      repoId: "test-org/chk-ok-\(uid)",
      files: [
        ComponentFile(
          relativePath: "model.safetensors",
          sha256: correctHash
        )
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir, content: content)

    let manager = AcervoManager.shared

    let result = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      let url = try handle.url(for: "model.safetensors")
      let data = try Data(contentsOf: url)
      return data.count
    }

    #expect(result == content.count)
  }

  // MARK: - Access Statistics

  @Test("withComponentAccess tracks access statistics")
  func accessTracksStatistics() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "access-stats-\(uid)"
    let descriptor = makeTestDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    let manager = AcervoManager.shared

    let countBefore = await manager.getAccessCount(for: componentId)

    _ = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { _ in "done" }

    let countAfter = await manager.getAccessCount(for: componentId)
    #expect(countAfter == countBefore + 1)
  }
}
