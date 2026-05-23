// Acervo+Discovery.swift
// SwiftAcervo
//
// Combines three related discovery concerns:
//
//   §4 — Model listing + GC (listing, filtering, and garbage-collecting the
//        shared models directory; includes the EM-3 validity-marker filter
//        and `gcEmptyModelDirectories` housekeeping API)
//
//   §7 — Model families (grouping models by family name for UI consumers)
//
//   §8 — Directory size calculation (private helper used exclusively by
//        the listing path above; private here rather than internal because
//        no other source file references it)
//
// All three sub-concerns are tightly coupled: families delegate to listing,
// listing delegates to the directory-size helper, and all three concern
// themselves with the shared models directory layout. Collapsing them into
// one file keeps the concern boundary clean.

import Foundation

// MARK: - Model Listing and GC

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

  // MARK: - Model Families

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

  // MARK: - Directory Size Calculation

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
