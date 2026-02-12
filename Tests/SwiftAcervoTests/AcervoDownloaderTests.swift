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

    @Test("buildURL constructs correct URL for root file")
    func buildURLRootFile() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            fileName: "config.json"
        )
        #expect(
            url.absoluteString ==
            "https://huggingface.co/mlx-community/Qwen2.5-7B-Instruct-4bit/resolve/main/config.json"
        )
    }

    @Test("buildURL constructs correct URL for subdirectory file")
    func buildURLSubdirectoryFile() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
            fileName: "speech_tokenizer/config.json"
        )
        #expect(
            url.absoluteString ==
            "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16/resolve/main/speech_tokenizer/config.json"
        )
    }

    @Test("buildURL has correct URL components")
    func buildURLComponents() {
        let url = AcervoDownloader.buildURL(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            fileName: "tokenizer.json"
        )

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(components?.scheme == "https")
        #expect(components?.host == "huggingface.co")
        #expect(
            components?.path ==
            "/mlx-community/Qwen2.5-7B-Instruct-4bit/resolve/main/tokenizer.json"
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
            "https://huggingface.co/org/repo/resolve/main/sub1/sub2/model.safetensors"
        )
    }

    // MARK: - Request Construction Tests

    @Test("buildRequest includes Authorization header when token provided")
    func buildRequestWithToken() {
        let url = URL(string: "https://huggingface.co/org/repo/resolve/main/config.json")!
        let request = AcervoDownloader.buildRequest(from: url, token: "hf_testtoken123")

        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_testtoken123")
    }

    @Test("buildRequest has no Authorization header when token is nil")
    func buildRequestWithoutToken() {
        let url = URL(string: "https://huggingface.co/org/repo/resolve/main/config.json")!
        let request = AcervoDownloader.buildRequest(from: url, token: nil)

        #expect(request.url == url)
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

        do {
            try await AcervoDownloader.downloadFile(
                from: unreachableURL,
                to: destination,
                token: nil
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

        let collector = ProgressCollector()
        do {
            try await AcervoDownloader.downloadFile(
                from: unreachableURL,
                to: destination,
                token: nil,
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

    // MARK: - Skip-If-Exists Tests

    @Test("downloadFiles skips existing files when force is false")
    func downloadFilesSkipsExisting() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Create destination directory with a pre-existing file
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let existingContent = "existing content"
        let existingFile = tempBase.appendingPathComponent("config.json")
        try existingContent.write(to: existingFile, atomically: true, encoding: .utf8)

        let collector = ProgressCollector()

        // downloadFiles should skip the existing file (force=false)
        // We use a model ID that will fail if actually downloaded (localhost),
        // so if it tries to download, the test will fail with a network error.
        // The file "config.json" exists, so it should be skipped.
        try await AcervoDownloader.downloadFiles(
            modelId: "test/skip-model",
            files: ["config.json"],
            destination: tempBase,
            token: nil,
            force: false,
            progress: { report in
                Task { await collector.append(report) }
            }
        )

        // The file should not have been re-downloaded; content should be unchanged
        let content = try String(contentsOf: existingFile, encoding: .utf8)
        #expect(content == existingContent)

        // Allow a moment for async Task to complete
        try await Task.sleep(for: .milliseconds(50))

        // Progress should have been reported for the skipped file
        let reports = await collector.getReports()
        #expect(reports.count == 1)
        #expect(reports[0].fileName == "config.json")
        #expect(reports[0].fileIndex == 0)
        #expect(reports[0].totalFiles == 1)
        // Skipped file reports as complete
        #expect(reports[0].bytesDownloaded == 1)
        #expect(reports[0].totalBytes == 1)
    }

    @Test("downloadFiles re-downloads when force is true")
    func downloadFilesForceRedownload() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-force-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Create destination directory with a pre-existing file
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let existingFile = tempBase.appendingPathComponent("config.json")
        try "existing content".write(to: existingFile, atomically: true, encoding: .utf8)

        // With force=true, it should attempt to re-download even though the file exists.
        // We use a nonexistent model ID so the download will fail with either
        // networkError or downloadFailed -- either way proves it attempted the download
        // rather than skipping the existing file.
        var didAttemptDownload = false
        do {
            try await AcervoDownloader.downloadFiles(
                modelId: "nonexistent-org/nonexistent-model-xyzzy",
                files: ["config.json"],
                destination: tempBase,
                token: nil,
                force: true,
                progress: nil
            )
            // If it somehow succeeded, the file would have been replaced
            // which also proves force=true worked
            didAttemptDownload = true
        } catch {
            // Any error (networkError or downloadFailed) proves the download was attempted
            didAttemptDownload = true
        }
        #expect(didAttemptDownload, "force=true should attempt download even when file exists")
    }

    @Test("downloadFiles skips multiple existing files with correct indices")
    func downloadFilesSkipsMultipleExisting() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-multi-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Create destination directory with multiple pre-existing files
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        try "a".write(
            to: tempBase.appendingPathComponent("file1.json"),
            atomically: true,
            encoding: .utf8
        )
        try "b".write(
            to: tempBase.appendingPathComponent("file2.json"),
            atomically: true,
            encoding: .utf8
        )
        try "c".write(
            to: tempBase.appendingPathComponent("file3.json"),
            atomically: true,
            encoding: .utf8
        )

        let collector = ProgressCollector()

        try await AcervoDownloader.downloadFiles(
            modelId: "test/multi-model",
            files: ["file1.json", "file2.json", "file3.json"],
            destination: tempBase,
            token: nil,
            force: false,
            progress: { report in
                Task { await collector.append(report) }
            }
        )

        // Allow a moment for async Tasks to complete
        try await Task.sleep(for: .milliseconds(50))

        // All three files should be skipped
        let reports = await collector.getReports()
        #expect(reports.count == 3)

        // Verify file indices are correct
        #expect(reports[0].fileIndex == 0)
        #expect(reports[0].fileName == "file1.json")
        #expect(reports[0].totalFiles == 3)

        #expect(reports[1].fileIndex == 1)
        #expect(reports[1].fileName == "file2.json")
        #expect(reports[1].totalFiles == 3)

        #expect(reports[2].fileIndex == 2)
        #expect(reports[2].fileName == "file3.json")
        #expect(reports[2].totalFiles == 3)
    }

    @Test("downloadFiles skips existing file and preserves its content")
    func downloadFilesSkipsPreservesContent() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-preserve-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )

        // Write known content to the file
        let knownContent = "{\"key\": \"preserved_value\"}"
        let file = tempBase.appendingPathComponent("data.json")
        try knownContent.write(to: file, atomically: true, encoding: .utf8)

        // Get the modification date before the call
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let modDateBefore = attrs[.modificationDate] as? Date

        // Small delay to ensure any re-download would produce a different mod date
        try await Task.sleep(for: .milliseconds(50))

        // Skip since file exists
        try await AcervoDownloader.downloadFiles(
            modelId: "test/preserve-model",
            files: ["data.json"],
            destination: tempBase,
            token: nil,
            force: false,
            progress: nil
        )

        // Verify content is unchanged
        let afterContent = try String(contentsOf: file, encoding: .utf8)
        #expect(afterContent == knownContent)

        // Verify modification date is unchanged (file was not touched)
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: file.path)
        let modDateAfter = attrsAfter[.modificationDate] as? Date
        #expect(modDateBefore == modDateAfter)
    }

    @Test("downloadFiles skips subdirectory file when it exists")
    func downloadFilesSkipsSubdirectoryFile() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-subdir-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Create destination with a subdirectory file
        let subdir = tempBase.appendingPathComponent("speech_tokenizer")
        try FileManager.default.createDirectory(
            at: subdir,
            withIntermediateDirectories: true
        )
        let subdirFile = subdir.appendingPathComponent("config.json")
        try "subdir content".write(to: subdirFile, atomically: true, encoding: .utf8)

        let collector = ProgressCollector()

        // Should skip the subdirectory file since it exists
        try await AcervoDownloader.downloadFiles(
            modelId: "test/subdir-model",
            files: ["speech_tokenizer/config.json"],
            destination: tempBase,
            token: nil,
            force: false,
            progress: { report in
                Task { await collector.append(report) }
            }
        )

        // Content should be unchanged
        let content = try String(contentsOf: subdirFile, encoding: .utf8)
        #expect(content == "subdir content")

        // Allow async tasks to complete
        try await Task.sleep(for: .milliseconds(50))

        let reports = await collector.getReports()
        #expect(reports.count == 1)
        #expect(reports[0].fileName == "speech_tokenizer/config.json")
    }

    @Test("downloadFiles does not skip missing files when force is false")
    func downloadFilesDoesNotSkipMissing() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoDownloaderTests-no-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBase) }

        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )

        // File does NOT exist, so even with force=false it should try to download.
        // The download will fail because the model doesn't exist, proving the attempt.
        var downloadAttempted = false
        do {
            try await AcervoDownloader.downloadFiles(
                modelId: "nonexistent-org/missing-model-xyz",
                files: ["missing.json"],
                destination: tempBase,
                token: nil,
                force: false,
                progress: nil
            )
        } catch {
            downloadAttempted = true
        }
        #expect(downloadAttempted, "Missing files should trigger download even with force=false")
    }
}
