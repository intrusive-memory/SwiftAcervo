import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for Acervo.migrateFromLegacyPaths().
///
/// All tests use temporary directories for isolation, ensuring no interaction
/// with the real SharedModels directory or legacy cache paths.
struct AcervoMigrationTests {

    // MARK: - Test Helpers

    /// Creates a temporary base directory for legacy model directories.
    /// Returns the legacy base URL, shared base URL, and a cleanup closure.
    private func makeTempBases() throws -> (
        legacyBase: URL,
        sharedBase: URL,
        cleanup: @Sendable () -> Void
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoMigrationTests-\(UUID().uuidString)")
        let legacyBase = root.appendingPathComponent("Library/Caches/intrusive-memory/Models")
        let sharedBase = root.appendingPathComponent("Library/SharedModels")

        try FileManager.default.createDirectory(
            at: legacyBase,
            withIntermediateDirectories: true
        )

        let cleanup: @Sendable () -> Void = {
            _ = try? FileManager.default.removeItem(at: root)
        }
        return (legacyBase, sharedBase, cleanup)
    }

    /// Creates a model directory inside a legacy subdirectory.
    ///
    /// - Parameters:
    ///   - legacyBase: The legacy base directory.
    ///   - subdirectory: The legacy subdirectory (e.g., "LLM", "TTS").
    ///   - slug: The model directory name (slug form).
    ///   - withConfig: Whether to include config.json.
    ///   - extraFiles: Additional files to create.
    /// - Returns: The URL of the created model directory.
    @discardableResult
    private func createLegacyModel(
        in legacyBase: URL,
        subdirectory: String,
        slug: String,
        withConfig: Bool = true,
        extraFiles: [String: Data] = [:]
    ) throws -> URL {
        let subdirURL = legacyBase.appendingPathComponent(subdirectory)
        let modelDir = subdirURL.appendingPathComponent(slug)
        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )

        if withConfig {
            let configURL = modelDir.appendingPathComponent("config.json")
            try Data("{}".utf8).write(to: configURL)
        }

        for (name, data) in extraFiles {
            let fileURL = modelDir.appendingPathComponent(name)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        }

