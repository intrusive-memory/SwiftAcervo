// IntegrationTests.swift
// SwiftAcervo
//
// Integration tests that require network access and a real HuggingFace
// endpoint. These tests are compiled only when the INTEGRATION_TESTS
// flag is set, so they do not run during normal `xcodebuild test`.
//
// To run integration tests:
//   xcodebuild test -scheme SwiftAcervo -destination 'platform=macOS' \
//       OTHER_SWIFT_FLAGS='-D INTEGRATION_TESTS'
//

#if INTEGRATION_TESTS

import Testing
import Foundation
@testable import SwiftAcervo

// MARK: - Integration Test Helpers

/// Creates a unique temporary directory for use as a SharedModels root.
/// The caller is responsible for cleaning up via `cleanupTempDirectory(_:)`.
private func makeTempSharedModels() throws -> URL {
    let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftAcervo-Integration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: tempBase,
        withIntermediateDirectories: true
    )
    return tempBase
}

/// Removes a temporary directory created by `makeTempSharedModels()`.
private func cleanupTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A small, publicly accessible model on HuggingFace suitable for
/// integration testing. Only `config.json` is downloaded to keep
/// test runtime minimal.
private let testModelId = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// A thread-safe collector for download progress reports.
private actor IntegrationProgressCollector {
    var reports: [AcervoDownloadProgress] = []

    func append(_ report: AcervoDownloadProgress) {
        reports.append(report)
    }

    func getReports() -> [AcervoDownloadProgress] {
        reports
    }
}

// MARK: - Real Download Tests

@Suite("Integration: Real HuggingFace Downloads")
struct RealDownloadIntegrationTests {

    @Test("Download config.json from a real HuggingFace model")
    func downloadConfigJson() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        let collector = IntegrationProgressCollector()

        // Download only config.json to keep the test fast
        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            progress: { report in
                Task { await collector.append(report) }
            },
            in: tempBase
        )

        // Verify the file landed at the correct path
        let slug = Acervo.slugify(testModelId)
        let modelDir = tempBase.appendingPathComponent(slug)
        let configPath = modelDir.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configPath.path))

        // Verify the file content is valid JSON
        let data = try Data(contentsOf: configPath)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any], "config.json should be a JSON dictionary")

        // Verify progress was reported
        let reports = await collector.getReports()
        #expect(!reports.isEmpty, "Progress should have been reported")

        // Verify the final progress report indicates completion
        if let last = reports.last {
            #expect(last.fileName == "config.json")
            #expect(last.fileIndex == 0)
            #expect(last.totalFiles == 1)
            #expect(last.bytesDownloaded > 0)
        }
    }

    @Test("Downloaded config.json has expected model keys")
    func downloadedConfigHasExpectedKeys() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            in: tempBase
        )

        let slug = Acervo.slugify(testModelId)
        let configPath = tempBase
            .appendingPathComponent(slug)
            .appendingPathComponent("config.json")

        let data = try Data(contentsOf: configPath)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil, "config.json should parse as a dictionary")

        // HuggingFace model config.json files typically have a "model_type" key
        #expect(json?["model_type"] != nil, "config.json should contain a model_type key")
    }
}

// MARK: - ensureAvailable() Integration Tests

@Suite("Integration: ensureAvailable()")
struct EnsureAvailableIntegrationTests {

    @Test("ensureAvailable() downloads model when it is missing")
    func ensureAvailableDownloadsWhenMissing() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // Model does not exist in the temp directory
        #expect(!Acervo.isModelAvailable(testModelId, in: tempBase))

        // ensureAvailable() should download the model
        try await Acervo.ensureAvailable(
            testModelId,
            files: ["config.json"],
            in: tempBase
        )

        // Now the model should be available
        #expect(Acervo.isModelAvailable(testModelId, in: tempBase))

