// Acervo.swift
// SwiftAcervo
//
// Static API namespace for shared AI model discovery and management.
//
// Acervo ("collection" / "repository" in Portuguese) provides a single
// canonical location for AI models across the intrusive-memory
// ecosystem. All model path resolution, availability checks, discovery,
// and download operations are accessed through static methods
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
  public static let version = "0.15.1-dev"

  /// The name of the environment variable that gates outbound HTTP fetches.
  ///
  /// When this variable is set to `"1"` in the process environment, every
  /// SwiftAcervo code path that would otherwise contact the CDN refuses the
  /// fetch and throws ``AcervoError/offlineModeActive`` instead. Read paths
  /// that only touch the local filesystem (e.g. ``modelDirectory(for:)``,
  /// ``isModelAvailable(_:)``, hydrate-from-cache) are unaffected.
  static let offlineModeEnvironmentVariable = "ACERVO_OFFLINE"

  /// `true` when the `ACERVO_OFFLINE` environment variable is set to `"1"`.
  ///
  /// Evaluated on every read; tests can toggle the variable with
  /// `setenv` / `unsetenv` between cases. Other values (including the empty
  /// string, `"true"`, and `"yes"`) do **not** activate offline mode — only
  /// the literal string `"1"` does, matching the documented contract for
  /// downstream consumers.
  static var isOfflineModeActive: Bool {
    ProcessInfo.processInfo.environment[offlineModeEnvironmentVariable] == "1"
  }
}

// MARK: - Availability

extension Acervo {

