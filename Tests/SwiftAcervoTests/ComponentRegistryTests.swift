import Foundation
import Testing
@testable import SwiftAcervo

@Suite("ComponentRegistry Tests")
struct ComponentRegistryTests {

    /// Creates a fresh registry for each test to avoid shared state.
    private func makeRegistry() -> ComponentRegistry {
        ComponentRegistry()
    }

    // MARK: - Registration

    @Test("Register a descriptor then retrieve it by ID")
    func registerAndRetrieve() {
        let registry = makeRegistry()
        let desc = makeDescriptor(id: "comp-1")

        registry.register(desc)

        let result = registry.component("comp-1")
        #expect(result != nil)
        #expect(result?.id == "comp-1")
        #expect(result?.displayName == desc.displayName)
    }

    @Test("Register multiple descriptors at once")
    func registerMultiple() {
        let registry = makeRegistry()
        let descriptors = [
            makeDescriptor(id: "comp-1"),
            makeDescriptor(id: "comp-2"),
            makeDescriptor(id: "comp-3"),
        ]

        registry.register(descriptors)

        #expect(registry.allComponents().count == 3)
    }

    @Test("Component returns nil for unregistered ID")
    func componentReturnsNilForUnknown() {
        let registry = makeRegistry()
        #expect(registry.component("nonexistent") == nil)
    }

    // MARK: - Deduplication

    @Test("Same ID with identical repo and files deduplicates silently")
    func deduplicateSameRepoAndFiles() {
        let registry = makeRegistry()
        let files = [ComponentFile(relativePath: "model.safetensors")]

        let desc1 = makeDescriptor(
            id: "comp-1",
            displayName: "First",
            huggingFaceRepo: "org/repo",
            files: files
        )
        let desc2 = makeDescriptor(
            id: "comp-1",
            displayName: "Second",
            huggingFaceRepo: "org/repo",
            files: files
        )

        registry.register(desc1)
        registry.register(desc2)

        #expect(registry.allComponents().count == 1)
        // Last registration wins for non-merged fields
        #expect(registry.component("comp-1")?.displayName == "Second")
    }

    @Test("Same ID with different repo: last registration wins")
    func deduplicateDifferentRepo() {
        let registry = makeRegistry()

        let desc1 = makeDescriptor(
            id: "comp-1",
            huggingFaceRepo: "org/repo-v1"
        )
        let desc2 = makeDescriptor(
            id: "comp-1",
            huggingFaceRepo: "org/repo-v2"
        )

        registry.register(desc1)
        registry.register(desc2)

        #expect(registry.allComponents().count == 1)
        #expect(registry.component("comp-1")?.huggingFaceRepo == "org/repo-v2")
    }

    @Test("Metadata merge: newer keys overwrite, older keys preserved")
    func metadataMerge() {
        let registry = makeRegistry()

        let desc1 = makeDescriptor(
            id: "comp-1",
            metadata: ["a": "1", "shared": "old"]
        )
        let desc2 = makeDescriptor(
            id: "comp-1",
            metadata: ["b": "2", "shared": "new"]
        )

        registry.register(desc1)
        registry.register(desc2)

        let result = registry.component("comp-1")!
        #expect(result.metadata["a"] == "1", "Key from first registration should be preserved")
        #expect(result.metadata["b"] == "2", "Key from second registration should be added")
        #expect(result.metadata["shared"] == "new", "Conflicting key should use newer value")
    }

    @Test("estimatedSizeBytes takes max of both registrations")
    func estimatedSizeTakesMax() {
        let registry = makeRegistry()

        let desc1 = makeDescriptor(id: "comp-1", estimatedSizeBytes: 100)
        let desc2 = makeDescriptor(id: "comp-1", estimatedSizeBytes: 200)

        registry.register(desc1)
        registry.register(desc2)

        #expect(registry.component("comp-1")?.estimatedSizeBytes == 200)
    }

    @Test("minimumMemoryBytes takes max of both registrations")
    func minimumMemoryTakesMax() {
        let registry = makeRegistry()

        let desc1 = makeDescriptor(id: "comp-1", minimumMemoryBytes: 500)
        let desc2 = makeDescriptor(id: "comp-1", minimumMemoryBytes: 300)

        registry.register(desc1)
        registry.register(desc2)

        // Max of 500 and 300 is 500
        #expect(registry.component("comp-1")?.minimumMemoryBytes == 500)
    }

    // MARK: - Unregistration

