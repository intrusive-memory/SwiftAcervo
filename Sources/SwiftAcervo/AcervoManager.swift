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
    ///
    /// ```swift
    /// let manager = AcervoManager.shared
    /// ```
    public static let shared = AcervoManager()

    /// Per-model download locks. When a model ID maps to `true`, the model
    /// is currently being accessed or downloaded and other callers must wait.
    private var downloadLocks: [String: Bool] = [:]

    /// Cached model directory URLs, keyed by model ID.
    private var urlCache: [String: URL] = [:]

    /// Download counts per model ID for statistics tracking.
    private var downloadCount: [String: Int] = [:]

    /// Access counts per model ID for statistics tracking.
    private var accessCount: [String: Int] = [:]

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

// MARK: - URL Cache

extension AcervoManager {

    /// Returns the cached URL for the specified model ID, if present.
    ///
    /// - Parameter modelId: The HuggingFace model identifier.
    /// - Returns: The cached URL, or `nil` if the model is not in the cache.
    private func cachedURL(for modelId: String) -> URL? {
        urlCache[modelId]
    }

    /// Stores a URL in the cache for the specified model ID.
    ///
    /// - Parameters:
    ///   - url: The model directory URL to cache.
    ///   - modelId: The HuggingFace model identifier.
    private func cacheURL(_ url: URL, for modelId: String) {
        urlCache[modelId] = url
    }

    /// Clears the entire URL cache.
    ///
    /// After calling this method, all cached model URLs are discarded.
    /// Subsequent operations will re-resolve model directory paths.
    ///
    /// ```swift
    /// await AcervoManager.shared.clearCache()
    /// ```
    public func clearCache() {
        urlCache.removeAll()
    }

    /// Preloads the URL cache with all models found in the shared models directory.
    ///
    /// Calls `Acervo.listModels()` and caches the directory URL for each
    /// discovered model. This is useful for warming the cache at application
    /// startup to avoid repeated filesystem scans.
    ///
    /// - Throws: Errors from `FileManager` if the shared models directory
    ///   cannot be read.
    ///
    /// ```swift
    /// try await AcervoManager.shared.preloadModels()
    /// // URL cache is now warmed for all discovered models
    /// ```
    public func preloadModels() async throws {
        let models = try Acervo.listModels()
        for model in models {
            cacheURL(model.path, for: model.id)
        }
    }

    /// Preloads the URL cache with all models found in the specified base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameter baseDirectory: The directory to scan for model subdirectories.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    func preloadModels(in baseDirectory: URL) async throws {
        let models = try Acervo.listModels(in: baseDirectory)
        for model in models {
            cacheURL(model.path, for: model.id)
        }
    }

    /// Returns the number of entries currently in the URL cache.
    ///
    /// Primarily useful for testing to verify cache population and clearing.
    func cacheCount() -> Int {
        urlCache.count
    }

    /// Returns whether the URL cache contains an entry for the specified model ID.
    ///
    /// Primarily useful for testing.
    ///
    /// - Parameter modelId: The HuggingFace model identifier to check.
    /// - Returns: `true` if the cache contains a URL for the model.
    func isCached(_ modelId: String) -> Bool {
        urlCache[modelId] != nil
    }
}

// MARK: - Statistics

extension AcervoManager {

    /// Returns the number of times `download()` has been called for the
    /// specified model ID.
    ///
    /// - Parameter modelId: The HuggingFace model identifier.
    /// - Returns: The download count, or 0 if the model has never been downloaded.
    ///
    /// ```swift
    /// let count = await AcervoManager.shared.getDownloadCount(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
    /// ```
    public func getDownloadCount(for modelId: String) -> Int {
        downloadCount[modelId] ?? 0
    }

    /// Returns the number of times `withModelAccess()` has been called for the
    /// specified model ID.
    ///
    /// - Parameter modelId: The HuggingFace model identifier.
    /// - Returns: The access count, or 0 if the model has never been accessed.
    ///
    /// ```swift
    /// let count = await AcervoManager.shared.getAccessCount(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
    /// ```
    public func getAccessCount(for modelId: String) -> Int {
        accessCount[modelId] ?? 0
    }

