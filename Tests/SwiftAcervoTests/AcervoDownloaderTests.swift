import Testing
import Foundation
@testable import SwiftAcervo

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
}
