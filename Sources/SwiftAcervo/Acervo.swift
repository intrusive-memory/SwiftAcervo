// Acervo.swift
// SwiftAcervo
//
// Static API namespace for shared AI model discovery and management.
//
// Acervo ("collection" / "repository" in Portuguese) provides a single
// canonical location for HuggingFace AI models across the intrusive-memory
// ecosystem. All model path resolution, availability checks, discovery,
// download, and migration operations are accessed through static methods
// on this enum.
//
// Usage:
//
//     import SwiftAcervo
//
//     let dir = Acervo.sharedModelsDirectory
//     let available = Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit")
//

import Foundation

/// Static API namespace for shared AI model discovery and management.
///
/// `Acervo` is a caseless enum used purely as a namespace. All functionality
/// is provided through static properties and methods. For thread-safe
/// operations with per-model locking, see `AcervoManager`.
public enum Acervo {}

// MARK: - Path Resolution

extension Acervo {

    /// The canonical base directory for all shared HuggingFace models.
    ///
    /// Returns `~/Library/SharedModels/`. This directory is persistent
    /// (not in Caches) and survives macOS cleanup operations.
    ///
    /// All model directories are stored as direct children of this path,
    /// named using the slugified HuggingFace model ID.
    public static var sharedModelsDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/SharedModels")
    }

    /// Converts a HuggingFace model ID to a filesystem-safe directory name.
    ///
    /// Replaces all "/" characters with "_". This is the canonical transformation
    /// used to derive directory names from HuggingFace model identifiers.
    ///
    /// - Parameter modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    /// - Returns: The slugified form (e.g., "mlx-community_Qwen2.5-7B-Instruct-4bit").
    ///   Returns an empty string if the input is empty.
    public static func slugify(_ modelId: String) -> String {
        modelId.replacingOccurrences(of: "/", with: "_")
    }

    /// Returns the local filesystem directory for a given HuggingFace model ID.
    ///
    /// The model ID must contain exactly one "/" separating the organization
    /// from the repository name (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///
    /// - Parameter modelId: A HuggingFace model identifier in "org/repo" format.
    /// - Returns: The URL of the model directory within `sharedModelsDirectory`.
    /// - Throws: `AcervoError.invalidModelId` if the model ID does not contain
    ///   exactly one "/".
    public static func modelDirectory(for modelId: String) throws -> URL {
        let slashCount = modelId.filter { $0 == "/" }.count
        guard slashCount == 1 else {
            throw AcervoError.invalidModelId(modelId)
        }
        return sharedModelsDirectory.appendingPathComponent(slugify(modelId))
    }
}

// MARK: - Availability

extension Acervo {

    /// Checks whether a model is available locally by verifying the presence
    /// of `config.json` in its model directory.
    ///
    /// This method never throws. If the model ID is invalid or the directory
    /// does not exist, it returns `false`.
    ///
    /// - Parameter modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    /// - Returns: `true` if the model directory contains a `config.json` file.
    public static func isModelAvailable(_ modelId: String) -> Bool {
        guard let dir = try? modelDirectory(for: modelId) else {
            return false
        }
        let configPath = dir.appendingPathComponent("config.json").path
        return FileManager.default.fileExists(atPath: configPath)
    }

    /// Checks whether a specific file exists within a model's directory.
    ///
    /// Supports files in subdirectories (e.g., "speech_tokenizer/config.json").
    /// This method never throws. If the model ID is invalid or the model
    /// directory does not exist, it returns `false`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16").
    ///   - fileName: The file name or relative path within the model directory
    ///     (e.g., "tokenizer.json" or "speech_tokenizer/config.json").
    /// - Returns: `true` if the file exists at the expected location.
    public static func modelFileExists(_ modelId: String, fileName: String) -> Bool {
        guard let dir = try? modelDirectory(for: modelId) else {
            return false
        }
        let filePath = dir.appendingPathComponent(fileName).path
        return FileManager.default.fileExists(atPath: filePath)
    }
}

// MARK: - Model Discovery

extension Acervo {