    /// Prints a formatted statistics report showing the top 10 downloaded
    /// and top 10 accessed models.
    ///
    /// Output goes to standard output via `print()`. If no statistics have
    /// been recorded, the report indicates that.
    ///
    /// ```swift
    /// await AcervoManager.shared.printStatisticsReport()
    /// ```
    public func printStatisticsReport() {
        print("=== AcervoManager Statistics Report ===")
        print("")

        // Top 10 downloaded models
        let topDownloads = downloadCount
            .sorted { $0.value > $1.value }
            .prefix(10)

        print("Top Downloaded Models:")
        if topDownloads.isEmpty {
            print("  (no downloads recorded)")
        } else {
            for (index, entry) in topDownloads.enumerated() {
                print("  \(index + 1). \(entry.key): \(entry.value) download(s)")
            }
        }

        print("")

        // Top 10 accessed models
        let topAccesses = accessCount
            .sorted { $0.value > $1.value }
            .prefix(10)

        print("Top Accessed Models:")
        if topAccesses.isEmpty {
            print("  (no accesses recorded)")
        } else {
            for (index, entry) in topAccesses.enumerated() {
                print("  \(index + 1). \(entry.key): \(entry.value) access(es)")
            }
        }

        print("")
        print("=======================================")
    }

    /// Resets all download and access statistics counters to zero.
    ///
    /// ```swift
    /// await AcervoManager.shared.resetStatistics()
    /// ```
    public func resetStatistics() {
        downloadCount.removeAll()
        accessCount.removeAll()
    }

    /// Increments the download counter for the specified model ID.
    private func trackDownload(for modelId: String) {
        downloadCount[modelId, default: 0] += 1
    }

    /// Increments the access counter for the specified model ID.
    private func trackAccess(for modelId: String) {
        accessCount[modelId, default: 0] += 1
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
    ///
    /// ```swift
    /// try await AcervoManager.shared.download(
    ///     "mlx-community/Qwen2.5-7B-Instruct-4bit",
    ///     files: ["config.json", "model.safetensors"],
    ///     progress: { p in print("\(p.overallProgress * 100)%") }
    /// )
    /// ```
    public func download(
        _ modelId: String,
        files: [String],
        token: String? = nil,
        force: Bool = false,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
    ) async throws {
        await acquireLock(for: modelId)
        defer { releaseLock(for: modelId) }

        trackDownload(for: modelId)

        try await Acervo.download(
            modelId,
            files: files,
            token: token,
            force: force,
            progress: progress
        )

        // Cache the model directory URL after successful download
        if let modelDir = try? Acervo.modelDirectory(for: modelId) {
            cacheURL(modelDir, for: modelId)
        }
    }
}

// MARK: - Exclusive Model Access

extension AcervoManager {

    /// Provides exclusive access to a model's directory while holding the
    /// per-model lock.
    ///
    /// The lock is acquired before the closure is called and released after
    /// it returns (or throws), preventing concurrent modifications to the
    /// same model directory. Access to different models is not blocked.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format
    ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - perform: A `@Sendable` closure that receives the model directory
    ///     URL and returns a value. The closure executes while the lock is held.
    /// - Returns: The value returned by the `perform` closure.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   or any error thrown by the `perform` closure. The lock is released
    ///   in all cases.
    ///
    /// ```swift
    /// let configURL = try await AcervoManager.shared.withModelAccess(
    ///     "mlx-community/Qwen2.5-7B-Instruct-4bit"
    /// ) { dir in
    ///     dir.appendingPathComponent("config.json")
    /// }
    /// ```
    public func withModelAccess<T: Sendable>(
        _ modelId: String,
        perform: @Sendable (URL) throws -> T
    ) async throws -> T {
        await acquireLock(for: modelId)
        defer { releaseLock(for: modelId) }

        trackAccess(for: modelId)

        let modelDir = try Acervo.modelDirectory(for: modelId)
        return try perform(modelDir)
    }
}