  /// Returns `true` when the model is **fully on disk and usable**, anchored
  /// against its cached CDN manifest.
  ///
  /// The check is strict and offline:
  ///
  /// 1. Load the manifest cached at
  ///    `{sharedModelsDirectory}/{slug}/.acervo-manifest.json`. If the
  ///    cached manifest is missing or fails its self-checksum, the method
  ///    returns `false`.
  /// 2. For every file declared in that manifest, verify the on-disk file
  ///    exists at the recorded byte size. Short-circuits on the first miss.
  ///
  /// This means a model directory containing only `config.json` (without a
  /// manifest cache, or with files smaller than the manifest declares) is
  /// **not** considered available — that state indicates a previous
  /// download that did not run to completion.
  ///
  /// This method never throws and never performs network I/O. For an
  /// "is the file just there?" probe that does not require a manifest, see
  /// `isModelConfigPresent(_:)` (the legacy loose check).
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format (e.g.,
  ///   "mlx-community/Qwen2.5-7B-Instruct-4bit").
  /// - Returns: `true` only if the cached manifest exists, self-validates,
  ///   and every file it declares is on disk at the recorded size.
  ///
  /// ```swift
  /// if Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit") {
  ///     print("Model is ready to use")
  /// }
  /// ```
  public static func isModelAvailable(_ modelId: String) -> Bool {
    isModelAvailable(modelId, in: sharedModelsDirectory)
  }

  /// Returns `true` when the model's `config.json` is present at the model
  /// root.
  ///
  /// **Warning:** Does NOT imply "model is usable." A directory containing
  /// only `config.json` (or a partial download) will satisfy this probe even
  /// though weights, tokenizer, and other declared files may be missing.
  /// Prefer `availability(_:)` or `isModelAvailable(_:)` for production use.
  /// This method exists as an explicit escape hatch for callers that
  /// genuinely only want to probe for `config.json` — for example, legacy
  /// integrations that pre-date the manifest cache.
  ///
  /// Never throws and never performs network I/O.
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format.
  /// - Returns: `true` iff `{sharedModelsDirectory}/{slug}/config.json`
  ///   exists.
  public static func isModelConfigPresent(_ modelId: String) -> Bool {
    guard let dir = try? modelDirectory(for: modelId) else {
      return false
    }
    let configPath = dir.appendingPathComponent("config.json").path
    return FileManager.default.fileExists(atPath: configPath)
  }

  /// Custom-base-directory overload of `isModelConfigPresent(_:)`.
  ///
  /// Internal test seam mirroring the public method's behavior against an
  /// arbitrary base directory.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - baseDirectory: The base directory to check.
  /// - Returns: `true` iff `{baseDirectory}/{slug}/config.json` exists.
  static func isModelConfigPresent(_ modelId: String, in baseDirectory: URL) -> Bool {
    let slug = slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    let configPath = modelDir.appendingPathComponent("config.json").path
    return FileManager.default.fileExists(atPath: configPath)
  }

  /// Checks whether a specific file exists within a model's directory.
  ///
  /// Supports files in subdirectories (e.g., "speech_tokenizer/config.json").
  /// This method never throws. If the model ID is invalid or the model
  /// directory does not exist, it returns `false`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format (e.g., "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16").
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

      // Must contain at least one of the three validity markers to be a real
      // model directory. Directories with NONE of these are empty stubs
      // (typically from cancelled downloads) and are excluded from the listing
      // without being removed from disk. Use `gcEmptyModelDirectories()` to
      // physically remove them.
      //
      //   - config.json     — standard transformers / MLX root marker
      //   - model_index.json — diffusers pipeline root marker
      //   - manifest.json   — EM-1 byte-equal CDN manifest artifact
      guard hasModelValidityMarker(in: itemURL, fm: fm) else {
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

  // MARK: - Empty-directory detection

  /// Returns `true` when the directory at `url` contains at least one of the
  /// three model validity markers (`config.json`, `model_index.json`,
  /// `manifest.json`).
  ///
  /// Used as the listing-time filter in `listModels(in:)` and as the
  /// retention criterion in `gcEmptyModelDirectories(in:)`.
  ///
  /// - Parameters:
  ///   - url: The model directory to probe.
  ///   - fm: The `FileManager` to use (injected to avoid redundant calls in
  ///     the tight listing loop).
  private static func hasModelValidityMarker(in url: URL, fm: FileManager) -> Bool {
    fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
      || fm.fileExists(atPath: url.appendingPathComponent("model_index.json").path)
      || fm.fileExists(atPath: url.appendingPathComponent(AcervoDownloader.manifestFilename).path)
  }

  // MARK: - Garbage collection

  /// Physically removes empty-stub model directories from the shared models
  /// directory.
  ///
  /// **Destructive** — this method permanently deletes directories from disk.
  /// Only directories that have **none** of the three model validity markers
  /// (`config.json`, `model_index.json`, `manifest.json`) are removed; any
  /// directory that carries at least one marker is left untouched regardless
  /// of its contents.
  ///
  /// The removal is per-directory atomic (each directory is deleted by a
  /// single `FileManager.removeItem(at:)` call). A directory that cannot be
  /// removed is silently skipped; its URL is not included in the returned
  /// list.
  ///
  /// - Returns: The URLs of every directory that was successfully removed.
  ///   Callers should log these for diagnostics.
  /// - Throws: Errors from `FileManager` if the shared models directory
  ///   cannot be read (e.g., does not exist yet — in which case the returned
  ///   array is empty).
  @discardableResult
  public static func gcEmptyModelDirectories() throws -> [URL] {
    try gcEmptyModelDirectories(in: sharedModelsDirectory)
  }

  /// Physically removes empty-stub model directories from the specified base
  /// directory.
  ///
  /// **Destructive** — see ``gcEmptyModelDirectories()`` for the full contract.
  /// This internal overload enables testing with temporary directories without
  /// touching the real `sharedModelsDirectory`.
  ///
  /// - Parameter baseDirectory: The directory to scan for empty-stub
  ///   subdirectories.
  /// - Returns: The URLs of every directory that was successfully removed.
  /// - Throws: `FileManager` errors from reading `baseDirectory`.
  @discardableResult
  static func gcEmptyModelDirectories(in baseDirectory: URL) throws -> [URL] {
    let fm = FileManager.default

    guard fm.fileExists(atPath: baseDirectory.path) else {
      return []
    }

    let contents = try fm.contentsOfDirectory(
      at: baseDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )

    var removed: [URL] = []
    for itemURL in contents {
      // Only operate on directories.
      guard
        let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
        resourceValues.isDirectory == true
      else {
        continue
      }

      // Keep any directory that has at least one validity marker.
      if hasModelValidityMarker(in: itemURL, fm: fm) {
        continue
      }

      // Directory has none of the three markers — it is a stub.
      // Attempt atomic removal; skip on failure (e.g., permission denied).
      do {
        try fm.removeItem(at: itemURL)
        removed.append(itemURL)
      } catch {
        // Silently skip — caller can check the returned list to see what was removed.
        _ = error
      }
    }

    return removed
  }

  /// Returns metadata for a single model identified by its model ID.
  ///
  /// Scans the shared models directory and returns the model whose ID matches
  /// the given identifier.
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
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
  ///   - modelId: A model identifier in "org/repo" format.
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

  /// Common organization prefixes that are stripped before computing
  /// edit distance, so that "Qwen2.5-7B" matches
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
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await download(
      modelId,
      files: files,
      force: force,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
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
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    // Validate model ID format (must contain exactly one "/")
    let slashCount = modelId.filter { $0 == "/" }.count
    guard slashCount == 1 else {
      throw AcervoError.invalidModelId(modelId)
    }

    // Lifecycle: snapshot wall-clock start and offline mode so the duration
    // measurement reflects the entire download operation including manifest
    // fetch and integrity verification. Payload construction is skipped when
    // no reporter is attached (hot-path discipline per requirements §5).
    let startTime = Date()
    if let telemetry {
      let offlineSnapshot = Acervo.isOfflineModeActive
      let requestedSnapshot = files
      await telemetry.capture(
        .downloadOperationStart(
          modelID: modelId,
          requestedFiles: requestedSnapshot,
          offlineMode: offlineSnapshot
        )
      )
    }

    // Compute destination directory
    let destination = baseDirectory.appendingPathComponent(slugify(modelId))

    // Create directory if needed
    try AcervoDownloader.ensureDirectory(at: destination, telemetry: telemetry)

    // Exclude model directory from iCloud backup — Apple requires that
    // large re-downloadable content must not be backed up.
    excludeFromBackup(baseDirectory)
    excludeFromBackup(destination)

    // Manifest-driven download with per-file integrity verification.
    // `session` is a test-only injection seam: when nil, AcervoDownloader's
    // default (`SecureDownloadSession.shared`) is used; when set, the
    // injected session intercepts both manifest and file requests.
    if let session {
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: files,
        destination: destination,
        force: force,
        progress: progress,
        session: session,
        telemetry: telemetry
      )
    } else {
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: files,
        destination: destination,
        force: force,
        progress: progress,
        telemetry: telemetry
      )
    }

    // Lifecycle: emit completion on the success path. `totalBytes` is reported
    // as 0 at this layer; consumers needing an exact byte total should sum
    // `componentDownloadComplete.actualBytes` events (those carry the
    // per-file ground truth from the integrity-verified stream).
    if let telemetry {
      let durationSeconds = Date().timeIntervalSince(startTime)
      await telemetry.capture(
        .downloadOperationComplete(
          modelID: modelId,
          totalBytes: 0,
          durationSeconds: durationSeconds
        )
      )
    }
  }
}

