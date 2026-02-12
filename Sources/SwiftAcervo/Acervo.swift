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