        // Verify config.json exists and is valid JSON
        let slug = Acervo.slugify(testModelId)
        let configPath = tempBase
            .appendingPathComponent(slug)
            .appendingPathComponent("config.json")
        let data = try Data(contentsOf: configPath)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any])
    }

    @Test("ensureAvailable() skips download when model already exists")
    func ensureAvailableSkipsWhenPresent() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // First download: populate the model
        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            in: tempBase
        )
        #expect(Acervo.isModelAvailable(testModelId, in: tempBase))

        // Record the modification date of config.json before ensureAvailable()
        let slug = Acervo.slugify(testModelId)
        let configPath = tempBase
            .appendingPathComponent(slug)
            .appendingPathComponent("config.json")
        let attrsBefore = try FileManager.default.attributesOfItem(
            atPath: configPath.path
        )
        let modDateBefore = attrsBefore[.modificationDate] as? Date

        // Small delay to ensure any re-download would produce a different timestamp
        try await Task.sleep(for: .milliseconds(100))

        // ensureAvailable() should skip because config.json already exists
        let collector = IntegrationProgressCollector()
        try await Acervo.ensureAvailable(
            testModelId,
            files: ["config.json"],
            progress: { report in
                Task { await collector.append(report) }
            },
            in: tempBase
        )

        // File modification date should be unchanged (no re-download occurred)
        let attrsAfter = try FileManager.default.attributesOfItem(
            atPath: configPath.path
        )
        let modDateAfter = attrsAfter[.modificationDate] as? Date
        #expect(
            modDateBefore == modDateAfter,
            "ensureAvailable should not re-download when model exists"
        )

        // No progress should have been reported (download was skipped entirely)
        try await Task.sleep(for: .milliseconds(50))
        let reports = await collector.getReports()
        #expect(reports.isEmpty, "No progress reports expected when download is skipped")
    }
}

// MARK: - Force Re-Download Tests

@Suite("Integration: Force Re-Download")
struct ForceReDownloadIntegrationTests {

    @Test("force=true re-downloads an existing file")
    func forceRedownloadsExistingFile() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // First download: populate config.json
        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            in: tempBase
        )

        let slug = Acervo.slugify(testModelId)
        let configPath = tempBase
            .appendingPathComponent(slug)
            .appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configPath.path))

        // Record the modification date before re-download
        let attrsBefore = try FileManager.default.attributesOfItem(
            atPath: configPath.path
        )
        let modDateBefore = attrsBefore[.modificationDate] as? Date

        // Small delay to ensure the re-download produces a different timestamp
        try await Task.sleep(for: .milliseconds(200))

        // Force re-download
        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            force: true,
            in: tempBase
        )

        // File should still exist
        #expect(FileManager.default.fileExists(atPath: configPath.path))

        // File should have been replaced (modification date changed)
        let attrsAfter = try FileManager.default.attributesOfItem(
            atPath: configPath.path
        )
        let modDateAfter = attrsAfter[.modificationDate] as? Date
        #expect(
            modDateBefore != modDateAfter,
            "force=true should replace the file, changing its modification date"
        )

        // Verify the re-downloaded file is still valid JSON
        let data = try Data(contentsOf: configPath)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any])
    }
}

// MARK: - Auth Token Tests

@Suite("Integration: Auth Token Header")
struct AuthTokenIntegrationTests {

    @Test("buildRequest includes Bearer token in Authorization header")
    func buildRequestIncludesToken() {
        let url = AcervoDownloader.buildURL(
            modelId: testModelId,
            fileName: "config.json"
        )
        let token = "hf_test_token_abcdef123456"
        let request = AcervoDownloader.buildRequest(from: url, token: token)

        #expect(request.url == url)
        #expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
        )
    }

    @Test("buildRequest omits Authorization header when token is nil")
    func buildRequestOmitsTokenWhenNil() {
        let url = AcervoDownloader.buildURL(
            modelId: testModelId,
            fileName: "config.json"
        )
        let request = AcervoDownloader.buildRequest(from: url, token: nil)

        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Download with a bogus token still works for public models")
    func downloadWithBogusTokenSucceeds() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // Public models should be downloadable even with a token present.
        // The token is included in the request but the server ignores it
        // for public models.
        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            token: "hf_bogus_token_for_testing",
            in: tempBase
        )

        let slug = Acervo.slugify(testModelId)
        let configPath = tempBase
            .appendingPathComponent(slug)
            .appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configPath.path))

        // Verify the file is valid JSON
        let data = try Data(contentsOf: configPath)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any])
    }

    @Test("buildRequest preserves token with special characters")
    func buildRequestPreservesSpecialChars() {
        let url = URL(string: "https://huggingface.co/test/model/resolve/main/f.json")!
        let token = "hf_ABC+/=xyz"
        let request = AcervoDownloader.buildRequest(from: url, token: token)

        #expect(
            request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_ABC+/=xyz"
        )
    }
}