// MARK: - Ensure Available

extension Acervo {

  /// Strict, manifest-driven availability check against a custom base
  /// directory.
  ///
  /// Internal overload used by tests and by `ensureAvailable(_:in:)`. As
  /// of EM-2 this is intentionally kept STRICTER than the
  /// consumer-facing `availability(_:)` oracle: only Tier A (the EM-1
  /// byte-equal `<modelDir>/manifest.json`, with the legacy
  /// `.acervo-manifest.json` self-validating cache as a transitional
  /// fallback) is consulted. The Tier-C heuristic is deliberately NOT
  /// used here because it can flip `ensureAvailable`'s fast-path
  /// short-circuit on for a model that just had a partial download
  /// failure — the consumer expects the retry to try downloading again,
  /// not to silently accept a `config.json`-only stub as "available".
  ///
  /// `availability(_:)` (the public async read API) DOES use the full
  /// three-tier oracle including Tier C for the spec's false-negative
  /// fix. Consumers that probe with `availability(_:)` will see
  /// `.available` for a `config.json`-only model (Tier C); consumers
  /// that re-invoke `ensureAvailable` after a failure will still see
  /// the strict cached-manifest verdict here and re-attempt the
  /// download.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - baseDirectory: The base directory to check for the model.
  /// - Returns: `true` only when an authoritative local manifest is
  ///   present and every declared file is on disk at the recorded size.
  static func isModelAvailable(_ modelId: String, in baseDirectory: URL) -> Bool {
    let slug = slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    guard
      let manifest = ValidityOracle.loadLocalManifestEitherShape(
        modelId: modelId,
        modelDir: modelDir,
        baseDirectory: baseDirectory
      )
    else {
      return false
    }
    return IntegrityVerification.allManifestFilesPresentBySize(
      manifest: manifest,
      in: modelDir
    )
  }