    /// Lists all valid models in the shared models directory.
    ///
    /// Scans `sharedModelsDirectory` for subdirectories containing `config.json`,
    /// extracts model metadata, and returns them sorted alphabetically by ID.
    ///
    /// - Returns: An array of `AcervoModel` instances for all valid models,
    ///   sorted by model ID.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    public static func listModels() throws -> [AcervoModel] {
        try listModels(in: sharedModelsDirectory)
    }

    /// Lists all valid models in the specified base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameter baseDirectory: The directory to scan for model subdirectories.
    /// - Returns: An array of `AcervoModel` instances for all valid models,
    ///   sorted by model ID.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    static func listModels(in baseDirectory: URL) throws -> [AcervoModel] {
        let fm = FileManager.default

        // If the base directory doesn't exist, return empty array
        guard fm.fileExists(atPath: baseDirectory.path) else {
            return []
        }

        let contents = try fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var models: [AcervoModel] = []

        for itemURL in contents {
            // Only consider directories
            guard let resourceValues = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ), resourceValues.isDirectory == true else {
                continue
            }

            // Must contain config.json to be a valid model
            let configURL = itemURL.appendingPathComponent("config.json")
            guard fm.fileExists(atPath: configURL.path) else {
                continue
            }

            // Extract model ID from directory name by reverse slugify:
            // Replace the first "_" with "/" to reconstruct "org/repo"
            let dirName = itemURL.lastPathComponent
            guard let firstUnderscore = dirName.firstIndex(of: "_") else {
                continue // Skip directories without underscore (invalid slug)
            }
            let org = String(dirName[dirName.startIndex..<firstUnderscore])
            let repo = String(dirName[dirName.index(after: firstUnderscore)...])
            let modelId = "\(org)/\(repo)"

            // Get creation date from directory attributes
            let attributes = try? fm.attributesOfItem(atPath: itemURL.path)
            let downloadDate = (attributes?[.creationDate] as? Date) ?? Date()

            // Calculate total size
            let size = (try? directorySize(at: itemURL)) ?? 0

            let model = AcervoModel(
                id: modelId,
                path: itemURL,
                sizeBytes: size,
                downloadDate: downloadDate
            )
            models.append(model)
        }

        // Sort alphabetically by ID
        models.sort { $0.id < $1.id }

        return models
    }

    /// Returns metadata for a single model identified by its HuggingFace ID.
    ///
    /// Scans the shared models directory and returns the model whose ID matches
    /// the given identifier.
    ///
    /// - Parameter modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    /// - Returns: The `AcervoModel` matching the given ID.
    /// - Throws: `AcervoError.modelNotFound` if no model with the given ID
    ///   exists in the shared models directory.
    public static func modelInfo(_ modelId: String) throws -> AcervoModel {
        try modelInfo(modelId, in: sharedModelsDirectory)
    }

    /// Returns metadata for a single model, scanning the specified base directory.
    ///
    /// This internal overload enables testing with temporary directories.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier.
    ///   - baseDirectory: The directory to scan for model subdirectories.
    /// - Returns: The `AcervoModel` matching the given ID.
    /// - Throws: `AcervoError.modelNotFound` if no model with the given ID
    ///   exists in the specified directory.
    static func modelInfo(_ modelId: String, in baseDirectory: URL) throws -> AcervoModel {
        let models = try listModels(in: baseDirectory)
        guard let model = models.first(where: { $0.id == modelId }) else {
            throw AcervoError.modelNotFound(modelId)
        }
        return model
    }
}

// MARK: - Pattern Matching

extension Acervo {

    /// Finds all models whose IDs contain the given substring.
    ///
    /// Performs a case-insensitive substring search across all model IDs
    /// in the shared models directory. Returns all matching models sorted
    /// alphabetically by ID.
    ///
    /// - Parameter pattern: The substring to search for within model IDs.
    /// - Returns: An array of `AcervoModel` instances whose IDs contain
    ///   the pattern (case-insensitive), sorted by model ID.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    public static func findModels(matching pattern: String) throws -> [AcervoModel] {
        try findModels(matching: pattern, in: sharedModelsDirectory)
    }

    /// Finds all models whose IDs contain the given substring, scanning
    /// the specified base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameters:
    ///   - pattern: The substring to search for within model IDs (case-insensitive).
    ///   - baseDirectory: The directory to scan for model subdirectories.
    /// - Returns: An array of `AcervoModel` instances whose IDs contain
    ///   the pattern (case-insensitive), sorted by model ID.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    static func findModels(matching pattern: String, in baseDirectory: URL) throws -> [AcervoModel] {
        let allModels = try listModels(in: baseDirectory)
        let lowercasedPattern = pattern.lowercased()

        let matches = allModels.filter { model in
            model.id.lowercased().contains(lowercasedPattern)
        }

        // listModels already returns sorted by ID, and filter preserves order
        return matches
    }
}

