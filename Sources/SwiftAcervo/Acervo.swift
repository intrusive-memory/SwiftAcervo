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
public enum Acervo {

  /// The current version of SwiftAcervo.
  public static let version = "0.5.1"
}

// MARK: - Path Resolution

extension Acervo {

  /// The App Group identifier for shared model storage across
  /// intrusive-memory apps. Intentionally not configurable by consumers.
  private static let appGroupIdentifier = "group.intrusive-memory.models"

  /// The subdirectory name within the container for model storage.
  private static let modelsSubdirectory = "SharedModels"

  /// Marks a URL as excluded from iCloud backup.
  ///
  /// Apple requires that large re-downloadable content (such as ML model
  /// weights) must not be backed up to iCloud. This method sets the
  /// `isExcludedFromBackup` resource value on the given URL.
  ///
  /// - Parameter url: A file or directory URL to exclude from backup.
  static func excludeFromBackup(_ url: URL) {
    var mutableURL = url
    try? mutableURL.setResourceValues(
      {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return values
      }())
  }

  /// The canonical base directory for all shared HuggingFace models.
  ///
  /// Resolves to the App Group container for `group.intrusive-memory.models`
  /// when the entitlement is available (sandboxed apps). Falls back to
  /// `Application Support/SwiftAcervo/SharedModels/` for non-sandboxed
  /// contexts (e.g., tests, CLI tools).
  ///
  /// All model directories are stored as direct children of this path,
  /// named using the slugified HuggingFace model ID.
  ///
  /// ```swift
  /// let baseDir = Acervo.sharedModelsDirectory
  /// // App Group: <container>/SharedModels/
  /// // Fallback:  ~/Library/Application Support/SwiftAcervo/SharedModels/
  /// ```
  public static var sharedModelsDirectory: URL {
    if let groupURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) {
      return groupURL.appendingPathComponent(modelsSubdirectory)
    }
    // Fallback for non-sandboxed or non-entitled contexts
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return
      appSupport
      .appendingPathComponent("SwiftAcervo")
      .appendingPathComponent(modelsSubdirectory)
  }

  /// Converts a HuggingFace model ID to a filesystem-safe directory name.
  ///
  /// Replaces all "/" characters with "_". This is the canonical transformation
  /// used to derive directory names from HuggingFace model identifiers.
  ///
  /// - Parameter modelId: A HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  /// - Returns: The slugified form (e.g., "mlx-community_Qwen2.5-7B-Instruct-4bit").
  ///   Returns an empty string if the input is empty.
  ///
  /// ```swift
  /// let slug = Acervo.slugify("mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// // "mlx-community_Qwen2.5-7B-Instruct-4bit"
  /// ```
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
  ///
  /// ```swift
  /// let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// // <sharedModelsDirectory>/mlx-community_Qwen2.5-7B-Instruct-4bit/
  /// ```
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
  ///
  /// ```swift
  /// if Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit") {
  ///     print("Model is ready to use")
  /// }
  /// ```
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
  ///
  /// ```swift
  /// let hasTokenizer = Acervo.modelFileExists(
  ///     "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
  ///     fileName: "speech_tokenizer/config.json"
  /// )
  /// ```
  public static func modelFileExists(_ modelId: String, fileName: String) -> Bool {
    guard let dir = try? modelDirectory(for: modelId) else {
      return false
    }
    let filePath = dir.appendingPathComponent(fileName).path
    return FileManager.default.fileExists(atPath: filePath)
  }

  /// Checks whether a specific file exists within a model's directory,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func modelFileExists(
    _ modelId: String,
    fileName: String,
    in baseDirectory: URL
  ) -> Bool {
    let slug = slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    let filePath = modelDir.appendingPathComponent(fileName).path
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
  ///
  /// ```swift
  /// let models = try Acervo.listModels()
  /// for model in models {
  ///     print("\(model.id): \(model.formattedSize)")
  /// }
  /// ```
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
      guard
        let resourceValues = try? itemURL.resourceValues(
          forKeys: [.isDirectoryKey]
        ), resourceValues.isDirectory == true
      else {
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
        continue  // Skip directories without underscore (invalid slug)
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
  ///
  /// ```swift
  /// let model = try Acervo.modelInfo("mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// print("Size: \(model.formattedSize), Downloaded: \(model.downloadDate)")
  /// ```
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
  ///
  /// ```swift
  /// let qwenModels = try Acervo.findModels(matching: "Qwen")
  /// // Returns all models whose IDs contain "Qwen" (case-insensitive)
  /// ```
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
  ///
  /// ```swift
  /// let matches = try Acervo.findModels(fuzzyMatching: "Qwen2.5-7B", editDistance: 10)
  /// // Returns models with edit distance <= 10 from "Qwen2.5-7B"
  /// ```
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
  ///
  /// ```swift
  /// if let closest = try Acervo.closestModel(to: "Qwen2.5-7B-Instruct") {
  ///     print("Did you mean: \(closest.id)?")
  /// }
  /// ```
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
  ///
  /// ```swift
  /// let families = try Acervo.modelFamilies()
  /// for (family, models) in families {
  ///     print("\(family): \(models.count) variant(s)")
  /// }
  /// ```
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
  /// canonical `sharedModelsDirectory`.
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
  ///
  /// ```swift
  /// let migrated = try Acervo.migrateFromLegacyPaths()
  /// print("Migrated \(migrated.count) model(s) to SharedModels")
  /// ```
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
        // Skip symlinks - only migrate actual directories
        guard
          let resourceValues = try? itemURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
          ), resourceValues.isDirectory == true,
          resourceValues.isSymbolicLink != true
        else {
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

    guard
      let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in true }  // Skip unreadable files
      )
    else {
      return 0
    }

    var totalSize: Int64 = 0

    for case let fileURL as URL in enumerator {
      guard
        let resourceValues = try? fileURL.resourceValues(
          forKeys: resourceKeys
        )
      else {
        continue  // Skip files whose resource values cannot be read
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

  /// Downloads specific files for a model from the CDN.
  ///
  /// Validates the model ID format, fetches the CDN manifest, creates
  /// the model directory if needed, and downloads each file with
  /// per-file SHA-256 verification. Files that already exist at the
  /// destination and match the manifest size are skipped unless
  /// `force` is `true`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format
  ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - files: An array of file names or relative paths within the model
  ///     (e.g., `["config.json", "speech_tokenizer/config.json"]`).
  ///   - force: When `true`, re-downloads files even if they already exist.
  ///     Defaults to `false`.
  ///   - progress: An optional callback invoked periodically with download
  ///     progress. Must be `@Sendable` for Swift 6 strict concurrency.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   `AcervoError.directoryCreationFailed` if the model directory cannot be
  ///   created, manifest errors if the CDN manifest is invalid, or
  ///   download/verification errors from `AcervoDownloader`.
  ///
  /// ```swift
  /// try await Acervo.download(
  ///     "mlx-community/Qwen2.5-7B-Instruct-4bit",
  ///     files: ["config.json", "tokenizer.json"],
  ///     progress: { p in print("Progress: \(p.overallProgress)") }
  /// )
  /// ```
  public static func download(
    _ modelId: String,
    files: [String],
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    try await download(
      modelId,
      files: files,
      force: force,
      progress: progress,
      in: sharedModelsDirectory
    )
  }

  /// Downloads specific files for a model to the specified base directory.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - files: An array of file names or relative paths within the model.
  ///   - force: When `true`, re-downloads files even if they already exist.
  ///   - progress: An optional progress callback.
  ///   - baseDirectory: The base directory to use instead of `sharedModelsDirectory`.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   or download/manifest-related errors from `AcervoDownloader`.
  static func download(
    _ modelId: String,
    files: [String],
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

    // Exclude model directory from iCloud backup — Apple requires that
    // large re-downloadable content must not be backed up.
    excludeFromBackup(baseDirectory)
    excludeFromBackup(destination)

    // Manifest-driven download with per-file integrity verification
    try await AcervoDownloader.downloadFiles(
      modelId: modelId,
      requestedFiles: files,
      destination: destination,
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
  ///   - modelId: A model identifier in "org/repo" format
  ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - files: An array of file names or relative paths within the model.
  ///   - progress: An optional callback invoked periodically with download progress.
  ///     Must be `@Sendable` for Swift 6 strict concurrency.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   or download/manifest-related errors from `AcervoDownloader`.
  ///
  /// ```swift
  /// try await Acervo.ensureAvailable(
  ///     "mlx-community/Qwen2.5-7B-Instruct-4bit",
  ///     files: ["config.json", "model.safetensors"]
  /// )
  /// // Model is now guaranteed to be available locally
  /// ```
  public static func ensureAvailable(
    _ modelId: String,
    files: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    try await ensureAvailable(
      modelId,
      files: files,
      progress: progress,
      in: sharedModelsDirectory
    )
  }

  /// Ensures a model is available locally within a specified base directory,
  /// downloading it if necessary.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`.
  static func ensureAvailable(
    _ modelId: String,
    files: [String],
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
  ///
  /// ```swift
  /// try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// ```
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

// MARK: - Component Registration

extension Acervo {

  /// Registers a component descriptor with the global registry.
  ///
  /// Idempotent: re-registering the same ID updates the entry, applying
  /// deduplication rules per REQUIREMENTS A1.2. If the same `id` is registered
  /// with a different `huggingFaceRepo` or `files`, a warning is logged and
  /// the last registration wins. Metadata dictionaries are merged (newer keys
  /// overwrite on conflict). `estimatedSizeBytes` and `minimumMemoryBytes`
  /// take the max of both values.
  ///
  /// Thread-safe: may be called from any thread or task.
  ///
  /// - Parameter descriptor: The component descriptor to register.
  ///
  /// ```swift
  /// Acervo.register(ComponentDescriptor(
  ///     id: "t5-xxl-encoder-int4",
  ///     type: .encoder,
  ///     displayName: "T5-XXL Text Encoder (int4)",
  ///     huggingFaceRepo: "intrusive-memory/t5-xxl-int4-mlx",
  ///     files: [ComponentFile(relativePath: "model.safetensors")],
  ///     estimatedSizeBytes: 1_200_000_000,
  ///     minimumMemoryBytes: 2_400_000_000
  /// ))
  /// ```
  public static func register(_ descriptor: ComponentDescriptor) {
    ComponentRegistry.shared.register(descriptor)
  }

  /// Registers multiple component descriptors at once.
  ///
  /// Each descriptor is registered individually, applying the same
  /// deduplication rules as `register(_:)`.
  ///
  /// - Parameter descriptors: The component descriptors to register.
  public static func register(_ descriptors: [ComponentDescriptor]) {
    ComponentRegistry.shared.register(descriptors)
  }

  /// Removes a component registration by its ID.
  ///
  /// This does NOT delete downloaded files from disk. The component
  /// simply stops appearing in catalog queries. If the ID is not
  /// registered, this is a no-op.
  ///
  /// - Parameter componentId: The ID of the component to unregister.
  public static func unregister(_ componentId: String) {
    ComponentRegistry.shared.unregister(componentId)
  }
}

// MARK: - Component Catalog

extension Acervo {

  /// Returns all registered component descriptors (whether downloaded or not).
  ///
  /// This is the "what exists in the world?" API. A UI can use this to
  /// show all known components regardless of download status.
  ///
  /// - Returns: An array of all registered descriptors, in no particular order.
  public static func registeredComponents() -> [ComponentDescriptor] {
    ComponentRegistry.shared.allComponents()
  }

  /// Returns all registered components of the specified type.
  ///
  /// - Parameter type: The component type to filter by (e.g., `.encoder`, `.backbone`).
  /// - Returns: An array of matching descriptors.
  public static func registeredComponents(ofType type: ComponentType) -> [ComponentDescriptor] {
    ComponentRegistry.shared.components(ofType: type)
  }

  /// Looks up a specific component by its ID.
  ///
  /// - Parameter id: The component ID to look up (e.g., "t5-xxl-encoder-int4").
  /// - Returns: The matching `ComponentDescriptor`, or `nil` if not registered.
  public static func component(_ id: String) -> ComponentDescriptor? {
    ComponentRegistry.shared.component(id)
  }

  /// Checks if a registered component is fully downloaded and available on disk.
  ///
  /// For each file in the component's descriptor:
  /// - Verifies the file exists at the expected path
  /// - If `expectedSizeBytes` is declared, verifies the actual file size matches
  ///
  /// Returns `false` if the component is not registered or any file is missing/wrong size.
  ///
  /// - Parameter id: The component ID to check.
  /// - Returns: `true` if all declared files are present with correct sizes.
  public static func isComponentReady(_ id: String) -> Bool {
    isComponentReady(id, in: sharedModelsDirectory)
  }

  /// Checks if a registered component is fully downloaded, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`.
  ///
  /// - Parameters:
  ///   - id: The component ID to check.
  ///   - baseDirectory: The base directory to resolve component paths against.
  /// - Returns: `true` if all declared files are present with correct sizes.
  static func isComponentReady(_ id: String, in baseDirectory: URL) -> Bool {
    guard let descriptor = ComponentRegistry.shared.component(id) else {
      return false
    }

    let fm = FileManager.default
    let componentDir = baseDirectory.appendingPathComponent(slugify(descriptor.huggingFaceRepo))

    for file in descriptor.files {
      let filePath = componentDir.appendingPathComponent(file.relativePath).path
      guard fm.fileExists(atPath: filePath) else {
        return false
      }

      // If expected size is declared, verify it matches
      if let expectedSize = file.expectedSizeBytes {
        guard let attrs = try? fm.attributesOfItem(atPath: filePath),
          let actualSize = attrs[.size] as? Int64,
          actualSize == expectedSize
        else {
          return false
        }
      }
    }

    return true
  }

  /// Returns all registered components that are not yet downloaded.
  ///
  /// Filters `registeredComponents()` to those where `isComponentReady` is `false`.
  ///
  /// - Returns: An array of component descriptors for components awaiting download.
  public static func pendingComponents() -> [ComponentDescriptor] {
    pendingComponents(in: sharedModelsDirectory)
  }

  /// Returns all registered components that are not yet downloaded,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameter baseDirectory: The base directory to resolve component paths against.
  /// - Returns: An array of component descriptors for components awaiting download.
  static func pendingComponents(in baseDirectory: URL) -> [ComponentDescriptor] {
    registeredComponents().filter { !isComponentReady($0.id, in: baseDirectory) }
  }

  /// Returns the total catalog size split between downloaded and pending components.
  ///
  /// Sums `estimatedSizeBytes` for ready components (downloaded) and
  /// not-ready components (pending). This allows a UI to display something
  /// like "3 of 7 components downloaded, 4.2 GB cached, 8.1 GB available."
  ///
  /// - Returns: A tuple of `(downloaded: Int64, pending: Int64)` byte counts.
  public static func totalCatalogSize() -> (downloaded: Int64, pending: Int64) {
    totalCatalogSize(in: sharedModelsDirectory)
  }

  /// Returns the total catalog size split between downloaded and pending components,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameter baseDirectory: The base directory to resolve component paths against.
  /// - Returns: A tuple of `(downloaded: Int64, pending: Int64)` byte counts.
  static func totalCatalogSize(in baseDirectory: URL) -> (downloaded: Int64, pending: Int64) {
    var downloaded: Int64 = 0
    var pending: Int64 = 0

    for descriptor in registeredComponents() {
      if isComponentReady(descriptor.id, in: baseDirectory) {
        downloaded += descriptor.estimatedSizeBytes
      } else {
        pending += descriptor.estimatedSizeBytes
      }
    }

    return (downloaded: downloaded, pending: pending)
  }
}

// MARK: - Integrity Verification

extension Acervo {

  /// Verifies the integrity of a downloaded component's files.
  ///
  /// For each file with a declared SHA-256 checksum, computes the actual
  /// hash and compares it to the expected value. Files without declared
  /// checksums are skipped.
  ///
  /// - Parameter componentId: The ID of the component to verify.
  /// - Returns: `true` if all checksums pass (or if no checksums are declared).
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  /// - Throws: `AcervoError.componentNotDownloaded` if any required files are missing.
  public static func verifyComponent(_ componentId: String) throws -> Bool {
    try verifyComponent(componentId, in: sharedModelsDirectory)
  }

  /// Verifies the integrity of a downloaded component's files,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameters:
  ///   - componentId: The ID of the component to verify.
  ///   - baseDirectory: The base directory to resolve component paths against.
  /// - Returns: `true` if all checksums pass (or if no checksums are declared).
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  /// - Throws: `AcervoError.componentNotDownloaded` if any required files are missing.
  static func verifyComponent(_ componentId: String, in baseDirectory: URL) throws -> Bool {
    guard let descriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    let componentDir = baseDirectory.appendingPathComponent(slugify(descriptor.huggingFaceRepo))

    // Check that all files exist first
    let fm = FileManager.default
    for file in descriptor.files {
      let filePath = componentDir.appendingPathComponent(file.relativePath).path
      guard fm.fileExists(atPath: filePath) else {
        throw AcervoError.componentNotDownloaded(componentId)
      }
    }

    // Verify checksums
    for file in descriptor.files {
      let result = try IntegrityVerification.verify(file: file, in: componentDir)
      if !result {
        return false
      }
    }

    return true
  }

  /// Verifies all downloaded components and returns the IDs of any that fail.
  ///
  /// Iterates over all registered components. Components that are not downloaded
  /// are skipped (they are not failures -- they are simply not yet available).
  /// Only components whose files are present but fail checksum verification
  /// are included in the returned array.
  ///
  /// - Returns: An array of component IDs that failed integrity verification.
  ///   Empty if all pass (or if no components are registered/downloaded).
  /// - Throws: Errors from file I/O during hash computation.
  public static func verifyAllComponents() throws -> [String] {
    try verifyAllComponents(in: sharedModelsDirectory)
  }

  /// Verifies all downloaded components using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameter baseDirectory: The base directory to resolve component paths against.
  /// - Returns: An array of component IDs that failed integrity verification.
  /// - Throws: Errors from file I/O during hash computation.
  static func verifyAllComponents(in baseDirectory: URL) throws -> [String] {
    var failures: [String] = []

    for descriptor in registeredComponents() {
      // Skip components that are not downloaded
      guard isComponentReady(descriptor.id, in: baseDirectory) else {
        continue
      }

      // Verify this downloaded component
      let passed = try verifyComponent(descriptor.id, in: baseDirectory)
      if !passed {
        failures.append(descriptor.id)
      }
    }

    return failures
  }
}

// MARK: - Component Downloads

extension Acervo {

  /// Downloads a registered component using the registry's file list and CDN manifest.
  ///
  /// The caller does not need to specify which files to download -- the registry
  /// knows. The CDN manifest provides SHA-256 checksums for per-file verification
  /// during download. Registry-level checksums are verified as an additional check.
  ///
  /// - Parameters:
  ///   - componentId: The ID of the registered component to download.
  ///   - force: When `true`, re-downloads files even if they already exist. Defaults to `false`.
  ///   - progress: A callback invoked periodically with download progress.
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  ///   `AcervoError.integrityCheckFailed` if a downloaded file fails checksum verification.
  public static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    try await downloadComponent(
      componentId,
      force: force,
      progress: progress,
      in: sharedModelsDirectory
    )
  }

  /// Downloads a registered component using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL
  ) async throws {
    guard let descriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    let fileList = descriptor.files.map(\.relativePath)

    // Manifest-driven download with CDN integrity verification
    try await download(
      descriptor.huggingFaceRepo,
      files: fileList,
      force: force,
      progress: progress,
      in: baseDirectory
    )

    // Additional registry-level checksum verification
    let componentDir = baseDirectory.appendingPathComponent(
      slugify(descriptor.huggingFaceRepo)
    )
    for file in descriptor.files {
      guard let expectedHash = file.sha256 else { continue }
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      let actualHash = try IntegrityVerification.sha256(of: fileURL)
      if actualHash != expectedHash {
        try? FileManager.default.removeItem(at: fileURL)
        throw AcervoError.integrityCheckFailed(
          file: file.relativePath,
          expected: expectedHash,
          actual: actualHash
        )
      }
    }
  }

  /// Ensures a registered component is downloaded and ready.
  ///
  /// If the component is already fully downloaded and verified (via `isComponentReady`),
  /// this method returns immediately without performing any downloads. Otherwise,
  /// it downloads the component using the registry's file list.
  ///
  /// - Parameters:
  ///   - componentId: The ID of the registered component.
  ///   - progress: A callback invoked periodically with download progress.
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  public static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    try await ensureComponentReady(
      componentId,
      progress: progress,
      in: sharedModelsDirectory
    )
  }

  /// Ensures a registered component is downloaded and ready, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL
  ) async throws {
    // Check registration first
    guard ComponentRegistry.shared.component(componentId) != nil else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    // If already ready, no-op
    if isComponentReady(componentId, in: baseDirectory) {
      return
    }

    // Download the component
    try await downloadComponent(
      componentId,
      force: false,
      progress: progress,
      in: baseDirectory
    )
  }

  /// Ensures multiple registered components are downloaded and ready.
  ///
  /// Iterates through the component IDs and ensures each one is ready,
  /// downloading any that are missing. Components already cached are skipped.
  ///
  /// - Parameters:
  ///   - componentIds: The IDs of the registered components to ensure.
  ///   - progress: A callback invoked periodically with download progress.
  /// - Throws: `AcervoError.componentNotRegistered` if any ID is not in the registry.
  public static func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil
  ) async throws {
    try await ensureComponentsReady(
      componentIds,
      progress: progress,
      in: sharedModelsDirectory
    )
  }

  /// Ensures multiple registered components are downloaded and ready,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL
  ) async throws {
    for componentId in componentIds {
      try await ensureComponentReady(
        componentId,
        progress: progress,
        in: baseDirectory
      )
    }
  }
}

// MARK: - Component Deletion

extension Acervo {

  /// Deletes a downloaded component's files from disk.
  ///
  /// Does NOT unregister the component -- it remains in the registry as
  /// "not downloaded." If the component is registered but not downloaded,
  /// this is a no-op (nothing to delete).
  ///
  /// - Parameter componentId: The ID of the registered component to delete.
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  public static func deleteComponent(_ componentId: String) throws {
    try deleteComponent(componentId, in: sharedModelsDirectory)
  }

  /// Deletes a downloaded component's files from disk, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func deleteComponent(_ componentId: String, in baseDirectory: URL) throws {
    guard let descriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    let componentDir = baseDirectory.appendingPathComponent(
      slugify(descriptor.huggingFaceRepo)
    )

    // If the directory doesn't exist, nothing to delete -- no-op
    guard FileManager.default.fileExists(atPath: componentDir.path) else {
      return
    }

    // Remove the entire component directory
    try FileManager.default.removeItem(at: componentDir)
  }
}