    @Test("Unregister removes entry from registry")
    func unregisterRemovesEntry() {
        let registry = makeRegistry()
        registry.register(makeDescriptor(id: "comp-1"))

        registry.unregister("comp-1")

        #expect(registry.component("comp-1") == nil)
        #expect(registry.allComponents().isEmpty)
    }

    @Test("Unregister nonexistent ID is a no-op")
    func unregisterNonexistentIsNoop() {
        let registry = makeRegistry()
        registry.register(makeDescriptor(id: "comp-1"))

        registry.unregister("nonexistent")

        #expect(registry.allComponents().count == 1)
    }

    // MARK: - Queries

    @Test("allComponents returns all registered descriptors")
    func allComponentsReturnsAll() {
        let registry = makeRegistry()
        registry.register(makeDescriptor(id: "comp-1"))
        registry.register(makeDescriptor(id: "comp-2"))
        registry.register(makeDescriptor(id: "comp-3"))

        let all = registry.allComponents()
        #expect(all.count == 3)

        let ids = Set(all.map(\.id))
        #expect(ids.contains("comp-1"))
        #expect(ids.contains("comp-2"))
        #expect(ids.contains("comp-3"))
    }

    @Test("components(ofType:) filters by type correctly")
    func componentsOfTypeFilters() {
        let registry = makeRegistry()
        registry.register(makeDescriptor(id: "enc-1", type: .encoder))
        registry.register(makeDescriptor(id: "enc-2", type: .encoder))
        registry.register(makeDescriptor(id: "dec-1", type: .decoder))

        let encoders = registry.components(ofType: .encoder)
        let decoders = registry.components(ofType: .decoder)
        let backbones = registry.components(ofType: .backbone)

        #expect(encoders.count == 2)
        #expect(decoders.count == 1)
        #expect(backbones.count == 0)
    }

    // MARK: - removeAll

    @Test("removeAll empties the registry")
    func removeAllEmptiesRegistry() {
        let registry = makeRegistry()
        registry.register(makeDescriptor(id: "comp-1"))
        registry.register(makeDescriptor(id: "comp-2"))
        registry.register(makeDescriptor(id: "comp-3"))

        registry.removeAll()

        #expect(registry.allComponents().isEmpty)
    }

    // MARK: - Thread Safety

    @Test("Concurrent register and unregister from many tasks does not crash")
    func threadSafetyConcurrentAccess() async {
        let registry = makeRegistry()

        await withTaskGroup(of: Void.self) { group in
            // Launch 100 concurrent tasks that register and unregister
            for i in 0..<100 {
                group.addTask {
                    let desc = makeDescriptor(id: "concurrent-\(i)")
                    registry.register(desc)
                    _ = registry.allComponents()
                    _ = registry.component("concurrent-\(i)")
                    _ = registry.components(ofType: .encoder)
                    registry.unregister("concurrent-\(i)")
                }
            }
        }

        // Registry should be empty after all unregistrations
        // (all tasks registered then unregistered their own entry)
        #expect(registry.allComponents().isEmpty)
    }

    @Test("Concurrent registrations of same ID converge to one entry")
    func threadSafetySameId() async {
        let registry = makeRegistry()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let desc = makeDescriptor(
                        id: "shared-id",
                        displayName: "Variant \(i)"
                    )
                    registry.register(desc)
                }
            }
        }

        // Despite 50 registrations, there should be exactly one entry
        #expect(registry.allComponents().count == 1)
        #expect(registry.component("shared-id") != nil)
    }

    // MARK: - Public API (Acervo static methods)

    @Test("Acervo.register and Acervo.unregister delegate to shared registry")
    func acervoStaticRegistration() {
        // Clean up shared registry state
        ComponentRegistry.shared.removeAll()

        let desc = makeDescriptor(id: "api-test-component")
        Acervo.register(desc)

        #expect(ComponentRegistry.shared.component("api-test-component") != nil)

        Acervo.unregister("api-test-component")

        #expect(ComponentRegistry.shared.component("api-test-component") == nil)

        // Clean up
        ComponentRegistry.shared.removeAll()
    }

    @Test("Acervo.register array delegates to shared registry")
    func acervoStaticRegistrationArray() {
        ComponentRegistry.shared.removeAll()

        let descriptors = [
            makeDescriptor(id: "batch-1"),
            makeDescriptor(id: "batch-2"),
        ]
        Acervo.register(descriptors)

        #expect(ComponentRegistry.shared.allComponents().count == 2)

        // Clean up
        ComponentRegistry.shared.removeAll()
    }

    // MARK: - Helpers

    /// Creates a minimal ComponentDescriptor for testing.
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
}

// Module-level helper used by concurrent tasks (must not capture self)
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