        return modelDir
    }

    /// Creates a model directory in the shared base.
    @discardableResult
    private func createSharedModel(
        in sharedBase: URL,
        slug: String
    ) throws -> URL {
        let modelDir = sharedBase.appendingPathComponent(slug)
        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        let configURL = modelDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configURL)
        return modelDir
    }

    // MARK: - Empty Directory Tests

    @Test("migrateFromLegacyPaths returns empty array when no legacy directories exist")
    func migrateEmptyLegacyBase() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )
        #expect(migrated.isEmpty)
    }

    @Test("migrateFromLegacyPaths returns empty array when legacy subdirectories are empty")
    func migrateEmptySubdirectories() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        // Create the four legacy subdirectories but leave them empty
        for subdir in AcervoMigration.legacySubdirectories {
            let subdirURL = legacyBase.appendingPathComponent(subdir)
            try FileManager.default.createDirectory(
                at: subdirURL,
                withIntermediateDirectories: true
            )
        }

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )
        #expect(migrated.isEmpty)
    }

    @Test("migrateFromLegacyPaths returns empty when nonexistent legacy base")
    func migrateNonexistentLegacyBase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoMigrationTests-nonexistent-\(UUID().uuidString)")
        let legacyBase = root.appendingPathComponent("does-not-exist")
        let sharedBase = root.appendingPathComponent("shared")
        defer { _ = try? FileManager.default.removeItem(at: root) }

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )
        #expect(migrated.isEmpty)
    }

    // MARK: - Valid Model Migration Tests

    @Test("migrateFromLegacyPaths moves model from legacy LLM directory")
    func migrateLLMModel() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: "mlx-community_Qwen2.5-7B-Instruct-4bit"
        )

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        #expect(migrated.count == 1)
        #expect(migrated[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")

        // Verify the model directory exists in the shared location
        let destPath = sharedBase
            .appendingPathComponent("mlx-community_Qwen2.5-7B-Instruct-4bit")
        #expect(FileManager.default.fileExists(atPath: destPath.path))

        // Verify config.json exists at destination
        let configPath = destPath.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configPath.path))
    }

    @Test("migrateFromLegacyPaths moves model from legacy TTS directory")
    func migrateTTSModel() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        try createLegacyModel(
            in: legacyBase,
            subdirectory: "TTS",
            slug: "mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16"
        )

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        #expect(migrated.count == 1)
        #expect(migrated[0].id == "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")

        // Verify model moved to shared location
        let destPath = sharedBase
            .appendingPathComponent("mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16")
        #expect(FileManager.default.fileExists(atPath: destPath.path))
    }

    @Test("migrateFromLegacyPaths skips model already in SharedModels")
    func migrateSkipsExistingModel() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        let slug = "mlx-community_existing-model"

        // Create the model in both legacy and shared locations
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: slug
        )
        try createSharedModel(in: sharedBase, slug: slug)

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        // Should skip the model since it already exists in shared
        #expect(migrated.isEmpty)

        // Legacy directory should still exist (was not moved)
        let legacyPath = legacyBase
            .appendingPathComponent("LLM")
            .appendingPathComponent(slug)
        #expect(FileManager.default.fileExists(atPath: legacyPath.path))
    }

    @Test("migrateFromLegacyPaths handles missing config.json")
    func migrateSkipsMissingConfig() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        // Create a directory without config.json
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: "mlx-community_incomplete-model",
            withConfig: false
        )

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        #expect(migrated.isEmpty)
    }

    @Test("migrateFromLegacyPaths returns correct AcervoModel list")
    func migrateReturnsCorrectModels() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        let extraData = Data(repeating: 0x41, count: 50)

        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: "org_model-a",
            extraFiles: ["weights.bin": extraData]
        )
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "TTS",
            slug: "org_model-b"
        )

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        #expect(migrated.count == 2)

        // Check model IDs (order depends on subdirectory scan order: LLM first)
        let ids = migrated.map(\.id)
        #expect(ids.contains("org/model-a"))
        #expect(ids.contains("org/model-b"))

        // Check that model-a has the correct size (config.json 2 bytes + weights.bin 50 bytes)
        if let modelA = migrated.first(where: { $0.id == "org/model-a" }) {
            #expect(modelA.sizeBytes == 52)
        }
    }

    @Test("migrateFromLegacyPaths scans all four subdirectories")
    func migrateScansAllSubdirectories() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        // Create one model in each subdirectory
        try createLegacyModel(in: legacyBase, subdirectory: "LLM", slug: "org_llm-model")
        try createLegacyModel(in: legacyBase, subdirectory: "TTS", slug: "org_tts-model")
        try createLegacyModel(in: legacyBase, subdirectory: "Audio", slug: "org_audio-model")
        try createLegacyModel(in: legacyBase, subdirectory: "VLM", slug: "org_vlm-model")

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        #expect(migrated.count == 4)

        let ids = migrated.map(\.id)
        #expect(ids.contains("org/llm-model"))
        #expect(ids.contains("org/tts-model"))
        #expect(ids.contains("org/audio-model"))
        #expect(ids.contains("org/vlm-model"))
    }

    @Test("migrateFromLegacyPaths does not delete old parent directories")
    func migratePreservesParentDirectories() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: "org_moved-model"
        )

        _ = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        // The LLM directory itself should still exist
        let llmDir = legacyBase.appendingPathComponent("LLM")
        #expect(FileManager.default.fileExists(atPath: llmDir.path))

        // The legacy base should still exist
        #expect(FileManager.default.fileExists(atPath: legacyBase.path))
    }

    // MARK: - Error Handling Tests

    @Test("migrateFromLegacyPaths handles unreadable directories gracefully")
    func migrateHandlesUnreadableDirectories() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        // Create an LLM directory with a valid model
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: "org_good-model"
        )

        // Create an Audio subdirectory but make it unreadable
        let audioDir = legacyBase.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(
            at: audioDir,
            withIntermediateDirectories: true
        )
        // Put a model inside before restricting access
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "Audio",
            slug: "org_audio-model"
        )
        // Restrict permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: audioDir.path
        )

        // Restore permissions in cleanup
        defer {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: audioDir.path
            )
        }

        // Should still succeed for LLM, skipping the unreadable Audio directory
        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        // At minimum, the LLM model should have been migrated
        let ids = migrated.map(\.id)
        #expect(ids.contains("org/good-model"))
    }

    @Test("migrateFromLegacyPaths handles partial success")
    func migratePartialSuccess() throws {
        let (legacyBase, sharedBase, cleanup) = try makeTempBases()
        defer { cleanup() }

        // Create a model in LLM (will succeed)
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "LLM",
            slug: "org_first-model"
        )

        // Create a model in TTS that already exists in shared (will be skipped)
        let existingSlug = "org_already-there"
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "TTS",
            slug: existingSlug
        )
        try createSharedModel(in: sharedBase, slug: existingSlug)

        // Create a model in VLM without config (will be skipped)
        try createLegacyModel(
            in: legacyBase,
            subdirectory: "VLM",
            slug: "org_no-config",
            withConfig: false
        )

        let migrated = try Acervo.migrateFromLegacyPaths(
            legacyBase: legacyBase,
            sharedBase: sharedBase
        )

        // Only the LLM model should be migrated
        #expect(migrated.count == 1)
        #expect(migrated[0].id == "org/first-model")
    }
}
