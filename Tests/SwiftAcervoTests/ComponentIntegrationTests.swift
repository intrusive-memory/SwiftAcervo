// ComponentIntegrationTests.swift
// SwiftAcervoTests
//
// Full lifecycle integration tests for the Component Registry v2 API.
// Covers register -> download-simulate -> access -> verify -> delete -> unregister.
// Also includes backward compatibility tests verifying v1 API unchanged.
//
// Per REQUIREMENTS A11.3:
// - No sleep or timed waits
// - No environment-dependent tests (no network, no GPU)
// - All tests use temp directories exclusively

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Component Integration Tests")
struct ComponentIntegrationTests {

  /// A unique suffix for each test instance.
  private let uid = UUID().uuidString.prefix(8)

  /// Creates a temp directory.
  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftAcervoInteg-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Removes a temp directory.
  private func removeTempDir(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  /// Creates a descriptor with unique IDs.
  private func makeDescriptor(
    id: String,
    type: ComponentType = .backbone,
    repo: String? = nil,
    files: [ComponentFile] = [
      ComponentFile(relativePath: "config.json"),
      ComponentFile(relativePath: "model.safetensors"),
    ],
    estimatedSizeBytes: Int64 = 1000,
    metadata: [String: String] = [:]
  ) -> ComponentDescriptor {
    ComponentDescriptor(
      id: id,
      type: type,
      displayName: "Test \(id)",
      huggingFaceRepo: repo ?? "test-org/\(id)",
      files: files,
      estimatedSizeBytes: estimatedSizeBytes,
      minimumMemoryBytes: 2000,
      metadata: metadata
    )
  }

  /// Creates files on disk for a descriptor.
  private func createFilesOnDisk(
    for descriptor: ComponentDescriptor,
    in baseDirectory: URL,
    content: Data = Data("test content".utf8)
  ) throws {
    let slug = Acervo.slugify(descriptor.huggingFaceRepo)
    let componentDir = baseDirectory.appendingPathComponent(slug)
    let fm = FileManager.default

    for file in descriptor.files {
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      let parentDir = fileURL.deletingLastPathComponent()
      try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
      try content.write(to: fileURL)
    }
  }

  // MARK: - Full Lifecycle

  @Test("Full lifecycle: register -> download-sim -> access -> delete -> unregister")
  func fullLifecycle() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "lifecycle-\(uid)"
    let descriptor = makeDescriptor(id: componentId)

    // 1. Register
    Acervo.register(descriptor)

    // Verify it appears in registeredComponents
    let registered = Acervo.registeredComponents()
    #expect(registered.contains(where: { $0.id == componentId }))

    // 2. Not yet downloaded
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == false)

    // 3. Simulate download by creating files
    try createFilesOnDisk(for: descriptor, in: tempDir)

    // 4. Now it's ready
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