  /// Ensures a model is available locally, downloading it if necessary.
  ///
  /// If the model is already available (the cached manifest is present and
  /// every declared file is on disk at the recorded byte size), this method
  /// returns immediately without performing any downloads. Otherwise, it
  /// calls `download()` with `force: false`.
  ///
  /// ## Concurrency: download deduplication
  ///
  /// This method participates in a process-wide in-flight registry
  /// (`InFlightDownloads`). When two callers invoke `ensureAvailable` for
  /// the same `modelId` concurrently, both await a SINGLE underlying
  /// download Task — the registry guarantees the work is performed exactly
  /// once. Both callers receive the same outcome (success or the same
  /// thrown error). The registry entry is cleared once the download Task
  /// completes (success or failure), so a subsequent call after the
  /// completion starts a fresh download.
  ///
  /// **Dedup key is `modelId`, NOT `(modelId, files)`.** A joiner that
  /// requests a different `files` subset rides on the originator's set:
  /// for example, if the originator requested `["config.json",
  /// "model.safetensors"]` and a joiner requested only `["config.json"]`,
  /// the joiner does not trigger an additional download of just
  /// `config.json` — it awaits the originator's two-file download and
  /// inherits both files on disk. This trade-off is intentional. The
  /// overwhelmingly common production caller passes `files: []` (i.e.
  /// "everything in the manifest"), in which case there is no observable
  /// difference. Callers that genuinely need disjoint per-file downloads
  /// for the same model must serialize themselves at the call site.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format
  ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - files: An array of file names or relative paths within the model.
  ///     Pass `[]` to download every file in the manifest.
  ///   - progress: An optional callback invoked periodically with download
  ///     progress. Must be `@Sendable` for Swift 6 strict concurrency.
  ///     When two callers dedup, only the originator's `progress` callback
  ///     receives ticks from the underlying download; joiners receive their
  ///     final outcome via the `await` but do not see per-tick callbacks.
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
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureAvailable(
      modelId,
      files: files,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Ensures a model is available locally within a specified base directory,
  /// downloading it if necessary.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`. It is the sole
  /// implementation of the dedup logic; the public `ensureAvailable(...)`
  /// forwards here. See the public overload's doc comment for the dedup
  /// contract.
  ///
  /// `session` is an internal test-injection seam (default `nil` uses
  /// `SecureDownloadSession.shared`). The public API does not surface it.
  static func ensureAvailable(
    _ modelId: String,
    files: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    // Fast path: model is already strictly available (cached manifest + all
    // files at recorded sizes). No download, no registry interaction.
    if isModelAvailable(modelId, in: baseDirectory) { return }

    // Wrap the caller's progress callback so each tick also publishes to
    // InFlightDownloads. The joiner's wrappedProgress closure is built but
    // never installed: only the originator's closure is wired into the
    // actual download (because only the originator's `start` runs).
    let wrappedProgress: (@Sendable (AcervoDownloadProgress) -> Void) = { p in
      Task { await InFlightDownloads.shared.publishProgress(p.overallProgress, for: modelId) }
      progress?(p)
    }

    // Capture by-value so the @Sendable `start` closure can reference them.
    let capturedFiles = files
    let capturedBase = baseDirectory
    let capturedTelemetry = telemetry
    let capturedSession = session

    let sharedTask = await InFlightDownloads.shared.task(for: modelId) {
      Task {
        // Clear the registry entry on BOTH the success and the failure path.
        // `defer` is synchronous; `finish` is async, so we re-launch it in a
        // Task. The next caller after a thrown error sees `contains == false`
        // and starts a fresh download.
        defer {
          Task { await InFlightDownloads.shared.finish(modelId) }
        }
        try await download(
          modelId,
          files: capturedFiles,
          force: false,
          progress: wrappedProgress,
          in: capturedBase,
          telemetry: capturedTelemetry,
          session: capturedSession
        )
      }
    }
    try await sharedTask.value
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
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await downloadComponent(
      componentId,
      force: force,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Downloads a registered component using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    guard let initialDescriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    if initialDescriptor.needsHydration {
      try await hydrateComponent(componentId, telemetry: telemetry)
    }

    guard let descriptor = ComponentRegistry.shared.component(componentId),
      descriptor.isHydrated
    else {
      throw AcervoError.componentNotHydrated(id: componentId)
    }

    let fileList = descriptor.files.map(\.relativePath)

    // Manifest-driven download with CDN integrity verification
    try await download(
      descriptor.repoId,
      files: fileList,
      force: force,
      progress: progress,
      in: baseDirectory,
      telemetry: telemetry
    )

    // Additional registry-level checksum verification
    let componentDir = baseDirectory.appendingPathComponent(
      slugify(descriptor.repoId)
    )
    for file in descriptor.files {
      guard let expectedHash = file.sha256 else { continue }
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      let actualHash = try IntegrityVerification.sha256(of: fileURL)
      if actualHash != expectedHash {
        try? FileManager.default.removeItem(at: fileURL)
        if let telemetry {
          await telemetry.capture(
            .errorThrown(
              phase: .fileDownloadIntegrity,
              errorDescription:
                "Registry-level SHA mismatch for \(file.relativePath): expected \(expectedHash), got \(actualHash)",
              modelID: descriptor.repoId,
              fileName: file.relativePath
            )
          )
        }
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
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureComponentReady(
      componentId,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Ensures a registered component is downloaded and ready, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    // Check registration first
    guard let initialDescriptor = ComponentRegistry.shared.component(componentId) else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .other,
            errorDescription: "Component not registered: \(componentId)",
            modelID: nil,
            fileName: nil
          )
        )
      }
      throw AcervoError.componentNotRegistered(componentId)
    }

    let startTime = Date()
    if let telemetry {
      await telemetry.capture(
        .componentResolveStart(
          componentID: componentId,
          repoID: initialDescriptor.repoId
        )
      )
    }

    if initialDescriptor.needsHydration {
      try await hydrateComponent(componentId, telemetry: telemetry)
    }

    // If already ready, emit cacheHit-style completion and no-op
    if isComponentReady(componentId, in: baseDirectory) {
      if let telemetry {
        let descriptor = ComponentRegistry.shared.component(componentId) ?? initialDescriptor
        let totalBytes = descriptor.files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) }
        await telemetry.capture(
          .componentResolveComplete(
            componentID: componentId,
            repoID: descriptor.repoId,
            fileCount: descriptor.files.count,
            totalBytes: totalBytes,
            cacheState: .alreadyReady,
            durationSeconds: Date().timeIntervalSince(startTime)
          )
        )
      }
      return
    }

    // Download the component (descriptor is now hydrated; downloadComponent will not re-hydrate)
    try await downloadComponent(
      componentId,
      force: false,
      progress: progress,
      in: baseDirectory,
      telemetry: telemetry
    )

    if let telemetry {
      let descriptor = ComponentRegistry.shared.component(componentId) ?? initialDescriptor
      let totalBytes = descriptor.files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) }
      await telemetry.capture(
        .componentResolveComplete(
          componentID: componentId,
          repoID: descriptor.repoId,
          fileCount: descriptor.files.count,
          totalBytes: totalBytes,
          cacheState: .downloaded,
          durationSeconds: Date().timeIntervalSince(startTime)
        )
      )
    }
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
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureComponentsReady(
      componentIds,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Ensures multiple registered components are downloaded and ready,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    for componentId in componentIds {
      try await ensureComponentReady(
        componentId,
        progress: progress,
        in: baseDirectory,
        telemetry: telemetry
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
      slugify(descriptor.repoId)
    )

    // If the directory doesn't exist, nothing to delete -- no-op
    guard FileManager.default.fileExists(atPath: componentDir.path) else {
      return
    }

    // R4: Remove only the files declared in this descriptor — never the entire
    // slug directory. Multiple components may share the same repoId (bundle shape),
    // each owning a distinct subset of files in the same slug directory. Removing
    // the whole directory would silently destroy sibling components' files.
    let fm = FileManager.default
    for file in descriptor.files {
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      // Use try? — a missing file (never downloaded, or already removed) is fine.
      try? fm.removeItem(at: fileURL)

      // Best-effort: prune the immediate parent directory if it is now empty,
      // walking up to (but not including) componentDir itself. This handles the
      // case where a file lives in a subfolder (e.g., "transformer/model.safetensors")
      // whose folder becomes empty after the last file in it is deleted.
      var parent = fileURL.deletingLastPathComponent()
      while parent.standardizedFileURL != componentDir.standardizedFileURL {
        guard let contents = try? fm.contentsOfDirectory(atPath: parent.path),
          contents.isEmpty
        else { break }
        try? fm.removeItem(at: parent)
        parent = parent.deletingLastPathComponent()
      }
    }

    // Remove the slug directory itself if it is now empty (all components deleted).
    if let contents = try? fm.contentsOfDirectory(atPath: componentDir.path),
      contents.isEmpty
    {
      try? fm.removeItem(at: componentDir)
    }
  }
}