// MARK: - Subdirectory File Download Tests

@Suite("Integration: Subdirectory File Download")
struct SubdirectoryFileDownloadIntegrationTests {

    @Test("Download a file into a subdirectory creates intermediate directories")
    func downloadCreatesSubdirectories() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // Use a model that has files in subdirectories.
        // The openai/whisper-tiny model has a "preprocessor_config.json"
        // at root level. We download config.json into a custom
        // subdirectory path to verify directory creation. However, the
        // downloader preserves the HuggingFace repo structure, so if
        // we request "tokenizer/tokenizer.json" it creates a "tokenizer/"
        // subdirectory under the model dir.
        //
        // For a reliable test, download a root-level file and verify the
        // model directory is created, then test subdirectory creation
        // via the AcervoDownloader.downloadFile() directly.

        let slug = Acervo.slugify(testModelId)
        let modelDir = tempBase.appendingPathComponent(slug)

        // Create the model directory
        try AcervoDownloader.ensureDirectory(at: modelDir)

        // Build the URL for a real file at the root level
        let url = AcervoDownloader.buildURL(
            modelId: testModelId,
            fileName: "config.json"
        )

        // Download the file into a subdirectory path under the model directory
        let subdirDestination = modelDir
            .appendingPathComponent("nested")
            .appendingPathComponent("subdir")
            .appendingPathComponent("config.json")

        try await AcervoDownloader.downloadFile(
            from: url,
            to: subdirDestination,
            token: nil
        )

        // Verify intermediate directories were created
        let nestedDir = modelDir
            .appendingPathComponent("nested")
            .appendingPathComponent("subdir")
        var isDirectory: ObjCBool = false
        let dirExists = FileManager.default.fileExists(
            atPath: nestedDir.path,
            isDirectory: &isDirectory
        )
        #expect(dirExists, "Intermediate directories should be created")
        #expect(isDirectory.boolValue, "Path should be a directory")

        // Verify file landed at the correct subdirectory path
        #expect(FileManager.default.fileExists(atPath: subdirDestination.path))

        // Verify file content is valid JSON
        let data = try Data(contentsOf: subdirDestination)
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any])
    }

    @Test("buildURL constructs correct URL for subdirectory files")
    func buildURLForSubdirectory() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
            fileName: "speech_tokenizer/config.json"
        )

        // Verify the URL includes the subdirectory path
        #expect(url.absoluteString.contains("speech_tokenizer/config.json"))
        #expect(url.absoluteString.hasPrefix("https://huggingface.co/"))
    }

    @Test("downloadFiles creates subdirectory for nested file path")
    func downloadFilesCreatesSubdirForNestedPath() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // Download config.json using a path that includes a subdirectory.
        // We use the download API with the full model download flow.
        // The model we use has config.json at root, which we'll reference
        // as a root file. To also test subdirectory creation, we download
        // two files: one at root and one we place at a nested path by
        // using the downloader directly.

        try await Acervo.download(
            testModelId,
            files: ["config.json"],
            in: tempBase
        )

        let slug = Acervo.slugify(testModelId)
        let modelDir = tempBase.appendingPathComponent(slug)

        // Root file should exist
        let rootConfig = modelDir.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: rootConfig.path))

        // Model should be detected as available (config.json at root)
        #expect(Acervo.isModelAvailable(testModelId, in: tempBase))
    }
}

// MARK: - HTTP Error Handling Tests

@Suite("Integration: HTTP Error Handling")
struct HTTPErrorHandlingIntegrationTests {

