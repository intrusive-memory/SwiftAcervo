import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for the public download API: Acervo.download(), Acervo.ensureAvailable(),
/// and Acervo.deleteModel().
///
/// These tests use temporary directories and the internal overloads that accept
/// a base directory parameter to avoid touching the real SharedModels directory.
/// Full integration tests with real HuggingFace downloads are in Sprint 14.
struct AcervoDownloadAPITests {

    // MARK: - Test Helpers

    /// Creates a temporary base directory for testing and returns its URL.
    private func makeTempBase() throws -> URL {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloadAPITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        return tempBase
    }

    /// Creates a fake model directory with config.json in the given base directory.
    private func createFakeModel(
        modelId: String,
        in baseDirectory: URL,
        files: [String] = ["config.json"]
    ) throws {
        let slug = Acervo.slugify(modelId)
        let modelDir = baseDirectory.appendingPathComponent(slug)
        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        for file in files {
            let fileURL = modelDir.appendingPathComponent(file)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: fileURL)
        }
    }

    // MARK: - download() Model ID Validation

    @Test("download() throws invalidModelId for ID with no slash")
    func downloadThrowsForNoSlash() async {
        do {
            try await Acervo.download(
                "no-slash-model",
                files: ["config.json"],
                in: FileManager.default.temporaryDirectory
            )
            #expect(Bool(false), "Expected download to throw invalidModelId")
        } catch let error as AcervoError {
            if case .invalidModelId(let id) = error {
                #expect(id == "no-slash-model")
            } else {
                #expect(Bool(false), "Expected invalidModelId but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    @Test("download() throws invalidModelId for ID with multiple slashes")
    func downloadThrowsForMultipleSlashes() async {
        do {
            try await Acervo.download(
                "org/sub/model",
                files: ["config.json"],
                in: FileManager.default.temporaryDirectory
            )
            #expect(Bool(false), "Expected download to throw invalidModelId")
        } catch let error as AcervoError {
            if case .invalidModelId(let id) = error {
                #expect(id == "org/sub/model")
            } else {
                #expect(Bool(false), "Expected invalidModelId but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    @Test("download() throws invalidModelId for empty string")
    func downloadThrowsForEmptyString() async {
        do {
            try await Acervo.download(
                "",
                files: ["config.json"],
                in: FileManager.default.temporaryDirectory
            )
            #expect(Bool(false), "Expected download to throw invalidModelId")
        } catch let error as AcervoError {
            if case .invalidModelId = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected invalidModelId but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    // MARK: - download() Directory Creation

    @Test("download() creates model directory")
    func downloadCreatesDirectory() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let modelId = "test-org/test-model"
        let slug = Acervo.slugify(modelId)
        let expectedDir = tempBase.appendingPathComponent(slug)

        // Directory should not exist yet
        #expect(!FileManager.default.fileExists(atPath: expectedDir.path))

        // download() will create the directory, then attempt to download.
        // The download will fail (network error) because the model doesn't exist,
        // but the directory should have been created before the download attempt.
        do {
            try await Acervo.download(
                modelId,
                files: ["config.json"],
                in: tempBase
            )
        } catch {
            // Network error expected -- that's fine for this test
        }

        // Directory should have been created
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: expectedDir.path,
            isDirectory: &isDirectory
        )
        #expect(exists, "download() should create the model directory")
        #expect(isDirectory.boolValue, "Created path should be a directory")
    }

    @Test("download() with valid model ID and pre-existing files succeeds")
    func downloadWithExistingFilesSucceeds() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Pre-create the model directory with config.json so download skips it
        try createFakeModel(modelId: "test-org/existing-model", in: tempBase)

        // download() with force=false should skip existing files
        try await Acervo.download(
            "test-org/existing-model",
            files: ["config.json"],
            force: false,
            in: tempBase
        )

        // Verify file still exists
        let configPath = tempBase
            .appendingPathComponent("test-org_existing-model")
            .appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configPath.path))
    }

    // MARK: - ensureAvailable() Skip Logic

    @Test("ensureAvailable() skips download when model already has config.json")
    func ensureAvailableSkipsExistingModel() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let modelId = "test-org/already-available"

        // Create fake model with config.json
        try createFakeModel(modelId: modelId, in: tempBase)

        // Write known content so we can verify it's unchanged
        let configURL = tempBase
            .appendingPathComponent(Acervo.slugify(modelId))
            .appendingPathComponent("config.json")
        let knownContent = "{\"test\": \"original_content\"}"
        try knownContent.write(to: configURL, atomically: true, encoding: .utf8)

        // ensureAvailable() should return without downloading
        // (if it tried to download, it would fail with a network error
        // for this fake model ID, or it would overwrite the content)
        try await Acervo.ensureAvailable(
            modelId,
            files: ["config.json"],
            in: tempBase
        )

        // Verify the file content is unchanged (no download occurred)
        let afterContent = try String(contentsOf: configURL, encoding: .utf8)
        #expect(afterContent == knownContent,
                "ensureAvailable should not modify existing model files")
    }

    @Test("ensureAvailable() validates model ID")
    func ensureAvailableValidatesModelId() async {
        do {
            try await Acervo.ensureAvailable(
                "invalid-no-slash",
                files: ["config.json"],
                in: FileManager.default.temporaryDirectory
            )
            #expect(Bool(false), "Expected ensureAvailable to throw invalidModelId")
        } catch let error as AcervoError {
            if case .invalidModelId = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected invalidModelId but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    @Test("ensureAvailable() attempts download when model is missing")
    func ensureAvailableDownloadsWhenMissing() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let modelId = "test-org/missing-model"

        // Model directory does not exist -- ensureAvailable should attempt download.
        // Since this is a fake model, the download will fail with a network error.
        var downloadAttempted = false
        do {
            try await Acervo.ensureAvailable(
                modelId,
                files: ["config.json"],
                in: tempBase
            )
        } catch {
            // Any error (networkError or downloadFailed) proves the download was attempted
            downloadAttempted = true
        }
        #expect(downloadAttempted,
                "ensureAvailable should attempt download when model is missing")
    }

    @Test("isModelAvailable internal overload detects model in custom directory")
    func isModelAvailableInternalOverload() throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        let modelId = "test-org/custom-dir-model"

        // Model not yet created
        #expect(!Acervo.isModelAvailable(modelId, in: tempBase))

        // Create fake model
        try createFakeModel(modelId: modelId, in: tempBase)

        // Now it should be available
        #expect(Acervo.isModelAvailable(modelId, in: tempBase))
    }
}