// MARK: - Availability (three-state)

extension Acervo {

  /// Returns the three-state availability of the specified model.
  ///
  /// This is the canonical "is the model usable right now?" surface.
  /// As of EM-2 it routes through the three-tier validity oracle:
  ///
  ///   - Tier A: local byte-equal `<modelDir>/manifest.json` (or, for
  ///     pre-EM-1 downloads, the legacy `.acervo-manifest.json` cache).
  ///   - Tier B: in-memory CDN manifest cache from the slug-registry
  ///     work (populated by `availability(slug:url:)` /
  ///     `ensureAvailable(slug:url:)`).
  ///   - Tier C: heuristic — `config.json` OR `model_index.json`
  ///     present, AND every shard enumerated in
  ///     `model.safetensors.index.json`'s `weight_map` is on disk.
  ///
  /// When the oracle has an authoritative manifest (Tier A or B) but
  /// at least one declared file is missing or wrong-size, the method
  /// returns `.partial(missing: [...])` rather than `.available` or
  /// `.notAvailable`. This is the audited false-positive case
  /// (Qwen3-Coder-Next-4bit with `config.json` + a shard index but
  /// zero shards on disk).
  ///
  /// When the Tier-C heuristic confirms a model without a manifest
  /// (the FLUX.2 false-negative case: `model_index.json` plus all
  /// subdirectory shards present), the method returns `.available`.
  ///
  /// The in-flight download registry is consulted first: a download
  /// in progress always wins over disk state.
  ///
  /// This method never throws and never performs network I/O.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - verifyHashes: When `true`, after the presence-and-size pass
  ///     succeeds the oracle stream-SHA-256 each manifest file and
  ///     treats any mismatch as effectively missing. Default `false`.
  ///     Hash verification streams files in 4 MB chunks via
  ///     `CryptoKit.SHA256` and `FileHandle`, but the wall-clock cost is
  ///     proportional to total bytes on disk — multi-minute on a 22 GB
  ///     model. Reserve for explicit bit-rot audits, not interactive
  ///     UI use.
  /// - Returns: `.available`, `.downloading(progress:)`,
  ///   `.partial(missing: [...])`, or `.notAvailable`.
  public static func availability(
    _ modelId: String,
    verifyHashes: Bool = false
  ) async -> ModelAvailability {
    await availability(
      modelId,
      verifyHashes: verifyHashes,
      in: sharedModelsDirectory
    )
  }

  /// Custom-base-directory overload of `availability(_:verifyHashes:)`.
  ///
  /// Internal test seam mirroring the public method's behavior against
  /// an arbitrary base directory. Not annotated `public` so it does
  /// not widen the API surface.
  static func availability(
    _ modelId: String,
    verifyHashes: Bool = false,
    in baseDirectory: URL
  ) async -> ModelAvailability {
    // Observe the in-flight registry first: a download in progress wins
    // over any partial bytes that may already be on disk. The registry
    // is the sole source of `.downloading`-ness — a `.part` file with
    // no registered Task is treated as one of the oracle verdicts.
    if await InFlightDownloads.shared.contains(modelId) {
      let p = await InFlightDownloads.shared.progress(for: modelId) ?? 0.0
      return .downloading(progress: p)
    }

    let verdict = await ValidityOracle.evaluate(
      modelId: modelId,
      in: baseDirectory,
      verifyHashes: verifyHashes
    )
    switch verdict {
    case .available:
      return .available
    case .partial(let missing):
      return .partial(missing: missing)
    case .indeterminate:
      return .notAvailable
    }
  }
}

// MARK: - Availability (slug-keyed, multi-component aggregation)

extension Acervo {