// MARK: - Fuzzy Search

extension Acervo {

    /// Common HuggingFace organization prefixes that are stripped before
    /// computing edit distance, so that "Qwen2.5-7B" matches
    /// "mlx-community/Qwen2.5-7B-Instruct-4bit" without the org prefix
    /// inflating the distance.
    private static let commonPrefixes = ["mlx-community/"]

    /// Strips known organization prefixes from a string for fuzzy comparison.
    ///
    /// This allows queries like "Qwen2.5-7B" to match model IDs like
    /// "mlx-community/Qwen2.5-7B-Instruct-4bit" without the org prefix
    /// contributing to the edit distance.
    ///
    /// - Parameter value: The string to strip prefixes from.
    /// - Returns: The string with any matching prefix removed (case-insensitive).
    private static func stripCommonPrefixes(_ value: String) -> String {
        let lowered = value.lowercased()
        for prefix in commonPrefixes {
            if lowered.hasPrefix(prefix.lowercased()) {
                return String(value.dropFirst(prefix.count))
            }
        }
        return value
    }

    /// Finds all models whose IDs are within the given Levenshtein edit distance
    /// of the query string.
    ///
    /// Before computing edit distance, common organization prefixes
    /// (e.g., "mlx-community/") are stripped from both the query and each
    /// model ID. Results are sorted by distance (closest first), then
    /// alphabetically by model ID for ties.
    ///
    /// - Parameters:
    ///   - query: The search string to match against model IDs.
    ///   - threshold: The maximum edit distance to consider a match. Defaults to 5.
    /// - Returns: An array of `AcervoModel` instances within the threshold,
    ///   sorted by closeness (then by ID).
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    public static func findModels(
        fuzzyMatching query: String,
        editDistance threshold: Int = 5
    ) throws -> [AcervoModel] {
        try findModels(fuzzyMatching: query, editDistance: threshold, in: sharedModelsDirectory)
    }

    /// Finds all models whose IDs are within the given Levenshtein edit distance,
    /// scanning the specified base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameters:
    ///   - query: The search string to match against model IDs.
    ///   - threshold: The maximum edit distance to consider a match.
    ///   - baseDirectory: The directory to scan for model subdirectories.
    /// - Returns: An array of `AcervoModel` instances within the threshold,
    ///   sorted by closeness (then by ID).
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    static func findModels(
        fuzzyMatching query: String,
        editDistance threshold: Int = 5,
        in baseDirectory: URL
    ) throws -> [AcervoModel] {
        let allModels = try listModels(in: baseDirectory)
        let strippedQuery = stripCommonPrefixes(query)

        // Calculate distance for each model and filter by threshold
        var matches: [(model: AcervoModel, distance: Int)] = []

        for model in allModels {
            let strippedId = stripCommonPrefixes(model.id)
            let distance = levenshteinDistance(strippedQuery, strippedId)
            if distance <= threshold {
                matches.append((model: model, distance: distance))
            }
        }

        // Sort by distance (closest first), then by ID for ties
        matches.sort { lhs, rhs in
            if lhs.distance != rhs.distance {
                return lhs.distance < rhs.distance
            }
            return lhs.model.id < rhs.model.id
        }

        return matches.map(\.model)
    }

    /// Returns the single closest model to the query string by edit distance,
    /// or `nil` if no model is within the threshold.
    ///
    /// This is a convenience wrapper around `findModels(fuzzyMatching:editDistance:)`
    /// that returns only the first (closest) result. Useful for "did you mean...?"
    /// suggestions.
    ///
    /// - Parameters:
    ///   - query: The search string to match against model IDs.
    ///   - threshold: The maximum edit distance to consider a match. Defaults to 5.
    /// - Returns: The closest `AcervoModel` within the threshold, or `nil`.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    public static func closestModel(
        to query: String,
        editDistance threshold: Int = 5
    ) throws -> AcervoModel? {
        try closestModel(to: query, editDistance: threshold, in: sharedModelsDirectory)
    }

    /// Returns the single closest model to the query string, scanning the
    /// specified base directory.
    ///
    /// This internal overload enables testing with temporary directories.
    ///
    /// - Parameters:
    ///   - query: The search string to match against model IDs.
    ///   - threshold: The maximum edit distance to consider a match.
    ///   - baseDirectory: The directory to scan for model subdirectories.
    /// - Returns: The closest `AcervoModel` within the threshold, or `nil`.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    static func closestModel(
        to query: String,
        editDistance threshold: Int = 5,
        in baseDirectory: URL
    ) throws -> AcervoModel? {
        let matches = try findModels(
            fuzzyMatching: query,
            editDistance: threshold,
            in: baseDirectory
        )
        return matches.first
    }
}

