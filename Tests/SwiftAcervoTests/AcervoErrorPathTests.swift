import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for error paths across the SwiftAcervo API surface.
///
/// Verifies that invalid inputs (malformed model IDs, nonexistent models) produce
/// the correct error cases with descriptive, non-empty error messages.
@Suite("AcervoError Path Tests")
struct AcervoErrorPathTests {

    // MARK: - Test Helpers

    /// Creates a temporary base directory for testing and returns its URL.
    private func makeTempBase() throws -> URL {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoErrorPathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        return tempBase
    }

    // MARK: - download() with invalid model IDs

    @Test("download() throws invalidModelId for model ID with no slash")
    func downloadThrowsForNoSlash() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        await #expect(throws: AcervoError.self) {
            try await Acervo.download("no-slash-model", files: ["config.json"], in: tempBase)
        }
    }

    @Test("download() throws invalidModelId for model ID with multiple slashes")
    func downloadThrowsForMultipleSlashes() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        await #expect(throws: AcervoError.self) {
            try await Acervo.download("a/b/c", files: ["config.json"], in: tempBase)
        }
    }

    @Test("download() throws invalidModelId for empty string")
    func downloadThrowsForEmptyString() async throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        await #expect(throws: AcervoError.self) {
            try await Acervo.download("", files: ["config.json"], in: tempBase)
        }
    }

    // MARK: - deleteModel() for nonexistent model

    @Test("deleteModel() throws modelNotFound for nonexistent model")
    func deleteModelThrowsForNonexistent() throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        do {
            try Acervo.deleteModel("test-org/does-not-exist", in: tempBase)
            #expect(Bool(false), "Expected deleteModel to throw modelNotFound")
        } catch let error as AcervoError {
            if case .modelNotFound(let id) = error {
                #expect(id == "test-org/does-not-exist")
            } else {
                #expect(Bool(false), "Expected modelNotFound but got \(error)")
            }
        }
    }

    @Test("deleteModel() throws invalidModelId for empty string")
    func deleteModelThrowsForEmptyString() throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        do {
            try Acervo.deleteModel("", in: tempBase)
            #expect(Bool(false), "Expected deleteModel to throw invalidModelId")
        } catch let error as AcervoError {
            if case .invalidModelId(let id) = error {
                #expect(id == "")
            } else {
                #expect(Bool(false), "Expected invalidModelId but got \(error)")
            }
        }
    }

    // MARK: - modelInfo() for nonexistent model

    @Test("modelInfo() throws modelNotFound for nonexistent model")
    func modelInfoThrowsForNonexistent() throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        do {
            let _ = try Acervo.modelInfo("test-org/ghost-model", in: tempBase)
            #expect(Bool(false), "Expected modelInfo to throw modelNotFound")
        } catch let error as AcervoError {
            if case .modelNotFound(let id) = error {
                #expect(id == "test-org/ghost-model")
            } else {
                #expect(Bool(false), "Expected modelNotFound but got \(error)")
            }
        }
    }

    @Test("modelInfo() throws modelNotFound for empty directory")
    func modelInfoThrowsForEmptyDirectory() throws {
        let tempBase = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: tempBase) }

        do {
            let _ = try Acervo.modelInfo("test-org/any-model", in: tempBase)
            #expect(Bool(false), "Expected modelInfo to throw modelNotFound")
        } catch let error as AcervoError {
            if case .modelNotFound = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected modelNotFound but got \(error)")
            }
        }
    }

    // MARK: - Error descriptions are descriptive

    @Test("invalidModelId error description contains the invalid ID")
    func invalidModelIdDescriptionContainsId() {
        let badId = "totally-wrong-format"
        let error = AcervoError.invalidModelId(badId)
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "errorDescription should not be empty")
        #expect(desc.contains(badId), "errorDescription should contain the invalid ID")
    }

    @Test("modelNotFound error description contains the model ID")
    func modelNotFoundDescriptionContainsId() {
        let modelId = "some-org/missing-model"
        let error = AcervoError.modelNotFound(modelId)
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "errorDescription should not be empty")
        #expect(desc.contains(modelId), "errorDescription should contain the model ID")
    }

    @Test("downloadFailed error description contains fileName and statusCode")
    func downloadFailedDescriptionContainsDetails() {
        let error = AcervoError.downloadFailed(fileName: "weights.bin", statusCode: 503)
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "errorDescription should not be empty")
        #expect(desc.contains("weights.bin"), "errorDescription should contain the file name")
        #expect(desc.contains("503"), "errorDescription should contain the status code")
    }

    @Test("directoryCreationFailed error description contains the path")
    func directoryCreationFailedDescriptionContainsPath() {
        let path = "/nonexistent/path/to/models"
        let error = AcervoError.directoryCreationFailed(path)
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "errorDescription should not be empty")
        #expect(desc.contains(path), "errorDescription should contain the path")
    }

    @Test("migrationFailed error description contains source and reason")
    func migrationFailedDescriptionContainsDetails() {
        let source = "/old/legacy/dir"
        let reason = "permission denied"
        let error = AcervoError.migrationFailed(source: source, reason: reason)
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "errorDescription should not be empty")
        #expect(desc.contains(source), "errorDescription should contain the source path")
        #expect(desc.contains(reason), "errorDescription should contain the failure reason")
    }

    @Test("networkError error description is non-empty")
    func networkErrorDescriptionIsNonEmpty() {
        let error = AcervoError.networkError(URLError(.timedOut))
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "networkError errorDescription should not be empty")
    }

    @Test("modelAlreadyExists error description contains the model ID")
    func modelAlreadyExistsDescriptionContainsId() {
        let modelId = "org/existing-model"
        let error = AcervoError.modelAlreadyExists(modelId)
        let desc = error.errorDescription ?? ""
        #expect(!desc.isEmpty, "errorDescription should not be empty")
        #expect(desc.contains(modelId), "errorDescription should contain the model ID")
    }
}
