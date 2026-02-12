import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for Acervo availability checks: isModelAvailable() and modelFileExists().
///
/// These tests create temporary directories that mimic the SharedModels structure
/// to verify file presence detection without touching real model storage.
struct AcervoAvailabilityTests {

    // MARK: - Test Helpers

    /// Creates a temporary directory and returns its URL. The caller is responsible
    /// for cleanup, which is handled by the `cleanup` closure returned alongside.
    private func makeTempModelDirectory(
        slug: String,
        files: [String] = []
    ) throws -> (url: URL, cleanup: () -> Void) {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoAvailabilityTests-\(UUID().uuidString)")
        let modelDir = tempBase.appendingPathComponent(slug)

        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )

        for file in files {
            let fileURL = modelDir.appendingPathComponent(file)
            // Create intermediate directories if the file path contains subdirectories
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
            try Data().write(to: fileURL)
        }

        let cleanup: () -> Void = {
            _ = try? FileManager.default.removeItem(at: tempBase)
        }

        return (modelDir, cleanup)
    }

    // MARK: - isModelAvailable

    @Test("isModelAvailable returns false for nonexistent model")
    func isModelAvailableNonexistent() {
        let result = Acervo.isModelAvailable("nonexistent-org/nonexistent-model-\(UUID().uuidString)")
        #expect(result == false)
    }

    @Test("isModelAvailable returns false when directory exists but no config.json")
    func isModelAvailableNoConfig() throws {
        // Create a model directory without config.json in the real SharedModels location
        let testModelId = "test-org/no-config-\(UUID().uuidString)"
        let dir = try Acervo.modelDirectory(for: testModelId)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Acervo.isModelAvailable(testModelId) == false)
    }

    @Test("isModelAvailable returns true when config.json is present")
    func isModelAvailableWithConfig() throws {
        let testModelId = "test-org/with-config-\(UUID().uuidString)"
        let dir = try Acervo.modelDirectory(for: testModelId)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Acervo.isModelAvailable(testModelId) == true)
    }

    @Test("isModelAvailable returns false for invalid model ID")
    func isModelAvailableInvalidId() {
        #expect(Acervo.isModelAvailable("no-slash") == false)
    }

    // MARK: - modelFileExists

    @Test("modelFileExists returns false for nonexistent model")
    func modelFileExistsNonexistent() {
        let result = Acervo.modelFileExists(
            "nonexistent-org/nonexistent-model-\(UUID().uuidString)",
            fileName: "config.json"
        )
        #expect(result == false)
    }

    @Test("modelFileExists returns true for root-level file")
    func modelFileExistsRootFile() throws {
        let testModelId = "test-org/root-file-\(UUID().uuidString)"
        let dir = try Acervo.modelDirectory(for: testModelId)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tokenizer = dir.appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: tokenizer)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Acervo.modelFileExists(testModelId, fileName: "tokenizer.json") == true)
    }

    @Test("modelFileExists returns false for missing root-level file")
    func modelFileExistsMissingRootFile() throws {
        let testModelId = "test-org/missing-file-\(UUID().uuidString)"
        let dir = try Acervo.modelDirectory(for: testModelId)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Acervo.modelFileExists(testModelId, fileName: "nonexistent.json") == false)
    }

    @Test("modelFileExists returns true for subdirectory file")
    func modelFileExistsSubdirectoryFile() throws {
        let testModelId = "test-org/subdir-file-\(UUID().uuidString)"
        let dir = try Acervo.modelDirectory(for: testModelId)

        let subdirURL = dir.appendingPathComponent("speech_tokenizer")
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        let configURL = subdirURL.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configURL)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Acervo.modelFileExists(testModelId, fileName: "speech_tokenizer/config.json") == true)
    }

    @Test("modelFileExists returns false for missing subdirectory file")
    func modelFileExistsMissingSubdirFile() throws {
        let testModelId = "test-org/missing-subdir-\(UUID().uuidString)"
        let dir = try Acervo.modelDirectory(for: testModelId)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(Acervo.modelFileExists(testModelId, fileName: "speech_tokenizer/config.json") == false)
    }

    @Test("modelFileExists returns false for invalid model ID")
    func modelFileExistsInvalidId() {
        #expect(Acervo.modelFileExists("invalid", fileName: "config.json") == false)
    }
}