// MARK: - Model Families

extension Acervo {

    /// Groups all models by their family name.
    ///
    /// Models with the same `familyName` (org + base model name, with
    /// quantization/size/variant suffixes stripped) are grouped together.
    /// Models within each family are sorted alphabetically by ID.
    ///
    /// - Returns: A dictionary mapping family names to arrays of models.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    public static func modelFamilies() throws -> [String: [AcervoModel]] {
        try modelFamilies(in: sharedModelsDirectory)
    }

    /// Groups all models by their family name, scanning the specified
    /// base directory.
    ///
    /// This internal overload enables testing with temporary directories.
    ///
    /// - Parameter baseDirectory: The directory to scan for model subdirectories.
    /// - Returns: A dictionary mapping family names to arrays of models.
    /// - Throws: Errors from `FileManager` if the directory cannot be read.
    static func modelFamilies(in baseDirectory: URL) throws -> [String: [AcervoModel]] {
        let allModels = try listModels(in: baseDirectory)

        var families: [String: [AcervoModel]] = [:]

        for model in allModels {
            let family = model.familyName
            families[family, default: []].append(model)
        }

        // Sort models within each family by ID
        for key in families.keys {
            families[key]?.sort { $0.id < $1.id }
        }

        return families
    }
}

// MARK: - Legacy Path Migration

extension Acervo {

    /// Migrates models from legacy intrusive-memory cache paths to the
    /// canonical `~/Library/SharedModels/` directory.
    ///
    /// Scans the four legacy subdirectories (`LLM`, `TTS`, `Audio`, `VLM`)
    /// under `~/Library/Caches/intrusive-memory/Models/` for directories
    /// containing `config.json`. Valid models are moved to `sharedModelsDirectory`
    /// if not already present there.
    ///
    /// Old parent directories are NOT deleted -- consumers clean up their own
    /// legacy references.
    ///
    /// - Returns: An array of `AcervoModel` instances for successfully migrated models.
    /// - Throws: `AcervoError.migrationFailed` if a filesystem error prevents migration.
    ///   Partial success is possible: some models may be migrated before an error occurs.
    public static func migrateFromLegacyPaths() throws -> [AcervoModel] {
        try migrateFromLegacyPaths(
            legacyBase: AcervoMigration.legacyBasePath,
            sharedBase: sharedModelsDirectory
        )
    }

