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

#endif
