import Testing
import Foundation
@testable import SwiftAcervo

/// A thread-safe collector for download progress reports, used in tests.
private actor ProgressCollector {
    var reports: [AcervoDownloadProgress] = []
    var called: Bool = false

    func append(_ report: AcervoDownloadProgress) {
        reports.append(report)
        called = true
    }

    func getReports() -> [AcervoDownloadProgress] {
        reports
    }

    func wasCalled() -> Bool {
        called
    }
}

/// Tests for AcervoDownloader: URL construction, directory creation, and download helpers.
struct AcervoDownloaderTests {

    // MARK: - URL Construction Tests

    @Test("buildURL constructs correct CDN URL for root file")
    func buildURLRootFile() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            fileName: "config.json"
        )
        #expect(
            url.absoluteString ==
            "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Qwen2.5-7B-Instruct-4bit/config.json"
        )
    }

    @Test("buildURL constructs correct CDN URL for subdirectory file")
    func buildURLSubdirectoryFile() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
            fileName: "speech_tokenizer/config.json"
        )
        #expect(
            url.absoluteString ==
            "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/speech_tokenizer/config.json"
        )
    }

    @Test("buildURL has correct URL components for CDN")
    func buildURLComponents() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            fileName: "tokenizer.json"
        )

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(components?.scheme == "https")
        #expect(components?.host == "pub-8e049ed02be340cbb18f921765fd24f3.r2.dev")
        #expect(
            components?.path ==
            "/models/mlx-community_Qwen2.5-7B-Instruct-4bit/tokenizer.json"
        )
    }

    @Test("buildURL handles deeply nested subdirectory file")
    func buildURLDeeplyNested() {
        let url = AcervoDownloader.buildURL(
            modelId: "org/repo",
            fileName: "sub1/sub2/model.safetensors"
        )
        #expect(
            url.absoluteString ==
            "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/org_repo/sub1/sub2/model.safetensors"
        )
    }

    @Test("buildManifestURL constructs correct manifest URL")
    func buildManifestURL() {
        let url = AcervoDownloader.buildManifestURL(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit"
        )
        #expect(
            url.absoluteString ==
            "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Qwen2.5-7B-Instruct-4bit/manifest.json"
        )
    }

    // MARK: - Request Construction Tests

    @Test("buildRequest creates a request with correct URL")
    func buildRequestCorrectURL() {
        let url = URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/org_repo/config.json")!
        let request = AcervoDownloader.buildRequest(from: url)

        #expect(request.url == url)
        // CDN requests should not have Authorization headers
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Directory Creation Tests

    @Test("ensureDirectory creates directory with intermediate paths")
    func ensureDirectoryCreatesIntermediates() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-\(UUID().uuidString)")
        let nestedDir = tempBase
            .appendingPathComponent("level1")
            .appendingPathComponent("level2")
            .appendingPathComponent("level3")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Directory should not exist yet
        #expect(!FileManager.default.fileExists(atPath: nestedDir.path))

        // Create with intermediates
        try AcervoDownloader.ensureDirectory(at: nestedDir)

        // Now it should exist
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: nestedDir.path,
            isDirectory: &isDirectory
        )
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test("ensureDirectory does nothing if directory already exists")
    func ensureDirectoryAlreadyExists() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create the directory first
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        // Should succeed without error
        try AcervoDownloader.ensureDirectory(at: tempDir)

        // Directory should still exist
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: tempDir.path,
            isDirectory: &isDirectory
        )
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    // MARK: - Download Error Tests

    @Test("downloadFile throws networkError for unreachable URL")
    func downloadFileNetworkError() async {
        let unreachableURL = URL(string: "https://localhost:1/nonexistent/file.json")!
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-\(UUID().uuidString)")
            .appendingPathComponent("output.json")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let manifestFile = CDNManifestFile(
            path: "file.json",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            sizeBytes: 100
        )

        do {
            try await AcervoDownloader.downloadFile(
                from: unreachableURL,
                to: destination,
                manifestFile: manifestFile
            )
            #expect(Bool(false), "Expected downloadFile to throw an error")
        } catch let error as AcervoError {
            // Should be a networkError since the server is unreachable
            if case .networkError = error {
                // Expected
            } else {
                #expect(Bool(false), "Expected AcervoError.networkError but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    @Test("downloadFile with progress throws networkError for unreachable URL")
    func downloadFileWithProgressNetworkError() async {
        let unreachableURL = URL(string: "https://localhost:1/nonexistent/file.json")!
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-\(UUID().uuidString)")
            .appendingPathComponent("output.json")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let manifestFile = CDNManifestFile(
            path: "file.json",
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            sizeBytes: 100
        )

        let collector = ProgressCollector()
        do {
            try await AcervoDownloader.downloadFile(
                from: unreachableURL,
                to: destination,
                manifestFile: manifestFile,
                fileName: "file.json",
                fileIndex: 0,
                totalFiles: 1,
                progress: { report in
                    Task { await collector.append(report) }
                }
            )
            #expect(Bool(false), "Expected downloadFile to throw an error")
        } catch let error as AcervoError {
            if case .networkError = error {
                // Expected - progress should not have been called since connection failed
                let wasCalled = await collector.wasCalled()
                #expect(!wasCalled)
            } else {
                #expect(Bool(false), "Expected AcervoError.networkError but got \(error)")
            }
        } catch {
            #expect(Bool(false), "Expected AcervoError but got \(error)")
        }
    }

    // MARK: - Progress Calculation Tests

    @Test("progress callback receives correct fileName")
    func progressCallbackFileName() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 3
        )
        #expect(progress.fileName == "config.json")
    }

    @Test("progress callback tracks file index correctly for single file")
    func progressSingleFileIndex() {
        let progress = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 1
        )
        #expect(progress.fileIndex == 0)
        #expect(progress.totalFiles == 1)
        // Half of the only file downloaded: 0.5/1.0 = 0.5
        #expect(progress.overallProgress == 0.5)
    }

    @Test("progress tracks file index across multiple files")
    func progressMultipleFileIndex() {
        // First file, halfway through
        let first = AcervoDownloadProgress(
            fileName: "config.json",
            bytesDownloaded: 500,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 3
        )
        #expect(first.fileIndex == 0)
        #expect(first.totalFiles == 3)
        // (0 + 0.5) / 3 = 0.1667
        let expectedFirst = (0.0 + 0.5) / 3.0
        #expect(abs(first.overallProgress - expectedFirst) < 0.001)

        // Second file, halfway through
        let second = AcervoDownloadProgress(
            fileName: "tokenizer.json",
            bytesDownloaded: 500,
            totalBytes: 1000,
            fileIndex: 1,
            totalFiles: 3
        )
        #expect(second.fileIndex == 1)
        // (1 + 0.5) / 3 = 0.5
        #expect(abs(second.overallProgress - 0.5) < 0.001)

        // Third file, complete
        let third = AcervoDownloadProgress(
            fileName: "model.safetensors",
            bytesDownloaded: 1000,
            totalBytes: 1000,
            fileIndex: 2,
            totalFiles: 3
        )
        #expect(third.fileIndex == 2)
        // (2 + 1.0) / 3 = 1.0
        #expect(abs(third.overallProgress - 1.0) < 0.001)
    }

    @Test("overallProgress calculation for partially completed files")
    func overallProgressPartial() {
        // File 1 of 4, 25% downloaded
        let p1 = AcervoDownloadProgress(
            fileName: "a.json",
            bytesDownloaded: 250,
            totalBytes: 1000,
            fileIndex: 0,
            totalFiles: 4
        )
        // (0 + 0.25) / 4 = 0.0625
        #expect(abs(p1.overallProgress - 0.0625) < 0.001)

        // File 3 of 4, 75% downloaded
        let p3 = AcervoDownloadProgress(
            fileName: "c.json",
            bytesDownloaded: 750,
            totalBytes: 1000,
            fileIndex: 2,
            totalFiles: 4
        )
        // (2 + 0.75) / 4 = 0.6875
        #expect(abs(p3.overallProgress - 0.6875) < 0.001)
    }

    @Test("overallProgress with unknown totalBytes treats file progress as zero")
    func overallProgressUnknownTotal() {
        let progress = AcervoDownloadProgress(
            fileName: "model.safetensors",
            bytesDownloaded: 5000,
            totalBytes: nil,
            fileIndex: 1,
            totalFiles: 3
        )
        // (1 + 0.0) / 3 = 0.333
        let expected = 1.0 / 3.0
        #expect(abs(progress.overallProgress - expected) < 0.001)
    }
}
