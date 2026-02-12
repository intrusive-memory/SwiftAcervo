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
}