    /// Migrates models from legacy paths to a shared base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real filesystem locations.
    ///
    /// - Parameters:
    ///   - legacyBase: The legacy base directory containing subdirectories
    ///     (`LLM`, `TTS`, `Audio`, `VLM`) with model directories.
    ///   - sharedBase: The destination base directory for migrated models.
    /// - Returns: An array of `AcervoModel` instances for successfully migrated models.
    /// - Throws: `AcervoError.migrationFailed` if a filesystem error prevents migration.
    static func migrateFromLegacyPaths(
        legacyBase: URL,
        sharedBase: URL
    ) throws -> [AcervoModel] {
        let fm = FileManager.default
        var migratedModels: [AcervoModel] = []

        // Scan each legacy subdirectory
        for subdirectory in AcervoMigration.legacySubdirectories {
            let subdirURL = legacyBase.appendingPathComponent(subdirectory)

            // Skip if the subdirectory doesn't exist
            guard fm.fileExists(atPath: subdirURL.path) else {
                continue
            }

            // List contents of the subdirectory
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: subdirURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                // Skip unreadable directories gracefully
                continue
            }

            for itemURL in contents {
                // Only consider directories
                guard let resourceValues = try? itemURL.resourceValues(
                    forKeys: [.isDirectoryKey]
                ), resourceValues.isDirectory == true else {
                    continue
                }

                // Must contain config.json to be a valid model
                let configURL = itemURL.appendingPathComponent("config.json")
                guard fm.fileExists(atPath: configURL.path) else {
                    continue
                }

                // The directory name is the slug
                let slug = itemURL.lastPathComponent

                // Determine destination path
                let destinationURL = sharedBase.appendingPathComponent(slug)

                // Skip if destination already exists (prefer existing copy)
                if fm.fileExists(atPath: destinationURL.path) {
                    continue
                }

                // Ensure the shared base directory exists
                do {
                    try fm.createDirectory(
                        at: sharedBase,
                        withIntermediateDirectories: true
                    )
                } catch {
                    throw AcervoError.migrationFailed(
                        source: itemURL.path,
                        reason: "Failed to create destination directory: \(error.localizedDescription)"
                    )
                }

                // Move the directory to the new location
                do {
                    try fm.moveItem(at: itemURL, to: destinationURL)
                } catch {
                    throw AcervoError.migrationFailed(
                        source: itemURL.path,
                        reason: "Failed to move directory: \(error.localizedDescription)"
                    )
                }

                // Build the model ID from the slug (reverse slugify: first "_" -> "/")
                guard let firstUnderscore = slug.firstIndex(of: "_") else {
                    continue
                }
                let org = String(slug[slug.startIndex..<firstUnderscore])
                let repo = String(slug[slug.index(after: firstUnderscore)...])
                let modelId = "\(org)/\(repo)"

                // Get metadata for the migrated model
                let attributes = try? fm.attributesOfItem(atPath: destinationURL.path)
                let downloadDate = (attributes?[.creationDate] as? Date) ?? Date()
                let size = (try? directorySize(at: destinationURL)) ?? 0

                let model = AcervoModel(
                    id: modelId,
                    path: destinationURL,
                    sizeBytes: size,
                    downloadDate: downloadDate
                )
                migratedModels.append(model)
            }
        }

        return migratedModels
    }
}

// MARK: - Directory Size Calculation

extension Acervo {

    /// Calculates the total size of all files within a directory, in bytes.
    ///
    /// Recursively enumerates all files in the directory tree and sums their
    /// `fileSize` resource values. Unreadable files are silently skipped.
    ///
    /// - Parameter url: The root directory URL to calculate size for.
    /// - Returns: The total size of all readable files in bytes.
    /// - Throws: Errors from `FileManager` if the directory cannot be enumerated.
    private static func directorySize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true } // Skip unreadable files
        ) else {
            return 0
        }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(
                forKeys: resourceKeys
            ) else {
                continue // Skip files whose resource values cannot be read
            }

            guard resourceValues.isRegularFile == true else {
                continue
            }

            totalSize += Int64(resourceValues.fileSize ?? 0)
        }

        return totalSize
    }
}

// MARK: - Download API

extension Acervo {

    /// Downloads specific files for a HuggingFace model to the canonical
    /// shared models directory.
    ///
    /// Validates the model ID format, creates the model directory if needed,
    /// and delegates file-level downloading to `AcervoDownloader`. Files that
    /// already exist at the destination are skipped unless `force` is `true`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format
    ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - files: An array of file names or relative paths within the model
    ///     repository (e.g., `["config.json", "speech_tokenizer/config.json"]`).
    ///   - token: An optional HuggingFace API token for gated model access.
    ///   - force: When `true`, re-downloads files even if they already exist.
    ///     Defaults to `false`.
    ///   - progress: An optional callback invoked periodically with download
    ///     progress. Must be `@Sendable` for Swift 6 strict concurrency.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   `AcervoError.directoryCreationFailed` if the model directory cannot be
    ///   created, or download-related errors from `AcervoDownloader`.
    public static func download(
        _ modelId: String,
        files: [String],
        token: String? = nil,
        force: Bool = false,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
    ) async throws {
        try await download(
            modelId,
            files: files,
            token: token,
            force: force,
            progress: progress,
            in: sharedModelsDirectory
        )
    }

    /// Downloads specific files for a HuggingFace model to the specified
    /// base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format.
    ///   - files: An array of file names or relative paths within the model repository.
    ///   - token: An optional HuggingFace API token for gated model access.
    ///   - force: When `true`, re-downloads files even if they already exist.
    ///   - progress: An optional progress callback.
    ///   - baseDirectory: The base directory to use instead of `sharedModelsDirectory`.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   or download-related errors from `AcervoDownloader`.
    static func download(
        _ modelId: String,
        files: [String],
        token: String? = nil,
        force: Bool = false,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
        in baseDirectory: URL
    ) async throws {
        // Validate model ID format (must contain exactly one "/")
        let slashCount = modelId.filter { $0 == "/" }.count
        guard slashCount == 1 else {
            throw AcervoError.invalidModelId(modelId)
        }

        // Compute destination directory
        let destination = baseDirectory.appendingPathComponent(slugify(modelId))

        // Create directory if needed
        try AcervoDownloader.ensureDirectory(at: destination)

        // Delegate to AcervoDownloader for actual file downloads
        try await AcervoDownloader.downloadFiles(
            modelId: modelId,
            files: files,
            destination: destination,
            token: token,
            force: force,
            progress: progress
        )
    }
}

