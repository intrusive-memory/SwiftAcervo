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

// MARK: - Per-Model Locking

extension AcervoManager {

    /// Acquires an exclusive lock for the specified model ID.
    ///
    /// If the model is already locked by another operation, this method
    /// suspends and polls every 50 milliseconds until the lock becomes
    /// available. Once acquired, the caller is responsible for releasing
    /// the lock via `releaseLock(for:)`.
    ///
    /// - Parameter modelId: The HuggingFace model identifier to lock.
    private func acquireLock(for modelId: String) async {
        while downloadLocks[modelId] == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        downloadLocks[modelId] = true
    }

    /// Releases the exclusive lock for the specified model ID.
    ///
    /// This should be called (typically via `defer`) after a locked operation
    /// completes, even if the operation threw an error.
    ///
    /// - Parameter modelId: The HuggingFace model identifier to unlock.
    private func releaseLock(for modelId: String) {
        downloadLocks[modelId] = false
    }

    /// Returns whether the specified model ID is currently locked.
    ///
    /// This is primarily useful for testing to verify that locks are
    /// properly released after operations complete.
    ///
    /// - Parameter modelId: The HuggingFace model identifier to check.
    /// - Returns: `true` if the model is currently locked.
    func isLocked(_ modelId: String) -> Bool {
        downloadLocks[modelId] == true
    }
}

// MARK: - Download

extension AcervoManager {

    /// Downloads specific files for a HuggingFace model with per-model locking.
    ///
    /// If another download or access operation is in progress for the same model,
    /// this method waits until the lock is released before proceeding. Downloads
    /// of different models proceed concurrently without blocking each other.
    ///
    /// The lock is automatically released when the download completes or throws,
    /// via `defer`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format
    ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - files: An array of file names or relative paths within the model repository.
    ///   - token: An optional HuggingFace API token for gated model access.
    ///   - force: When `true`, re-downloads files even if they already exist.
    ///     Defaults to `false`.
    ///   - progress: An optional callback invoked periodically with download
    ///     progress. Must be `@Sendable` for Swift 6 strict concurrency.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   or download-related errors from the underlying `Acervo.download()`.
    public func download(
        _ modelId: String,
        files: [String],
        token: String? = nil,
        force: Bool = false,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
    ) async throws {
        await acquireLock(for: modelId)
        defer { releaseLock(for: modelId) }

        try await Acervo.download(
            modelId,
            files: files,
            token: token,
            force: force,
            progress: progress
        )
    }
}
