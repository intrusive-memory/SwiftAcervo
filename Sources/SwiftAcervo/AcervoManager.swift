// AcervoManager.swift
// SwiftAcervo
//
// Actor-based thread-safe manager for shared AI model operations.
//
// AcervoManager wraps the static Acervo API with per-model locking
// to ensure that concurrent downloads of the same model are serialized,
// while downloads of different models proceed in parallel. It also
// provides exclusive model directory access via withModelAccess().
//
// Usage:
//
//     import SwiftAcervo
//
//     try await AcervoManager.shared.download(
//         "mlx-community/Qwen2.5-7B-Instruct-4bit",
//         files: ["config.json", "model.safetensors"]
//     )
//
//     let url = try await AcervoManager.shared.withModelAccess(
//         "mlx-community/Qwen2.5-7B-Instruct-4bit"
//     ) { url in
//         return url
//     }
//

import Foundation

/// Actor-based thread-safe manager for shared AI model operations.
///
/// `AcervoManager` provides per-model locking so that concurrent downloads
/// of the same model are serialized, while downloads of different models
/// proceed in parallel. Access the singleton instance via `shared`.
///
/// All closures passed to `AcervoManager` must be `@Sendable`.
public actor AcervoManager {

    /// The shared singleton instance.
    public static let shared = AcervoManager()

    /// Per-model download locks. When a model ID maps to `true`, the model
    /// is currently being accessed or downloaded and other callers must wait.
    private var downloadLocks: [String: Bool] = [:]

    /// Cached model directory URLs, keyed by model ID.
    private var urlCache: [String: URL] = [:]

    /// Private initializer to enforce singleton usage.
    private init() {}
}
