import Foundation
import Testing
@testable import SwiftAcervo

/// Tests for the Component Catalog query API (Sortie 5).
///
/// These tests use unique component IDs per test (via UUID suffixes) to avoid
/// interference with other test suites that use `ComponentRegistry.shared`.
@Suite("Component Catalog Query Tests")
struct ComponentCatalogTests {

    /// A unique suffix for each test instance to ensure component ID isolation.
    private let uid = UUID().uuidString.prefix(8)

    // MARK: - registeredComponents()

    @Test("registeredComponents returns registered descriptors")
    func registeredComponentsReturnsRegistered() {
        let id1 = "cat-comp-1-\(uid)"
        let id2 = "cat-comp-2-\(uid)"
        let id3 = "cat-comp-3-\(uid)"

        Acervo.register(makeDescriptor(id: id1))
        Acervo.register(makeDescriptor(id: id2))
        Acervo.register(makeDescriptor(id: id3))

        let result = Acervo.registeredComponents()
        let ids = Set(result.map(\.id))
        #expect(ids.contains(id1))
        #expect(ids.contains(id2))
        #expect(ids.contains(id3))

        // Cleanup
        Acervo.unregister(id1)
        Acervo.unregister(id2)
        Acervo.unregister(id3)
    }

    // MARK: - registeredComponents(ofType:)

    @Test("registeredComponents(ofType:) filters by type correctly")
    func registeredComponentsByType() {
        let encId1 = "cat-enc-1-\(uid)"
        let encId2 = "cat-enc-2-\(uid)"
        let decId = "cat-dec-1-\(uid)"

        Acervo.register(makeDescriptor(id: encId1, type: .encoder))
        Acervo.register(makeDescriptor(id: encId2, type: .encoder))
        Acervo.register(makeDescriptor(id: decId, type: .decoder))

        let encoders = Acervo.registeredComponents(ofType: .encoder)
        let decoders = Acervo.registeredComponents(ofType: .decoder)

        let encoderIds = Set(encoders.map(\.id))
        let decoderIds = Set(decoders.map(\.id))

        #expect(encoderIds.contains(encId1))
        #expect(encoderIds.contains(encId2))
        #expect(!encoderIds.contains(decId))
        #expect(decoderIds.contains(decId))
        #expect(!decoderIds.contains(encId1))

        // Cleanup
        Acervo.unregister(encId1)
        Acervo.unregister(encId2)
        Acervo.unregister(decId)
    }

    // MARK: - component(_:)

    @Test("component returns the descriptor for a known ID")
    func componentReturnsKnown() {
        let id = "cat-known-\(uid)"
        Acervo.register(makeDescriptor(id: id, displayName: "Known Component"))

        let result = Acervo.component(id)
        #expect(result != nil)
        #expect(result?.id == id)
        #expect(result?.displayName == "Known Component")

        Acervo.unregister(id)
    }

    @Test("component returns nil for unknown ID")
    func componentReturnsNilForUnknown() {
        #expect(Acervo.component("cat-unknown-\(uid)") == nil)
    }

    // MARK: - isComponentReady

