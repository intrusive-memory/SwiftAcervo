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
