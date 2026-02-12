import Foundation

/// Metadata for a downloaded HuggingFace model.
///
/// Represents a model stored in the shared models directory with its
/// HuggingFace identifier, local filesystem path, size, and download date.
/// Conforms to `Identifiable` (keyed by HuggingFace ID), `Equatable`,
/// `Codable`, and `Sendable`.
///
/// ```swift
/// let model = try Acervo.modelInfo("mlx-community/Qwen2.5-7B-Instruct-4bit")
/// print(model.formattedSize)  // "4.4 GB"
/// print(model.slug)           // "mlx-community_Qwen2.5-7B-Instruct-4bit"
/// print(model.baseName)       // "Qwen2.5"
/// print(model.familyName)     // "mlx-community/Qwen2.5"
/// ```
public struct AcervoModel: Identifiable, Equatable, Codable, Sendable {

    /// The HuggingFace model identifier (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
    public let id: String

    /// The local filesystem URL of the model directory.
    public let path: URL

    /// The total size of all files in the model directory, in bytes.
    public let sizeBytes: Int64

    /// The date when the model was downloaded (directory creation date).
    public let downloadDate: Date

    /// Creates a new model metadata instance.
    ///
    /// - Parameters:
    ///   - id: The HuggingFace model identifier.
    ///   - path: The local filesystem URL of the model directory.
    ///   - sizeBytes: The total size of all files in bytes.
    ///   - downloadDate: The date the model was downloaded.
    public init(
        id: String,
        path: URL,
        sizeBytes: Int64,
        downloadDate: Date
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.downloadDate = downloadDate
    }

    // MARK: - Computed Properties

    /// A human-readable representation of the model's size on disk.
    ///
    /// Formats bytes using standard units:
    /// - Less than 1 KB: "N bytes"
    /// - Less than 1 MB: "N.N KB"
    /// - Less than 1 GB: "N.N MB"
    /// - 1 GB or more: "N.N GB"
    public var formattedSize: String {
        let bytes = Double(sizeBytes)
        let kb = 1024.0
        let mb = kb * 1024.0
        let gb = mb * 1024.0

        if bytes < kb {
            return "\(sizeBytes) bytes"
        } else if bytes < mb {
            return String(format: "%.1f KB", bytes / kb)
        } else if bytes < gb {
            return String(format: "%.1f MB", bytes / mb)
        } else {
            return String(format: "%.1f GB", bytes / gb)
        }
    }

    /// The directory name form of the model ID, with "/" replaced by "_".
    ///
    /// For example, "mlx-community/Qwen2.5-7B-Instruct-4bit" becomes
    /// "mlx-community_Qwen2.5-7B-Instruct-4bit".
    public var slug: String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - Name Parsing

    /// The base model name with quantization, size, and variant suffixes stripped.
    ///
    /// Extracts just the repo name (after the "/") and removes:
    /// - Quantization suffixes: `-4bit`, `-8bit`, `-bf16`, `-fp16`
    /// - Variant suffixes: `-Base`, `-Instruct`, `-VoiceDesign`, `-CustomVoice`
    /// - Size suffixes: `-0.6B`, `-1.7B`, `-7B`, `-8B`, `-70B`, etc.
    ///
    /// Examples:
    /// - "mlx-community/Qwen2.5-7B-Instruct-4bit" -> "Qwen2.5"
    /// - "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16" -> "Qwen3-TTS-12Hz"
    /// - "mlx-community/Phi-3-mini-4k-instruct-4bit" -> "Phi-3-mini-4k"
    public var baseName: String {
        let repoName: String
        if let slashIndex = id.firstIndex(of: "/") {
            repoName = String(id[id.index(after: slashIndex)...])
        } else {
            repoName = id
        }
        return Self.stripSuffixes(repoName)
    }

    /// The organization and base model name, used for grouping model variants.
    ///
    /// Combines the organization prefix with the `baseName` to form a family
    /// identifier. Models with the same `familyName` are considered variants
    /// of the same model (e.g., different quantizations or sizes).
    ///
    /// Examples:
    /// - "mlx-community/Qwen2.5-7B-Instruct-4bit" -> "mlx-community/Qwen2.5"
    /// - "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16" -> "mlx-community/Qwen3-TTS-12Hz"
    public var familyName: String {
        let org: String
        if let slashIndex = id.firstIndex(of: "/") {
            org = String(id[id.startIndex..<slashIndex])
        } else {
            org = ""
        }

        let base = baseName

        if org.isEmpty {
            return base
        }
        return "\(org)/\(base)"
    }

    // MARK: - Private Helpers

    /// Strips known suffixes from a model repo name to extract the base name.
    ///
    /// Strips in order: quantization, then variant, then size suffixes.
    /// Each category is stripped repeatedly to handle multiple suffixes.
    private static func stripSuffixes(_ name: String) -> String {
        var result = name

        // Quantization suffixes (case-sensitive match on common patterns)
        let quantizationSuffixes = ["-4bit", "-8bit", "-bf16", "-fp16"]
        for suffix in quantizationSuffixes {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }

        // Variant suffixes (case-insensitive check for common variants)
        let variantSuffixes = ["-Base", "-Instruct", "-VoiceDesign", "-CustomVoice",
                               "-base", "-instruct", "-voicedesign", "-customvoice"]
        for suffix in variantSuffixes {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }

        // Size suffixes: match pattern like -0.6B, -1.7B, -7B, -8B, -70B
        // Pattern: hyphen, optional digits and dot, digits, "B"
        while let range = result.range(
            of: #"-\d+(\.\d+)?[Bb]$"#,
            options: .regularExpression
        ) {
            result = String(result[result.startIndex..<range.lowerBound])
        }

        return result
    }
}
