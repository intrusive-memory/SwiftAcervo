import Foundation
import Testing
@testable import SwiftAcervo

@Suite("ComponentDescriptor Type Tests")
struct ComponentDescriptorTests {

    // MARK: - ComponentType

    @Test("ComponentType has exactly 7 cases")
    func componentTypeCount() {
        #expect(ComponentType.allCases.count == 7)
    }

    @Test("ComponentType cases have correct raw values")
    func componentTypeRawValues() {
        #expect(ComponentType.encoder.rawValue == "encoder")
        #expect(ComponentType.backbone.rawValue == "backbone")
        #expect(ComponentType.decoder.rawValue == "decoder")
        #expect(ComponentType.scheduler.rawValue == "scheduler")
        #expect(ComponentType.tokenizer.rawValue == "tokenizer")
        #expect(ComponentType.auxiliary.rawValue == "auxiliary")
        #expect(ComponentType.languageModel.rawValue == "languageModel")
    }

    @Test("ComponentType raw values round-trip through RawRepresentable")
    func componentTypeRoundTrip() {
        for caseValue in ComponentType.allCases {
            let raw = caseValue.rawValue
            let restored = ComponentType(rawValue: raw)
            #expect(restored == caseValue)
        }
    }

    @Test("ComponentType conforms to Codable via round-trip encode/decode")
    func componentTypeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for caseValue in ComponentType.allCases {
            let data = try encoder.encode(caseValue)
            let decoded = try decoder.decode(ComponentType.self, from: data)
            #expect(decoded == caseValue)
        }
    }

    // MARK: - ComponentFile

    @Test("ComponentFile equality compares all three properties")
    func componentFileEquality() {
        let file1 = ComponentFile(
            relativePath: "model.safetensors",
            expectedSizeBytes: 1000,
            sha256: "abc123"
        )
        let file2 = ComponentFile(
            relativePath: "model.safetensors",
            expectedSizeBytes: 1000,
            sha256: "abc123"
        )
        let file3 = ComponentFile(
            relativePath: "model.safetensors",
            expectedSizeBytes: 2000,
            sha256: "abc123"
        )
        let file4 = ComponentFile(
            relativePath: "other.safetensors",
            expectedSizeBytes: 1000,
            sha256: "abc123"
        )
        let file5 = ComponentFile(
            relativePath: "model.safetensors",
            expectedSizeBytes: 1000,
            sha256: "different"
        )

        #expect(file1 == file2)
        #expect(file1 != file3)
        #expect(file1 != file4)
        #expect(file1 != file5)
    }

    @Test("ComponentFile optional properties default to nil")
    func componentFileDefaults() {
        let file = ComponentFile(relativePath: "config.json")
        #expect(file.relativePath == "config.json")
        #expect(file.expectedSizeBytes == nil)
        #expect(file.sha256 == nil)
    }

    @Test("ComponentFile preserves all properties")
    func componentFileProperties() {
        let file = ComponentFile(
            relativePath: "speech_tokenizer/config.json",
            expectedSizeBytes: 42_000,
            sha256: "deadbeef"
        )
        #expect(file.relativePath == "speech_tokenizer/config.json")
        #expect(file.expectedSizeBytes == 42_000)
        #expect(file.sha256 == "deadbeef")
    }

    // MARK: - ComponentDescriptor

    @Test("ComponentDescriptor equality compares by id only")
    func descriptorEqualityById() {
        let desc1 = makeDescriptor(id: "comp-1", displayName: "First Name")
        let desc2 = makeDescriptor(id: "comp-1", displayName: "Different Name")
        let desc3 = makeDescriptor(id: "comp-2", displayName: "First Name")

        #expect(desc1 == desc2, "Same id should be equal regardless of displayName")
        #expect(desc1 != desc3, "Different id should not be equal")
    }

    @Test("ComponentDescriptor conforms to Identifiable")
    func descriptorIdentifiable() {
        let desc = makeDescriptor(id: "test-component")
        #expect(desc.id == "test-component")
    }

    @Test("ComponentDescriptor preserves all properties")
    func descriptorProperties() {
        let files = [
            ComponentFile(relativePath: "model.safetensors", expectedSizeBytes: 300_000_000, sha256: "abc"),
            ComponentFile(relativePath: "config.json", expectedSizeBytes: 1024),
        ]
        let metadata = ["quantization": "int4", "architecture": "dit"]

        let desc = ComponentDescriptor(
            id: "pixart-dit-int4",
            type: .backbone,
            displayName: "PixArt DiT (int4)",
            huggingFaceRepo: "intrusive-memory/pixart-dit-int4-mlx",
            files: files,
            estimatedSizeBytes: 300_001_024,
            minimumMemoryBytes: 600_000_000,
            metadata: metadata
        )

        #expect(desc.id == "pixart-dit-int4")
        #expect(desc.type == .backbone)
        #expect(desc.displayName == "PixArt DiT (int4)")
        #expect(desc.huggingFaceRepo == "intrusive-memory/pixart-dit-int4-mlx")
        #expect(desc.files.count == 2)
        #expect(desc.estimatedSizeBytes == 300_001_024)
        #expect(desc.minimumMemoryBytes == 600_000_000)
        #expect(desc.metadata["quantization"] == "int4")
        #expect(desc.metadata["architecture"] == "dit")
    }

    @Test("ComponentDescriptor metadata defaults to empty dictionary")
    func descriptorMetadataDefault() {
        let desc = makeDescriptor(id: "test")
        #expect(desc.metadata.isEmpty)
    }

    @Test("ComponentDescriptor is Hashable consistent with Equatable")
    func descriptorHashable() {
        let desc1 = makeDescriptor(id: "same-id", displayName: "Name A")
        let desc2 = makeDescriptor(id: "same-id", displayName: "Name B")

        // Equal descriptors must have equal hash values
        #expect(desc1.hashValue == desc2.hashValue)

        // Can be used as Set elements
        var set = Set<ComponentDescriptor>()
        set.insert(desc1)
        set.insert(desc2)
        #expect(set.count == 1)
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