// MARK: - Ensure Available

extension Acervo {

    /// Checks whether a model is available locally within a specified
    /// base directory by verifying the presence of `config.json`.
    ///
    /// This internal overload enables testing with temporary directories.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier.
    ///   - baseDirectory: The base directory to check for the model.
    /// - Returns: `true` if the model directory contains a `config.json` file.
    static func isModelAvailable(_ modelId: String, in baseDirectory: URL) -> Bool {
        let slug = slugify(modelId)
        let modelDir = baseDirectory.appendingPathComponent(slug)
        let configPath = modelDir.appendingPathComponent("config.json").path
        return FileManager.default.fileExists(atPath: configPath)
    }

    /// Ensures a model is available locally, downloading it if necessary.
    ///
    /// If the model is already available (has `config.json` in its directory),
    /// this method returns immediately without performing any downloads.
    /// Otherwise, it calls `download()` with `force: false`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format
    ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    ///   - files: An array of file names or relative paths within the model repository.
    ///   - token: An optional HuggingFace API token for gated model access.
    ///   - progress: An optional callback invoked periodically with download progress.
    ///     Must be `@Sendable` for Swift 6 strict concurrency.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   or download-related errors from `AcervoDownloader`.
    public static func ensureAvailable(
        _ modelId: String,
        files: [String],
        token: String? = nil,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
    ) async throws {
        try await ensureAvailable(
            modelId,
            files: files,
            token: token,
            progress: progress,
            in: sharedModelsDirectory
        )
    }

    /// Ensures a model is available locally within a specified base directory,
    /// downloading it if necessary.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format.
    ///   - files: An array of file names or relative paths within the model repository.
    ///   - token: An optional HuggingFace API token for gated model access.
    ///   - progress: An optional progress callback.
    ///   - baseDirectory: The base directory to use instead of `sharedModelsDirectory`.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   or download-related errors from `AcervoDownloader`.
    static func ensureAvailable(
        _ modelId: String,
        files: [String],
        token: String? = nil,
        progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
        in baseDirectory: URL
    ) async throws {
        // Check if model is already available (has config.json)
        if isModelAvailable(modelId, in: baseDirectory) {
            return
        }

        // Model not available -- download it
        try await download(
            modelId,
            files: files,
            token: token,
            force: false,
            progress: progress,
            in: baseDirectory
        )
    }
}

// MARK: - Delete Model

extension Acervo {

    /// Deletes a model's directory from the canonical shared models directory.
    ///
    /// Validates the model ID format, verifies the directory exists, then
    /// removes the entire model directory recursively.
    ///
    /// - Parameter modelId: A HuggingFace model identifier in "org/repo" format
    ///   (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   `AcervoError.modelNotFound` if the model directory does not exist.
    public static func deleteModel(_ modelId: String) throws {
        try deleteModel(modelId, in: sharedModelsDirectory)
    }

    /// Deletes a model's directory from the specified base directory.
    ///
    /// This internal overload enables testing with temporary directories
    /// without touching the real `sharedModelsDirectory`.
    ///
    /// - Parameters:
    ///   - modelId: A HuggingFace model identifier in "org/repo" format.
    ///   - baseDirectory: The base directory to use instead of `sharedModelsDirectory`.
    /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
    ///   `AcervoError.modelNotFound` if the model directory does not exist.
    static func deleteModel(_ modelId: String, in baseDirectory: URL) throws {
        // Validate model ID format (must contain exactly one "/")
        let slashCount = modelId.filter { $0 == "/" }.count
        guard slashCount == 1 else {
            throw AcervoError.invalidModelId(modelId)
        }

        let modelDir = baseDirectory.appendingPathComponent(slugify(modelId))

        // Verify directory exists
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw AcervoError.modelNotFound(modelId)
        }

        // Remove directory recursively
        try FileManager.default.removeItem(at: modelDir)
    }
}
