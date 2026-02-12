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
