// Acervo+Search.swift
// SwiftAcervo
//
// Combines two related search concerns:
//
//   §5 — Pattern matching (glob/substring search via findModels(matching:),
//        case-insensitive substring search across all model IDs)
//
//   §6 — Fuzzy search (Levenshtein edit-distance search via
//        findModels(fuzzyMatching:editDistance:) and closestModel(to:),
//        with organization prefix stripping and distance-based ranking)
//
// Both search variants operate on the listing produced by Acervo+Discovery.swift's
// listModels(_:in:) API. The pattern matcher is a simple substring filter;
// the fuzzy searcher computes edit distances and ranks by closeness. Both
// return results sorted by ID (or distance, then ID for fuzzy).

import Foundation

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
