// ComponentDownloadTests.swift
// SwiftAcervoTests
//
// Tests for registry-aware download and deletion API:
// Acervo.downloadComponent, ensureComponentReady,
// ensureComponentsReady, and deleteComponent.
//
// Per REQUIREMENTS A11.3, no network calls in these tests.
// All tests use temp directories and unique component IDs.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Component Download Tests")
struct ComponentDownloadTests {

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

    /// Creates a test component descriptor.
    private func makeDescriptor(
        id: String,
        repo: String = "test-org/test-repo",
        files: [ComponentFile] = [
            ComponentFile(relativePath: "config.json"),
            ComponentFile(relativePath: "model.safetensors"),
        ],
        estimatedSizeBytes: Int64 = 1000
    ) -> ComponentDescriptor {
        ComponentDescriptor(
            id: id,
            type: .backbone,
            displayName: "Test Component",
            huggingFaceRepo: repo,
            files: files,
            estimatedSizeBytes: estimatedSizeBytes,
            minimumMemoryBytes: 2000
        )
    }

    /// Creates files on disk simulating a downloaded component.
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

    // MARK: - downloadComponent

    @Test("downloadComponent throws componentNotRegistered for unknown ID")
    func downloadUnregisteredComponent() async throws {
        let unknownId = "dl-unknown-\(uid)"

        do {
            try await Acervo.downloadComponent(unknownId)
            #expect(Bool(false), "Expected componentNotRegistered error")
        } catch let error as AcervoError {
            guard case .componentNotRegistered(let id) = error else {
                #expect(Bool(false), "Expected componentNotRegistered, got \(error)")
                return
            }
            #expect(id == unknownId)
        }
    }

    // MARK: - ensureComponentReady

    @Test("ensureComponentReady is no-op when files already exist")
    func ensureReadyWhenAlreadyCached() async throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let componentId = "ensure-cached-\(uid)"
        let descriptor = makeDescriptor(id: componentId, repo: "test-org/ensure-cached-\(uid)")
        Acervo.register(descriptor)
        defer { Acervo.unregister(componentId) }

        // Create files on disk to simulate already-downloaded component
        try createFilesOnDisk(for: descriptor, in: tempDir)

        // Verify component is ready before calling ensureComponentReady
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

        // ensureComponentReady should return immediately without error
        try await Acervo.ensureComponentReady(
            componentId,
            in: tempDir
        )

        // Files should still be there
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
    }

    @Test("ensureComponentReady throws componentNotRegistered for unknown ID")
    func ensureReadyUnregistered() async throws {
        let unknownId = "ensure-unknown-\(uid)"
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        do {
            try await Acervo.ensureComponentReady(unknownId, in: tempDir)
            #expect(Bool(false), "Expected componentNotRegistered error")
        } catch let error as AcervoError {
            guard case .componentNotRegistered(let id) = error else {
                #expect(Bool(false), "Expected componentNotRegistered, got \(error)")
                return
            }
            #expect(id == unknownId)
        }
    }

    // MARK: - ensureComponentsReady

    @Test("ensureComponentsReady throws componentNotRegistered for unknown ID in batch")
    func ensureComponentsReadyUnregistered() async throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let knownId = "batch-known-\(uid)"
        let unknownId = "batch-unknown-\(uid)"
        let descriptor = makeDescriptor(id: knownId, repo: "test-org/batch-known-\(uid)")
        Acervo.register(descriptor)
        defer { Acervo.unregister(knownId) }
        try createFilesOnDisk(for: descriptor, in: tempDir)

        do {
            try await Acervo.ensureComponentsReady(
                [knownId, unknownId],
                in: tempDir
            )
            #expect(Bool(false), "Expected componentNotRegistered error")
        } catch let error as AcervoError {
            guard case .componentNotRegistered(let id) = error else {
                #expect(Bool(false), "Expected componentNotRegistered, got \(error)")
                return
            }
            #expect(id == unknownId)
        }
    }

    @Test("ensureComponentsReady is no-op when all components already cached")
    func ensureComponentsReadyAllCached() async throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let id1 = "batch-cached-1-\(uid)"
        let id2 = "batch-cached-2-\(uid)"
        let desc1 = makeDescriptor(id: id1, repo: "test-org/batch-1-\(uid)")
        let desc2 = makeDescriptor(id: id2, repo: "test-org/batch-2-\(uid)")
        Acervo.register(desc1)
        Acervo.register(desc2)
        defer {
            Acervo.unregister(id1)
            Acervo.unregister(id2)
        }

        try createFilesOnDisk(for: desc1, in: tempDir)
        try createFilesOnDisk(for: desc2, in: tempDir)

        // Should return without error since both are cached
        try await Acervo.ensureComponentsReady(
            [id1, id2],
            in: tempDir
        )

        // Both still ready
        #expect(Acervo.isComponentReady(id1, in: tempDir) == true)
        #expect(Acervo.isComponentReady(id2, in: tempDir) == true)
    }

    // MARK: - deleteComponent

    @Test("deleteComponent removes files but preserves registration")
    func deletePreservesRegistration() throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let componentId = "del-preserve-\(uid)"
        let descriptor = makeDescriptor(id: componentId, repo: "test-org/del-preserve-\(uid)")
        Acervo.register(descriptor)
        defer { Acervo.unregister(componentId) }

        try createFilesOnDisk(for: descriptor, in: tempDir)

        // Verify downloaded
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

        // Delete
        try Acervo.deleteComponent(componentId, in: tempDir)

        // Files removed
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == false)

        // Registration preserved
        #expect(Acervo.component(componentId) != nil)
        #expect(Acervo.component(componentId)?.id == componentId)
    }

    @Test("deleteComponent for not-downloaded is a no-op")
    func deleteNotDownloadedIsNoop() throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let componentId = "del-noop-\(uid)"
        let descriptor = makeDescriptor(id: componentId, repo: "test-org/del-noop-\(uid)")
        Acervo.register(descriptor)
        defer { Acervo.unregister(componentId) }

        // Component is registered but not downloaded -- no files on disk
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == false)

        // Delete should succeed without error (no-op)
        try Acervo.deleteComponent(componentId, in: tempDir)

        // Still registered
        #expect(Acervo.component(componentId) != nil)
    }

    @Test("deleteComponent throws componentNotRegistered for unknown ID")
    func deleteUnregisteredComponent() throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let unknownId = "del-unknown-\(uid)"

        do {
            try Acervo.deleteComponent(unknownId, in: tempDir)
            #expect(Bool(false), "Expected componentNotRegistered error")
        } catch let error as AcervoError {
            guard case .componentNotRegistered(let id) = error else {
                #expect(Bool(false), "Expected componentNotRegistered, got \(error)")
                return
            }
            #expect(id == unknownId)
        }
    }

    @Test("deleteComponent followed by re-download cycle")
    func deleteAndRedownloadCycle() throws {
        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let componentId = "del-cycle-\(uid)"
        let descriptor = makeDescriptor(id: componentId, repo: "test-org/del-cycle-\(uid)")
        Acervo.register(descriptor)
        defer { Acervo.unregister(componentId) }

        // Create files (simulate download)
        try createFilesOnDisk(for: descriptor, in: tempDir)
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)

        // Delete
        try Acervo.deleteComponent(componentId, in: tempDir)
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == false)

        // Simulate re-download by creating files again
        try createFilesOnDisk(for: descriptor, in: tempDir)
        #expect(Acervo.isComponentReady(componentId, in: tempDir) == true)
    }
}