  /// Returns the three-state availability for a slug, fetching the CDN
  /// manifest and aggregating across every component the slug declares.
  ///
  /// This is the slug-registry-mission entry point introduced in
  /// `slug-registry/S2`. Unlike the legacy ``availability(_:)``, which is
  /// strictly offline and reflects only what is cached on disk, this method
  /// fetches the manifest (via the manifest cache or the network if needed)
  /// to discover the component list, then fans out across every component to
  /// build the aggregate.
  ///
  /// ## Slug + URL resolution rule
  ///
  /// * If `url` is supplied, it is used verbatim as the manifest fetch URL.
  ///   The `slug` is treated purely as the on-disk directory key.
  /// * If `url` is `nil` and `slug` parses as `"org/repo"` (single forward
  ///   slash, non-empty halves), the canonical CDN manifest URL is derived
  ///   from the slug.
  /// * If `url` is `nil` and `slug` does NOT parse as `"org/repo"`, the
  ///   method throws ``AcervoError/urlRequiredForSlug(_:)``.
  /// * If manifest fetch returns a non-2xx status, the method throws
  ///   ``AcervoError/manifestFetchFailed(slug:status:)``.
  ///
  /// ## Aggregation
  ///
  /// Per-component states are collapsed via the same
  /// ``AvailabilityAggregator/aggregate(_:)`` helper that
  /// ``ensureAvailable(slug:url:files:progress:)`` (S3) consumes:
  ///
  /// * Every component `.available` → `.available`
  /// * Any component `.downloading` → `.downloading(weightedAverage)` where
  ///   the weight is the component's manifest-declared total bytes
  /// * Otherwise → `.notAvailable`
  ///
  /// ## Telemetry
  ///
  /// Exactly one ``AcervoTelemetryEvent/modelAvailabilityResolved(slug:manifestURL:componentCount:result:)``
  /// is emitted per call, regardless of call shape (derived URL, explicit
  /// URL, single-component, multi-component). Error paths emit
  /// ``AcervoTelemetryEvent/errorThrown(phase:errorDescription:modelID:fileName:)``
  /// instead and skip the availability-resolved event.
  ///
  /// - Parameters:
  ///   - slug: The slug-level identifier. May or may not look like
  ///     `"org/repo"`.
  ///   - url: An explicit manifest URL. `nil` triggers slug-based URL
  ///     derivation (which requires the slug to parse as `"org/repo"`).
  ///   - telemetry: Optional reporter. Exactly one event is captured per
  ///     successful call.
  /// - Returns: `.available`, `.downloading(progress:)`, or `.notAvailable`.
  /// - Throws: ``AcervoError/urlRequiredForSlug(_:)`` when the slug needs an
  ///   explicit URL and none was supplied;
  ///   ``AcervoError/manifestFetchFailed(slug:status:)`` when the manifest
  ///   fetch returns a non-2xx HTTP status;
  ///   ``AcervoError/networkError(_:)`` on transport failures;
  ///   ``AcervoError/manifestDecodingFailed(_:)`` on malformed JSON.
  public static func availability(
    slug: String,
    url: URL? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws -> ModelAvailability {
    try await availability(
      slug: slug,
      url: url,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Custom-base-directory and session-injecting overload of
  /// ``availability(slug:url:telemetry:)``.
  ///
  /// Internal test seam. `session` defaults to `nil` which delegates to
  /// ``SecureDownloadSession/shared``; tests inject a `MockURLProtocol`-backed
  /// session.
  static func availability(
    slug: String,
    url: URL? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws -> ModelAvailability {
    // ---- Resolve the manifest URL per the (slug, url?) contract. ----
    let manifestURL: URL
    if let explicit = url {
      manifestURL = explicit
    } else if isOrgRepoSlug(slug) {
      manifestURL = ManifestCache.derivedURL(forSlug: slug)
    } else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: "Slug '\(slug)' is not 'org/repo' and no URL was supplied.",
            modelID: slug,
            fileName: nil
          ))
      }
      throw AcervoError.urlRequiredForSlug(slug)
    }

    // ---- Fetch the manifest (cache-aware). ----
    let manifest: CDNManifest
    do {
      manifest = try await fetchSlugManifest(
        slug: slug,
        manifestURL: manifestURL,
        session: session
      )
    } catch let error as AcervoError {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: error.errorDescription ?? "\(error)",
            modelID: slug,
            fileName: nil
          ))
      }
      throw error
    } catch {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: error.localizedDescription,
            modelID: slug,
            fileName: nil
          ))
      }
      throw AcervoError.networkError(error)
    }

    // ---- Fan out across components and aggregate. ----
    // Single-component case: `components == [primaryRepo]` and the
    // per-component state is just the legacy repo-keyed availability for
    // that one repo. Multi-component case: each component is resolved
    // independently via the same legacy probe (offline; cached manifest +
    // InFlightDownloads). The aggregator collapses them.
    var inputs: [ComponentAvailabilityInput] = []
    inputs.reserveCapacity(manifest.components.count)
    for component in manifest.components {
      let state = await availability(component, in: baseDirectory)
      let bytes = await componentTotalBytes(component, in: baseDirectory)
      inputs.append(
        ComponentAvailabilityInput(availability: state, bytesTotal: bytes))
    }
    let aggregate = AvailabilityAggregator.aggregate(inputs)

    // Exactly one availability-resolved event per call. Branches all funnel
    // through this single emission point.
    if let telemetry {
      let resultLabel: String
      switch aggregate {
      case .available: resultLabel = "available"
      case .notAvailable: resultLabel = "notAvailable"
      case .downloading(let p): resultLabel = "downloading(\(p))"
      case .partial(let missing): resultLabel = "partial(missing: \(missing.count))"
      }
      await telemetry.capture(
        .modelAvailabilityResolved(
          slug: slug,
          manifestURL: manifestURL.absoluteString,
          componentCount: manifest.components.count,
          result: resultLabel
        ))
    }
    return aggregate
  }

  /// Returns `true` when `slug` parses as `"org/repo"` with a single
  /// non-empty forward-slash separator. Matches the resolution rule in
  /// ``availability(slug:url:telemetry:)``.
  static func isOrgRepoSlug(_ slug: String) -> Bool {
    let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return !parts[0].isEmpty && !parts[1].isEmpty
  }

  /// Best-effort total-bytes lookup for a component, used as the
  /// aggregator's per-component weight. Returns `nil` when the local
  /// cached manifest is absent for this component (in which case the
  /// aggregator falls back to equal-weight averaging across all
  /// components).
  static func componentTotalBytes(_ modelId: String, in baseDirectory: URL) async -> Int64? {
    guard let cached = AcervoDownloader.loadCachedManifest(for: modelId, in: baseDirectory)
    else {
      return nil
    }
    return cached.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
  }

  /// Cache-aware manifest fetch for the slug-keyed APIs. Hits
  /// ``ManifestCache/shared`` first; on miss, downloads from
  /// `manifestURL` and stores under both `(slug, nil)` and
  /// `(slug, manifestURL)` lookup shapes (which collapse to the same key
  /// when `manifestURL == derivedURL(forSlug: slug)`).
  ///
  /// Non-2xx responses throw ``AcervoError/manifestFetchFailed(slug:status:)``
  /// (NOT ``manifestDownloadFailed(statusCode:)``) so UI code can branch on
  /// slug-resolution failure specifically.
  static func fetchSlugManifest(
    slug: String,
    manifestURL: URL,
    session injectedSession: URLSession?
  ) async throws -> CDNManifest {
    // 1) Cache hit?
    if let cached = await ManifestCache.shared.manifest(slug: slug, url: manifestURL) {
      return cached
    }
    // 2) Network fetch.
    let session = injectedSession ?? SecureDownloadSession.shared
    let request = URLRequest(url: manifestURL)
    let data: Data
    let response: URLResponse
    (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AcervoError.manifestFetchFailed(slug: slug, status: http.statusCode)
    }
    let manifest: CDNManifest
    do {
      manifest = try JSONDecoder().decode(CDNManifest.self, from: data)
    } catch {
      throw AcervoError.manifestDecodingFailed(error)
    }
    // 3) Store under the explicit URL (preserves the (slug, explicitURL)
    // key) — when `manifestURL == derivedURL(forSlug: slug)`, this is
    // also the canonical (slug, nil) entry per ManifestCache's contract.
    await ManifestCache.shared.store(manifest, slug: slug, url: manifestURL)
    return manifest
  }
}