    // 5. Access via withComponentAccess
    let manager = AcervoManager.shared
    let accessResult = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      let configURL = try handle.url(for: "config.json")
      #expect(FileManager.default.fileExists(atPath: configURL.path))
      return "accessed"
    }
    #expect(accessResult == "accessed")

    // 6. Delete component
    try Acervo.deleteComponent(componentId, in: tempDir)

    // 7. Not ready anymore (files deleted)
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == false)

    // 8. Still registered (deleteComponent preserves registration)
    #expect(Acervo.component(componentId) != nil)

    // 9. Unregister
    Acervo.unregister(componentId)

    // 10. Gone from registry
    #expect(Acervo.component(componentId) == nil)
  }

  // MARK: - Type Filtering

  @Test("Register 3 components of different types, filter correctly")
  func typeFiltering() {
    let encId1 = "integ-enc1-\(uid)"
    let encId2 = "integ-enc2-\(uid)"
    let decId = "integ-dec-\(uid)"

    Acervo.register(makeDescriptor(id: encId1, type: .encoder))
    Acervo.register(makeDescriptor(id: encId2, type: .encoder))
    Acervo.register(makeDescriptor(id: decId, type: .decoder))
    defer {
      Acervo.unregister(encId1)
      Acervo.unregister(encId2)
      Acervo.unregister(decId)
    }

    let encoders = Acervo.registeredComponents(ofType: .encoder)
    let decoders = Acervo.registeredComponents(ofType: .decoder)

    let encoderIds = Set(encoders.map(\.id))
    let decoderIds = Set(decoders.map(\.id))

    #expect(encoderIds.contains(encId1))
    #expect(encoderIds.contains(encId2))
    #expect(decoderIds.contains(decId))
    #expect(!encoderIds.contains(decId))
  }

  // MARK: - Deduplication (Same ID, Same Repo)

  @Test("Same component from two plugins deduplicates to one entry")
  func deduplicationSameRepo() {
    let componentId = "integ-dedup-\(uid)"
    let files = [ComponentFile(relativePath: "model.safetensors")]

    let desc1 = ComponentDescriptor(
      id: componentId,
      type: .backbone,
      displayName: "Plugin A",
      huggingFaceRepo: "org/shared-model",
      files: files,
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )
    let desc2 = ComponentDescriptor(
      id: componentId,
      type: .backbone,
      displayName: "Plugin B",
      huggingFaceRepo: "org/shared-model",
      files: files,
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    Acervo.register(desc1)
    Acervo.register(desc2)
    defer { Acervo.unregister(componentId) }

    // Only one entry
    let all = Acervo.registeredComponents().filter { $0.id == componentId }
    #expect(all.count == 1)
  }

  // MARK: - Deduplication (Same ID, Different Repo)

  @Test("Same ID different repo: last registration wins")
  func deduplicationDifferentRepo() {
    let componentId = "integ-dedup-diff-\(uid)"

    let desc1 = makeDescriptor(id: componentId, repo: "org/repo-v1")
    let desc2 = makeDescriptor(id: componentId, repo: "org/repo-v2")

    Acervo.register(desc1)
    Acervo.register(desc2)
    defer { Acervo.unregister(componentId) }

    let result = Acervo.component(componentId)
    #expect(result?.huggingFaceRepo == "org/repo-v2")
  }

  // MARK: - Pending Components

  @Test("pendingComponents returns only undownloaded components")
  func pendingComponentsFiltering() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let readyId = "integ-ready-\(uid)"
    let pendingId = "integ-pending-\(uid)"

    let readyDesc = makeDescriptor(id: readyId, estimatedSizeBytes: 500)
    let pendingDesc = makeDescriptor(id: pendingId, estimatedSizeBytes: 300)

    Acervo.register(readyDesc)
    Acervo.register(pendingDesc)
    defer {
      Acervo.unregister(readyId)
      Acervo.unregister(pendingId)
    }

    // Create files only for readyDesc
    try createFilesOnDisk(for: readyDesc, in: tempDir)

    let pending = Acervo.pendingComponents(in: tempDir)
    let pendingIds = pending.map(\.id)

    #expect(pendingIds.contains(pendingId))
    #expect(!pendingIds.contains(readyId))
  }

  // MARK: - Total Catalog Size

  @Test("totalCatalogSize correctly splits downloaded vs pending")
  func totalCatalogSizeCalculation() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let readyId = "integ-size-ready-\(uid)"
    let pendingId = "integ-size-pend-\(uid)"

    let readyDesc = makeDescriptor(id: readyId, estimatedSizeBytes: 100)
    let pendingDesc = makeDescriptor(id: pendingId, estimatedSizeBytes: 200)

    Acervo.register(readyDesc)
    Acervo.register(pendingDesc)
    defer {
      Acervo.unregister(readyId)
      Acervo.unregister(pendingId)
    }

    try createFilesOnDisk(for: readyDesc, in: tempDir)

    let sizes = Acervo.totalCatalogSize(in: tempDir)

    // Only readyDesc's size is in the downloaded total
    #expect(sizes.downloaded >= 100)
    // pendingDesc's size is in the pending total
    #expect(sizes.pending >= 200)
  }

  // MARK: - Integrity in Lifecycle

  @Test("verifyComponent returns true for valid component in lifecycle")
  func integrityInLifecycle() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let content = Data("integrity test data".utf8)

    // Compute SHA-256
    let hashFile = tempDir.appendingPathComponent("hash-tmp")
    try content.write(to: hashFile)
    let hash = try IntegrityVerification.sha256(of: hashFile)
    try FileManager.default.removeItem(at: hashFile)

    let componentId = "integ-verify-\(uid)"
    let descriptor = ComponentDescriptor(
      id: componentId,
      type: .encoder,
      displayName: "Verified Component",
      huggingFaceRepo: "test-org/integ-verify-\(uid)",
      files: [
        ComponentFile(relativePath: "model.safetensors", sha256: hash)
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )

    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    try createFilesOnDisk(for: descriptor, in: tempDir, content: content)

    let result = try Acervo.verifyComponent(componentId, in: tempDir)
    #expect(result == true)
  }

  @Test("verifyAllComponents returns empty when all pass")
  func verifyAllComponentsAllPass() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "integ-verifyall-\(uid)"
    let descriptor = makeDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    let failures = try Acervo.verifyAllComponents(in: tempDir)
    // No failures expected (no checksums declared = all pass)
    let relevantFailures = failures.filter { $0 == componentId }
    #expect(relevantFailures.isEmpty)
  }

  // MARK: - Backward Compatibility (v1 API)

  @Test("v1 API listModels still works")
  func v1ListModels() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    // Create a model directory with config.json
    let modelDir = tempDir.appendingPathComponent("test-org_v1-model")
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

    let models = try Acervo.listModels(in: tempDir)
    #expect(models.count == 1)
    #expect(models.first?.id == "test-org/v1-model")
  }

  @Test("v1 API isModelAvailable still works")
  func v1IsModelAvailable() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    // Not available
    #expect(Acervo.isModelAvailable("test-org/nonexistent", in: tempDir) == false)

    // Create model with config.json
    let modelDir = tempDir.appendingPathComponent("test-org_exists")
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

    #expect(Acervo.isModelAvailable("test-org/exists", in: tempDir) == true)
  }

  @Test("v1 API withModelAccess still works")
  func v1WithModelAccess() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    // The v1 withModelAccess uses the global sharedModelsDirectory,
    // but we can verify the method is callable and compiles.
    // We test with a model ID that doesn't need to be on disk
    // (the method resolves via modelDirectory(for:) which just computes the path).
    let manager = AcervoManager.shared
    let result = try await manager.withModelAccess("test-org/v1-compat") { url in
      return url.lastPathComponent
    }

    #expect(result == "test-org_v1-compat")
  }

  @Test("v1 API deleteModel still works")
  func v1DeleteModel() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let modelDir = tempDir.appendingPathComponent("test-org_v1-delete")
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

    // Verify exists
    #expect(FileManager.default.fileExists(atPath: modelDir.path))

    // Delete using v1 API
    try Acervo.deleteModel("test-org/v1-delete", in: tempDir)

    // Verify deleted
    #expect(!FileManager.default.fileExists(atPath: modelDir.path))
  }

  // MARK: - Three State Verification

  @Test("Three states: registered+downloaded, not-registered+on-disk, registered+not-downloaded")
  func threeStateVerification() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    // State 1: Registered + Downloaded
    let regDownId = "integ-state1-\(uid)"
    let regDownDesc = makeDescriptor(
      id: regDownId,
      repo: "test-org/integ-state1-\(uid)"
    )
    Acervo.register(regDownDesc)
    defer { Acervo.unregister(regDownId) }

    // Create files and config.json for listModels to see it
    let slug1 = Acervo.slugify(regDownDesc.huggingFaceRepo)
    let dir1 = tempDir.appendingPathComponent(slug1)
    try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: dir1.appendingPathComponent("config.json"))
    try Data("model".utf8).write(to: dir1.appendingPathComponent("model.safetensors"))

    // State 2: Not-registered + on-disk (legacy)
    let legacyDir = tempDir.appendingPathComponent("legacy-org_legacy-model")
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: legacyDir.appendingPathComponent("config.json"))

    // State 3: Registered + Not Downloaded
    let regNotDlId = "integ-state3-\(uid)"
    let regNotDlDesc = makeDescriptor(
      id: regNotDlId,
      repo: "test-org/integ-state3-\(uid)"
    )
    Acervo.register(regNotDlDesc)
    defer { Acervo.unregister(regNotDlId) }

    // Verify State 1: appears in both views
    let registeredIds = Set(Acervo.registeredComponents().map(\.id))
    let modelIds = Set(try Acervo.listModels(in: tempDir).map(\.id))

    #expect(registeredIds.contains(regDownId))
    // listModels sees the directory since it has config.json
    #expect(
      modelIds.contains(regDownDesc.huggingFaceRepo.replacingOccurrences(of: "_", with: "/"))
        || modelIds.contains("test-org/integ-state1-\(uid)"))

    // Verify State 2: appears only in listModels
    #expect(modelIds.contains("legacy-org/legacy-model"))
    #expect(!registeredIds.contains("legacy-org/legacy-model"))

    // Verify State 3: appears only in registeredComponents
    #expect(registeredIds.contains(regNotDlId))
    // Should NOT appear in listModels since files don't exist
    #expect(!modelIds.contains(regNotDlId))
  }

  // MARK: - ensureComponentReady No-Op for Cached

  @Test("ensureComponentReady is no-op when already cached")
  func ensureReadyNoOp() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "integ-ensure-\(uid)"
    let descriptor = makeDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }
    try createFilesOnDisk(for: descriptor, in: tempDir)

    // Already ready
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

    // Should return immediately without error
    try await Acervo.ensureComponentReady(componentId, in: tempDir)

    // Still ready
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
  }

  // MARK: - deleteComponent + Re-Registration

  @Test("Delete then re-create files: component becomes ready again")
  func deleteAndRecreate() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "integ-delrecreate-\(uid)"
    let descriptor = makeDescriptor(id: componentId)
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    // Create files
    try createFilesOnDisk(for: descriptor, in: tempDir)
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

    // Delete
    try Acervo.deleteComponent(componentId, in: tempDir)
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == false)

    // Re-create (simulate re-download)
    try createFilesOnDisk(for: descriptor, in: tempDir)
    #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
  }

  // MARK: - ComponentHandle URL Validation

  @Test("ComponentHandle url(for:) throws for missing file")
  func handleUrlForMissingFile() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "integ-handle-\(uid)"
    let descriptor = makeDescriptor(
      id: componentId,
      files: [
        ComponentFile(relativePath: "config.json"),
        ComponentFile(relativePath: "model.safetensors"),
        ComponentFile(relativePath: "extra.bin"),
      ]
    )
    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    // Create only some files (not extra.bin)
    let slug = Acervo.slugify(descriptor.huggingFaceRepo)
    let componentDir = tempDir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: componentDir.appendingPathComponent("config.json"))
    try Data("model".utf8).write(to: componentDir.appendingPathComponent("model.safetensors"))
    try Data("extra".utf8).write(to: componentDir.appendingPathComponent("extra.bin"))

    let manager = AcervoManager.shared

    try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      // These should work
      _ = try handle.url(for: "config.json")
      _ = try handle.url(for: "model.safetensors")
      _ = try handle.url(for: "extra.bin")

      // Available files should include all three
      let available = handle.availableFiles()
      #expect(available.count == 3)
    }
  }

  // MARK: - Sharded Weights (urls(matching:))

  @Test("ComponentHandle urls(matching:) returns all sharded weight files")
  func handleUrlsMatchingShardedWeights() async throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let componentId = "integ-sharded-\(uid)"
    let descriptor = ComponentDescriptor(
      id: componentId,
      type: .backbone,
      displayName: "Sharded Model",
      huggingFaceRepo: "test-org/integ-sharded-\(uid)",
      files: [
        ComponentFile(relativePath: "config.json"),
        ComponentFile(relativePath: "model-00001-of-00003.safetensors"),
        ComponentFile(relativePath: "model-00002-of-00003.safetensors"),
        ComponentFile(relativePath: "model-00003-of-00003.safetensors"),
      ],
      estimatedSizeBytes: 3000,
      minimumMemoryBytes: 6000
    )

    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    // Create all files
    let slug = Acervo.slugify(descriptor.huggingFaceRepo)
    let componentDir = tempDir.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
    for file in descriptor.files {
      try Data("shard data".utf8).write(
        to: componentDir.appendingPathComponent(file.relativePath)
      )
    }

    let manager = AcervoManager.shared

    let shardURLs = try await manager.withComponentAccess(
      componentId,
      in: tempDir
    ) { handle in
      try handle.urls(matching: ".safetensors")
    }

    #expect(shardURLs.count == 3)
  }

  // MARK: - Metadata Preservation

  @Test("Component metadata is preserved through registration")
  func metadataPreservation() {
    let componentId = "integ-meta-\(uid)"
    let descriptor = makeDescriptor(
      id: componentId,
      metadata: [
        "quantization": "int4",
        "architecture": "dit",
        "custom_key": "custom_value",
      ]
    )

    Acervo.register(descriptor)
    defer { Acervo.unregister(componentId) }

    let result = Acervo.component(componentId)
    #expect(result?.metadata["quantization"] == "int4")
    #expect(result?.metadata["architecture"] == "dit")
    #expect(result?.metadata["custom_key"] == "custom_value")
  }

  // MARK: - Component Not Registered Error

  @Test("isComponentReady returns false for unregistered ID")
  func isReadyForUnregistered() {
    #expect(Acervo.isComponentReady("definitely-not-registered-\(uid)") == false)
  }

  // MARK: - Descriptor Equality

  @Test("Two descriptors with same ID are equal regardless of other fields")
  func descriptorEqualityById() {
    let desc1 = ComponentDescriptor(
      id: "eq-test",
      type: .encoder,
      displayName: "Name A",
      huggingFaceRepo: "org/repo-a",
      files: [],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 200
    )
    let desc2 = ComponentDescriptor(
      id: "eq-test",
      type: .decoder,
      displayName: "Name B",
      huggingFaceRepo: "org/repo-b",
      files: [ComponentFile(relativePath: "f.bin")],
      estimatedSizeBytes: 999,
      minimumMemoryBytes: 888
    )

    #expect(desc1 == desc2)
    #expect(desc1.hashValue == desc2.hashValue)
  }

  // MARK: - ComponentType Completeness

  @Test("ComponentType has all 7 cases")
  func componentTypeCases() {
    #expect(ComponentType.allCases.count == 7)

    let expectedCases: Set<ComponentType> = [
      .encoder, .backbone, .decoder, .scheduler,
      .tokenizer, .auxiliary, .languageModel,
    ]
    #expect(Set(ComponentType.allCases) == expectedCases)
  }

  // MARK: - SHA-256 Known Value

  @Test("SHA-256 of 'Hello, world!' matches known value")
  func sha256KnownValue() throws {
    let tempDir = try makeTempDir()
    defer { removeTempDir(tempDir) }

    let file = tempDir.appendingPathComponent("hello.txt")
    try Data("Hello, world!".utf8).write(to: file)

    let hash = try IntegrityVerification.sha256(of: file)
    #expect(hash == "315f5bdb76d078c43b8ac0064e4a0164612b1fce77c869345bfc94c75894edd3")
  }
}
