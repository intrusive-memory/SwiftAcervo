// AcervoDownloader.swift
// SwiftAcervo
//
// Internal download infrastructure for fetching HuggingFace model files.
//
// AcervoDownloader provides static helpers for constructing HuggingFace
// download URLs, ensuring local directories exist, and downloading
// individual files with optional authentication. This type is internal
// to the package; the public download API lives on `Acervo`.
//
// URL format:
//   https://huggingface.co/{modelId}/resolve/main/{fileName}
//
// Auth header (for gated models):
//   Authorization: Bearer {token}

import Foundation

/// Internal download infrastructure for fetching HuggingFace model files.
///
/// All methods are static. This struct is not publicly exposed; consumers
/// use `Acervo.download()` and related public API instead.
struct AcervoDownloader: Sendable {

    /// The base URL for the HuggingFace model repository.
    static let huggingFaceBaseURL = "https://huggingface.co"

    private init() {}
}

// MARK: - URL Construction

extension AcervoDownloader {

    /// Constructs the HuggingFace download URL for a specific file in a model repository.
    ///
    /// The URL follows the HuggingFace pattern:
    /// `https://huggingface.co/{modelId}/resolve/main/{fileName}`
    ///
    /// Subdirectory files are supported. For example, a `fileName` of
    /// `"speech_tokenizer/config.json"` produces a URL with the subdirectory
    /// path preserved in the URL path.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - fileName: The file name or relative path within the model repository
    ///     (e.g., "config.json" or "speech_tokenizer/config.json").
    /// - Returns: The fully qualified download URL.
    static func buildURL(modelId: String, fileName: String) -> URL {
        // Build the URL by appending path components to avoid encoding issues.
        // modelId contains a "/" (e.g., "org/repo") which is a valid path separator.
        var url = URL(string: huggingFaceBaseURL)!
            .appendingPathComponent(modelId)
            .appendingPathComponent("resolve")
            .appendingPathComponent("main")

        // Handle subdirectory files by appending each path component separately
        let pathComponents = fileName.split(separator: "/").map(String.init)
        for component in pathComponents {
            url = url.appendingPathComponent(component)
        }

        return url
    }
}
