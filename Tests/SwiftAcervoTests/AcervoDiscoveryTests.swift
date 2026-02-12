import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for Acervo model discovery: listModels() and modelInfo().
///
/// All tests use temporary directories for isolation, ensuring no interaction
/// with the real SharedModels directory.
struct AcervoDiscoveryTests {

    // MARK: - Test Helpers

    /// Creates a temporary base directory for test model directories.
    /// Returns the base URL and a cleanup closure.
    private func makeTempBase() throws -> (url: URL, cleanup: @Sendable () -> Void) {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let cleanup: @Sendable () -> Void = {
            _ = try? FileManager.default.removeItem(at: tempBase)
        }
        return (tempBase, cleanup)
    }

    /// Creates a model directory with an optional config.json and optional extra files
    /// inside the given base directory.
    private func createModelDir(
        in base: URL,
        slug: String,
        withConfig: Bool = true,
        extraFiles: [String: Data] = [:]
    ) throws -> URL {
        let modelDir = base.appendingPathComponent(slug)
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

    // MARK: - listModels() Tests

    @Test("listModels returns empty array for empty directory")
    func listModelsEmptyDirectory() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let models = try Acervo.listModels(in: base)
        #expect(models.isEmpty)
    }

    @Test("listModels returns empty array for nonexistent directory")
    func listModelsNonexistentDirectory() throws {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let models = try Acervo.listModels(in: nonexistent)
        #expect(models.isEmpty)
    }

    @Test("listModels finds model with config.json")
    func listModelsFindsValidModel() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        _ = try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 1)
        #expect(models[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("listModels skips directory without config.json")
    func listModelsSkipsNoConfig() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        _ = try createModelDir(in: base, slug: "mlx-community_incomplete-model", withConfig: false)

        let models = try Acervo.listModels(in: base)
        #expect(models.isEmpty)
    }

    @Test("listModels skips directory without underscore in name")
    func listModelsSkipsNoUnderscore() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Directory name without underscore can't be reverse-slugified
        let oddDir = base.appendingPathComponent("no-underscore-here")
        try FileManager.default.createDirectory(at: oddDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: oddDir.appendingPathComponent("config.json"))

        let models = try Acervo.listModels(in: base)
        #expect(models.isEmpty)
    }

    @Test("listModels returns multiple models sorted by ID")
    func listModelsMultipleModels() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        _ = try createModelDir(in: base, slug: "org_zebra-model")
        _ = try createModelDir(in: base, slug: "org_alpha-model")
        _ = try createModelDir(in: base, slug: "org_middle-model")

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 3)
        #expect(models[0].id == "org/alpha-model")
        #expect(models[1].id == "org/middle-model")
        #expect(models[2].id == "org/zebra-model")
    }

    @Test("listModels model path is correct")
    func listModelsPathCorrect() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        _ = try createModelDir(in: base, slug: "org_my-model")

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 1)
        // Compare last path component to avoid /private/var vs /var symlink issues
        #expect(models[0].path.lastPathComponent == "org_my-model")
        #expect(models[0].path.path.contains("org_my-model"))
    }

    @Test("listModels model size includes all files")
    func listModelsSize() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // config.json is 2 bytes ("{}"), extra file is 10 bytes
        let extraData = Data(repeating: 0x41, count: 10)
        _ = try createModelDir(
            in: base,
            slug: "org_sized-model",
            extraFiles: ["model.bin": extraData]
        )

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 1)
        // config.json ("{}" = 2 bytes) + model.bin (10 bytes) = 12 bytes
        #expect(models[0].sizeBytes == 12)
    }

    @Test("listModels model has a valid download date")
    func listModelsDate() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let beforeCreation = Date()
        _ = try createModelDir(in: base, slug: "org_dated-model")

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 1)
        // Download date should be on or after the time we created the directory
        #expect(models[0].downloadDate >= beforeCreation.addingTimeInterval(-1))
    }

    @Test("listModels skips regular files in base directory")
    func listModelsSkipsFiles() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Create a regular file (not a directory) in the base
        let fileURL = base.appendingPathComponent("org_not-a-dir")
        try Data("hello".utf8).write(to: fileURL)

        // Also add a valid model
        _ = try createModelDir(in: base, slug: "org_real-model")

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 1)
        #expect(models[0].id == "org/real-model")
    }

    @Test("listModels includes models with subdirectory files in size calculation")
    func listModelsSizeWithSubdirectory() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let subData = Data(repeating: 0x42, count: 20)
        _ = try createModelDir(
            in: base,
            slug: "org_sub-model",
            extraFiles: ["speech_tokenizer/model.bin": subData]
        )

        let models = try Acervo.listModels(in: base)
        #expect(models.count == 1)
        // config.json (2 bytes) + speech_tokenizer/model.bin (20 bytes) = 22 bytes
        #expect(models[0].sizeBytes == 22)
    }
}
