// LevenshteinDistance.swift
// SwiftAcervo
//
// Levenshtein edit distance algorithm for fuzzy model name matching.
// Uses standard dynamic programming with case-insensitive comparison.

/// Computes the Levenshtein edit distance between two strings.
///
/// The Levenshtein distance is the minimum number of single-character edits
/// (insertions, deletions, or substitutions) required to change one string
/// into the other. Comparison is case-insensitive.
///
/// - Parameters:
///   - s1: The first string.
///   - s2: The second string.
/// - Returns: The edit distance between `s1` and `s2`.
func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
    // Lowercase both inputs for case-insensitive comparison
    let a = Array(s1.lowercased())
    let b = Array(s2.lowercased())

    let m = a.count
    let n = b.count

    // Handle empty string edge cases
    if m == 0 { return n }
    if n == 0 { return m }

    // Create a 2D matrix of size (m+1) x (n+1)
    // dp[i][j] = edit distance between a[0..<i] and b[0..<j]
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

    // Base cases: transforming from/to empty string
    for i in 0...m {
        dp[i][0] = i
    }
    for j in 0...n {
        dp[0][j] = j
    }

    // Fill the matrix
    for i in 1...m {
        for j in 1...n {
            if a[i - 1] == b[j - 1] {
                // Characters match: no edit needed
                dp[i][j] = dp[i - 1][j - 1]
            } else {
                // Minimum of insertion, deletion, or substitution
                let insertion = dp[i][j - 1] + 1
                let deletion = dp[i - 1][j] + 1
                let substitution = dp[i - 1][j - 1] + 1
                dp[i][j] = min(insertion, min(deletion, substitution))
            }
        }
    }

    return dp[m][n]
}