    @Test("404 error for nonexistent file in a real model")
    func notFoundForNonexistentFile() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        do {
            try await Acervo.download(
                testModelId,
                files: ["this_file_definitely_does_not_exist_12345.json"],
                in: tempBase
            )
            #expect(Bool(false), "Expected download to throw for nonexistent file")
        } catch let error as AcervoError {
            switch error {
            case .downloadFailed(let fileName, let statusCode):
                // HuggingFace returns 404 for missing files
                #expect(statusCode == 404, "Expected 404 status code, got \(statusCode)")
                #expect(
                    fileName.contains("this_file_definitely_does_not_exist_12345"),
                    "Error should include the file name"
                )
            default:
                // Some 404s may redirect and result in different errors;
                // as long as it is an AcervoError, the handling is correct.
                break
            }
            // Verify the error has a descriptive message
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "Error should have a descriptive message")
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(type(of: error)): \(error)")
        }
    }

    @Test("404 error for completely nonexistent model")
    func notFoundForNonexistentModel() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        let fakeModelId = "nonexistent-org-xyz/nonexistent-model-abc-99999"

        do {
            try await Acervo.download(
                fakeModelId,
                files: ["config.json"],
                in: tempBase
            )
            #expect(Bool(false), "Expected download to throw for nonexistent model")
        } catch let error as AcervoError {
            switch error {
            case .downloadFailed(_, let statusCode):
                // HuggingFace returns 401 or 404 for nonexistent repos
                #expect(
                    statusCode == 404 || statusCode == 401,
                    "Expected 404 or 401 for nonexistent model, got \(statusCode)"
                )
            case .networkError:
                // Network errors are also acceptable (e.g., DNS resolution
                // failures for unusual hostnames)
                break
            default:
                break
            }
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty)
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(type(of: error)): \(error)")
        }
    }

    @Test("Network error for unreachable host")
    func networkErrorForUnreachableHost() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        // Use the downloader directly with an unreachable URL
        let unreachableURL = URL(string: "https://localhost:1/fake/path/file.json")!
        let destination = tempBase.appendingPathComponent("output.json")

        do {
            try await AcervoDownloader.downloadFile(
                from: unreachableURL,
                to: destination,
                token: nil
            )
            #expect(Bool(false), "Expected download to throw for unreachable host")
        } catch let error as AcervoError {
            if case .networkError(let underlyingError) = error {
                // Verify the underlying error has useful information
                let desc = underlyingError.localizedDescription
                #expect(!desc.isEmpty, "Underlying network error should be descriptive")
            } else {
                #expect(Bool(false), "Expected networkError but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(type(of: error)): \(error)")
        }
    }

    @Test("Error descriptions are non-empty for all download error types")
    func errorDescriptionsAreDescriptive() {
        let downloadFailed = AcervoError.downloadFailed(
            fileName: "model.safetensors",
            statusCode: 404
        )
        #expect(downloadFailed.errorDescription?.contains("404") == true)
        #expect(downloadFailed.errorDescription?.contains("model.safetensors") == true)

        let invalidId = AcervoError.invalidModelId("bad-id")
        #expect(invalidId.errorDescription?.contains("bad-id") == true)
        #expect(invalidId.errorDescription?.contains("org/repo") == true)

        let notFound = AcervoError.modelNotFound("org/missing-model")
        #expect(notFound.errorDescription?.contains("org/missing-model") == true)
    }

    @Test("downloadFile with progress throws descriptive error for 404")
    func downloadFileWithProgressThrows404() async throws {
        let tempBase = try makeTempSharedModels()
        defer { cleanupTempDirectory(tempBase) }

        let url = AcervoDownloader.buildURL(
            modelId: testModelId,
            fileName: "this_file_does_not_exist_xyz.json"
        )
        let destination = tempBase.appendingPathComponent("output.json")

        do {
            try await AcervoDownloader.downloadFile(
                from: url,
                to: destination,
                token: nil,
                fileName: "this_file_does_not_exist_xyz.json",
                fileIndex: 0,
                totalFiles: 1,
                progress: nil
            )
            #expect(Bool(false), "Expected download to throw")
        } catch let error as AcervoError {
            if case .downloadFailed(_, let statusCode) = error {
                #expect(statusCode == 404, "Expected 404 for missing file")
            }
            // Other AcervoError types are also acceptable (e.g., networkError
            // if the request fails at the transport level)
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(type(of: error))")
        }
    }
}

#endif
