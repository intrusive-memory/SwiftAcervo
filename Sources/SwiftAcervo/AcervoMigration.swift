// AcervoMigration.swift
// SwiftAcervo
//
// Legacy path constants for migration from the old intrusive-memory
// cache directory structure to the new SharedModels canonical location.

import Foundation

/// Internal constants for legacy path migration.
///
/// Defines the legacy base path and subdirectory structure used by
/// earlier intrusive-memory projects. These paths are scanned during
/// migration to discover models that should be moved to
/// `~/Library/SharedModels/`.
struct AcervoMigration: Sendable {

    /// The legacy base directory where models were stored.
    ///
    /// Resolves to `~/Library/Caches/intrusive-memory/Models/`.
    static var legacyBasePath: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/intrusive-memory/Models")
    }

    /// The subdirectories within the legacy base path that contained models.
    ///
    /// Each subdirectory corresponds to a model type category used by
    /// earlier projects:
    /// - `LLM`: Language models (SwiftBruja, Produciesta)
    /// - `TTS`: Text-to-speech models (SwiftVoxAlta)
    /// - `Audio`: Audio models (mlx-audio-swift)
    /// - `VLM`: Vision-language models
    static let legacySubdirectories: [String] = ["LLM", "TTS", "Audio", "VLM"]
}