    @Test("isComponentReady returns false for registered-but-not-downloaded component")
    func isComponentReadyFalseWhenNotDownloaded() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let id = "cat-not-dl-\(uid)"
        Acervo.register(makeDescriptor(
            id: id,
            huggingFaceRepo: "org/not-dl-\(uid)",
            files: [ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 100)]
        ))

        #expect(Acervo.isComponentReady(id, in: tempDir) == false)

        Acervo.unregister(id)
    }

    @Test("isComponentReady returns true when all files exist with correct sizes")
    func isComponentReadyTrueWhenDownloaded() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let id = "cat-dl-\(uid)"
        let repoSlug = "org/dl-\(uid)"
        let modelData = Data("hello world".utf8)  // 11 bytes
        let configData = Data("foobar".utf8)  // 6 bytes

        let files = [
            ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: Int64(modelData.count)),
            ComponentFile(relativePath: "config.json", expectedSizeBytes: Int64(configData.count)),
        ]
        Acervo.register(makeDescriptor(id: id, huggingFaceRepo: repoSlug, files: files))

        // Create the files on disk with correct sizes
        let componentDir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
        try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
        try modelData.write(to: componentDir.appendingPathComponent("model.safetensors"))
        try configData.write(to: componentDir.appendingPathComponent("config.json"))

        #expect(Acervo.isComponentReady(id, in: tempDir) == true)

        Acervo.unregister(id)
    }

    @Test("isComponentReady returns false when file size does not match")
    func isComponentReadyFalseWhenSizeMismatch() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let id = "cat-size-mismatch-\(uid)"
        let repoSlug = "org/size-mismatch-\(uid)"

        let files = [
            ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 999),
        ]
        Acervo.register(makeDescriptor(id: id, huggingFaceRepo: repoSlug, files: files))

        let componentDir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
        try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
        try Data("small".utf8).write(to: componentDir.appendingPathComponent("model.safetensors"))

        #expect(Acervo.isComponentReady(id, in: tempDir) == false)

        Acervo.unregister(id)
    }

    @Test("isComponentReady returns false for unregistered component")
    func isComponentReadyFalseForUnregistered() {
        #expect(Acervo.isComponentReady("cat-nonexistent-\(uid)") == false)
    }

    @Test("isComponentReady with nil expectedSizeBytes skips size check")
    func isComponentReadySkipsSizeCheckWhenNil() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let id = "cat-no-size-\(uid)"
        let repoSlug = "org/no-size-\(uid)"

        let files = [
            ComponentFile(relativePath: "model.safetensors"),  // nil expectedSizeBytes
        ]
        Acervo.register(makeDescriptor(id: id, huggingFaceRepo: repoSlug, files: files))

        let componentDir = tempDir.appendingPathComponent(Acervo.slugify(repoSlug))
        try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)
        try Data("any size data here".utf8).write(to: componentDir.appendingPathComponent("model.safetensors"))

        #expect(Acervo.isComponentReady(id, in: tempDir) == true)

        Acervo.unregister(id)
    }

    // MARK: - pendingComponents

    @Test("pendingComponents returns only undownloaded components")
    func pendingComponentsReturnsUndownloaded() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let readyId = "cat-ready-\(uid)"
        let pendingId = "cat-pending-\(uid)"
        let readyRepo = "org/ready-\(uid)"
        let pendingRepo = "org/pending-\(uid)"

        let configData = Data("test".utf8)

        Acervo.register(makeDescriptor(
            id: readyId,
            huggingFaceRepo: readyRepo,
            files: [ComponentFile(relativePath: "config.json", expectedSizeBytes: Int64(configData.count))]
        ))
        Acervo.register(makeDescriptor(
            id: pendingId,
            huggingFaceRepo: pendingRepo,
            files: [ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 100)]
        ))

        // Create files for only the ready component
        let readyDir = tempDir.appendingPathComponent(Acervo.slugify(readyRepo))
        try FileManager.default.createDirectory(at: readyDir, withIntermediateDirectories: true)
        try configData.write(to: readyDir.appendingPathComponent("config.json"))

        let pending = Acervo.pendingComponents(in: tempDir)
        let pendingIds = Set(pending.map(\.id))

        // Our ready component should NOT be pending
        #expect(!pendingIds.contains(readyId))
        // Our pending component SHOULD be pending
        #expect(pendingIds.contains(pendingId))

        Acervo.unregister(readyId)
        Acervo.unregister(pendingId)
    }

    // MARK: - totalCatalogSize

    @Test("totalCatalogSize includes ready and pending components correctly")
    func totalCatalogSizeIncludesCorrectly() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanupTempDirectory(tempDir) }

        let readyId = "cat-sz-ready-\(uid)"
        let pendingId = "cat-sz-pending-\(uid)"
        let readyRepo = "org/sz-ready-\(uid)"
        let pendingRepo = "org/sz-pending-\(uid)"

        let configData = Data("test".utf8)

        Acervo.register(makeDescriptor(
            id: readyId,
            huggingFaceRepo: readyRepo,
            files: [ComponentFile(relativePath: "config.json", expectedSizeBytes: Int64(configData.count))],
            estimatedSizeBytes: 100
        ))
        Acervo.register(makeDescriptor(
            id: pendingId,
            huggingFaceRepo: pendingRepo,
            files: [ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 200)],
            estimatedSizeBytes: 200
        ))

        // Create files for only the ready component
        let readyDir = tempDir.appendingPathComponent(Acervo.slugify(readyRepo))
        try FileManager.default.createDirectory(at: readyDir, withIntermediateDirectories: true)
        try configData.write(to: readyDir.appendingPathComponent("config.json"))

        let size = Acervo.totalCatalogSize(in: tempDir)
        // The size includes all registered components, not just ours.
        // We verify our contributions are included:
        // - readyId (100 bytes) should be in downloaded
        // - pendingId (200 bytes) should be in pending
        // Since other tests may have registered components, we check minimum values.
        #expect(size.downloaded >= 100)
        #expect(size.pending >= 200)

        Acervo.unregister(readyId)
        Acervo.unregister(pendingId)
    }

    // MARK: - Helpers

    private func makeDescriptor(
        id: String,
        type: ComponentType = .encoder,
        displayName: String = "Test Component",
        huggingFaceRepo: String = "test-org/test-repo",
        files: [ComponentFile] = [ComponentFile(relativePath: "config.json")],
        estimatedSizeBytes: Int64 = 1000,
        minimumMemoryBytes: Int64 = 2000,
        metadata: [String: String] = [:]
    ) -> ComponentDescriptor {
        ComponentDescriptor(
            id: id,
            type: type,
            displayName: displayName,
            huggingFaceRepo: huggingFaceRepo,
            files: files,
            estimatedSizeBytes: estimatedSizeBytes,
            minimumMemoryBytes: minimumMemoryBytes,
            metadata: metadata
        )
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