// MARK: - Ensure Available (slug-keyed, multi-component)

extension Acervo {

  /// Ensures all components of a slug-keyed model are available locally,
  /// downloading any that are missing.
  ///
  /// This is the slug-registry-mission entry point introduced in
  /// `slug-registry/S3`. It mirrors ``availability(slug:url:telemetry:)``'s
  /// slug + URL resolution rule and extends the existing
  /// ``ensureAvailable(_:files:progress:telemetry:)`` to multi-component models.
  ///
  /// ## Slug + URL resolution rule
  ///
  /// * If `url` is supplied, it is used verbatim as the manifest fetch URL.
  ///   The `slug` is treated purely as the on-disk directory key.
  /// * If `url` is `nil` and `slug` parses as `"org/repo"` (single forward
  ///   slash, non-empty halves), the canonical CDN manifest URL is derived
  ///   from the slug.
  /// * If `url` is `nil` and `slug` does NOT parse as `"org/repo"`, the
  ///   method throws ``AcervoError/urlRequiredForSlug(_:)``.
  /// * If manifest fetch returns a non-2xx status, the method throws
  ///   ``AcervoError/manifestFetchFailed(slug:status:)``.
  ///
  /// ## Multi-component download
  ///
  /// Once the slug's manifest is resolved, each entry in `manifest.components`
  /// is downloaded in sequence via the existing repo-keyed
  /// ``ensureAvailable(_:files:progress:telemetry:)`` path. Download
  /// deduplication (``InFlightDownloads``) is keyed by `(modelId, file)` via
  /// the per-component calls, preserving the existing dedup contract.
  ///
  /// ## Progress aggregation
  ///
  /// The `progress:` callback receives a bytes-weighted aggregate across all
  /// components, computed via ``AvailabilityAggregator/aggregate(_:)`` — the
  /// same helper that ``availability(slug:url:telemetry:)`` uses.  Every
  /// component tick fires the caller's callback with the current aggregate
  /// state, so the callback rate is proportional to the total download activity
  /// across components (not just the last-started one).
  ///
  /// ## HF-repo regression protection
  ///
  /// The existing ``ensureAvailable(_:files:progress:telemetry:)`` signature is
  /// preserved unchanged; it continues to use the repo-keyed path and is not
  /// rerouted through this method.
  ///
  /// - Parameters:
  ///   - slug: The slug-level identifier. May or may not look like `"org/repo"`.
  ///   - url: An explicit manifest URL. `nil` triggers slug-based URL derivation
  ///     (which requires the slug to parse as `"org/repo"`).
  ///   - files: An array of file names to download within each component. Pass
  ///     `[]` to download every file in each component's manifest.
  ///   - progress: An optional callback invoked periodically with the aggregate
  ///     download progress across all components. Must be `@Sendable`.
  ///   - telemetry: Optional reporter.
  /// - Throws: ``AcervoError/urlRequiredForSlug(_:)`` when the slug needs an
  ///   explicit URL and none was supplied;
  ///   ``AcervoError/manifestFetchFailed(slug:status:)`` when the manifest
  ///   fetch returns a non-2xx HTTP status;
  ///   any error from the underlying per-component download (network failures,
  ///   integrity errors, etc.).
  public static func ensureAvailable(
    slug: String,
    url: URL? = nil,
    files: [String],
    progress: (@Sendable (ModelAvailability) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureAvailable(
      slug: slug,
      url: url,
      files: files,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Internal test seam for ``ensureAvailable(slug:url:files:progress:telemetry:)``.
  ///
  /// Accepts a custom `baseDirectory` and injected `URLSession` so tests can
  /// drive the full path via `MockURLProtocol` without touching
  /// `sharedModelsDirectory` or the live CDN.
  static func ensureAvailable(
    slug: String,
    url: URL? = nil,
    files: [String],
    progress: (@Sendable (ModelAvailability) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    // ---- Resolve the manifest URL per the (slug, url?) contract. ----
    // (Identical resolution rule to availability(slug:url:in:telemetry:session:).)
    let manifestURL: URL
    if let explicit = url {
      manifestURL = explicit
    } else if isOrgRepoSlug(slug) {
      manifestURL = ManifestCache.derivedURL(forSlug: slug)
    } else {
      throw AcervoError.urlRequiredForSlug(slug)
    }

    // ---- Fetch the manifest (cache-aware). ----
    let manifest: CDNManifest
    do {
      manifest = try await fetchSlugManifest(
        slug: slug,
        manifestURL: manifestURL,
        session: session
      )
    } catch let error as AcervoError {
      throw error
    } catch {
      throw AcervoError.networkError(error)
    }

    // ---- Per-component state tracking for aggregate progress. ----
    // We maintain a mutable state vector — one entry per component — and
    // recompute the aggregate via AvailabilityAggregator.aggregate(_:) on
    // every callback tick. This is the same helper that availability(slug:url:)
    // uses, guaranteeing the two paths cannot drift.
    //
    // The vector is captured by reference (class box) so the per-component
    // progress closures can mutate it concurrently. We guard mutations with an
    // NSLock so the aggregate snapshot is always coherent.
    let componentIds = manifest.components
    let componentCount = componentIds.count

    // State box: holds the current (availability, bytesTotal) pair for each
    // component index.
    final class ComponentStateBox: @unchecked Sendable {
      var states: [ComponentAvailabilityInput]
      let lock = NSLock()
      init(count: Int) {
        states = Array(
          repeating: ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: nil),
          count: count
        )
      }
      func update(index: Int, availability: ModelAvailability, bytesTotal: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        states[index] = ComponentAvailabilityInput(
          availability: availability, bytesTotal: bytesTotal)
      }
      func snapshot() -> [ComponentAvailabilityInput] {
        lock.lock()
        defer { lock.unlock() }
        return states
      }
    }

    let stateBox = ComponentStateBox(count: componentCount)

    // ---- Download each component sequentially. ----
    for (index, componentId) in componentIds.enumerated() {
      // Determine the total bytes for this component (best-effort; used as
      // the aggregator weight). Read from the local cached manifest if present;
      // the actual bytes will be known after the first successful download.
      let componentBytesTotal = await componentTotalBytes(componentId, in: baseDirectory)

      // Build a per-component progress closure that:
      //   1. Updates the component's slot in the state box.
      //   2. Aggregates across all slots via AvailabilityAggregator.
      //   3. Fires the caller's progress callback with the aggregate.
      let capturedIndex = index
      let componentProgress: (@Sendable (AcervoDownloadProgress) -> Void)? = progress.map {
        outerProgress in
        let box = stateBox
        let total = componentBytesTotal
        return { @Sendable (p: AcervoDownloadProgress) in
          // Translate per-component AcervoDownloadProgress into a ModelAvailability
          // state for this component slot.
          let componentState: ModelAvailability = p.overallProgress >= 1.0
            ? .available : .downloading(progress: p.overallProgress)
          box.update(index: capturedIndex, availability: componentState, bytesTotal: total)
          let aggregate = AvailabilityAggregator.aggregate(box.snapshot())
          outerProgress(aggregate)
        }
      }

      // Mark this component as downloading in the state box before we start,
      // so that any aggregate snapshot taken before the first progress tick
      // reflects the fact that work is in flight.
      stateBox.update(
        index: index, availability: .downloading(progress: 0.0),
        bytesTotal: componentBytesTotal)
      if let progress {
        progress(AvailabilityAggregator.aggregate(stateBox.snapshot()))
      }

      // Delegate to the existing repo-keyed ensureAvailable, which handles:
      //   - Fast-path if already on disk (cached manifest + size check).
      //   - InFlightDownloads deduplication keyed by modelId.
      //   - Per-file SHA-256 verification.
      try await ensureAvailable(
        componentId,
        files: files,
        progress: componentProgress,
        in: baseDirectory,
        telemetry: telemetry,
        session: session
      )

      // Component finished: mark it as available.
      let finalBytes = await componentTotalBytes(componentId, in: baseDirectory)
        ?? componentBytesTotal
      stateBox.update(index: index, availability: .available, bytesTotal: finalBytes)
      if let progress {
        progress(AvailabilityAggregator.aggregate(stateBox.snapshot()))
      }
    }
  }
}
