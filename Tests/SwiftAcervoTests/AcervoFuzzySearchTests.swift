import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for Acervo fuzzy search: findModels(fuzzyMatching:), closestModel(to:),
/// and modelFamilies().
///
/// All tests use temporary directories for isolation, ensuring no interaction
/// with the real SharedModels directory.
struct AcervoFuzzySearchTests {

    // MARK: - Test Helpers

    /// Creates a temporary base directory for test model directories.
    /// Returns the base URL and a cleanup closure.
    private func makeTempBase() throws -> (url: URL, cleanup: @Sendable () -> Void) {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoFuzzySearchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let cleanup: @Sendable () -> Void = {
            _ = try? FileManager.default.removeItem(at: tempBase)
        }
        return (tempBase, cleanup)
    }

    /// Creates a model directory with a config.json inside the given base directory.
    @discardableResult
    private func createModelDir(
        in base: URL,
        slug: String
    ) throws -> URL {
        let modelDir = base.appendingPathComponent(slug)
        try FileManager.default.createDirectory(
            at: modelDir,
            withIntermediateDirectories: true
        )
        let configURL = modelDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configURL)
        return modelDir
    }

    // MARK: - findModels(fuzzyMatching:) Tests

    @Test("Fuzzy search finds close matches within threshold")
    func fuzzySearchFindsCloseMatches() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // "Qwen2.5-7B-Instruct-4bit" is an exact match after prefix stripping
        let matches = try Acervo.findModels(
            fuzzyMatching: "Qwen2.5-7B-Instruct-4bit",
            editDistance: 5,
            in: base
        )
        #expect(matches.count >= 1)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("Fuzzy search respects threshold - excludes distant matches")
    func fuzzySearchRespectsThreshold() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // With a very small threshold, only very close matches should appear
        // "Qwen2.5-7B-Instruct-4bit" vs "Phi-3-mini-4k-instruct-4bit" are very different
        let matches = try Acervo.findModels(
            fuzzyMatching: "Qwen2.5-7B-Instruct-4bit",
            editDistance: 0,
            in: base
        )
        // Only exact match (after prefix stripping) should be found
        #expect(matches.count == 1)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("Fuzzy search strips mlx-community/ prefix before comparison")
    func fuzzySearchStripsPrefixes() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        // Query with prefix should still match (prefix stripped from both)
        let matchesWithPrefix = try Acervo.findModels(
            fuzzyMatching: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            editDistance: 0,
            in: base
        )
        #expect(matchesWithPrefix.count == 1)
        #expect(matchesWithPrefix[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")

        // Query without prefix should also match (prefix stripped from model ID)
        let matchesWithoutPrefix = try Acervo.findModels(
            fuzzyMatching: "Qwen2.5-7B-Instruct-4bit",
            editDistance: 0,
            in: base
        )
        #expect(matchesWithoutPrefix.count == 1)
        #expect(matchesWithoutPrefix[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("Fuzzy search sorts results by closeness then by ID")
    func fuzzySearchSortsByCloseness() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Create models with varying distances from the query
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // Query: "Qwen2.5-7B-Instruct-4bit"
        // After prefix stripping:
        //   - "Qwen2.5-7B-Instruct-4bit" has distance 0 to query
        //   - "Qwen2.5-7B-Instruct-8bit" has distance 1 to query (4 -> 8)
        //   - "Phi-3-mini-4k-instruct-4bit" has a much larger distance
        let matches = try Acervo.findModels(
            fuzzyMatching: "Qwen2.5-7B-Instruct-4bit",
            editDistance: 2,
            in: base
        )
        // Should include 4bit (distance 0) and 8bit (distance 1), but not Phi
        #expect(matches.count == 2)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit") // distance 0
        #expect(matches[1].id == "mlx-community/Qwen2.5-7B-Instruct-8bit") // distance 1
    }

    @Test("Fuzzy search returns empty array if no matches within threshold")
    func fuzzySearchNoMatchesWithinThreshold() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        // A completely unrelated query with a tight threshold
        let matches = try Acervo.findModels(
            fuzzyMatching: "ZZZZZZZZZZZ",
            editDistance: 2,
            in: base
        )
        #expect(matches.isEmpty)
    }

    @Test("Fuzzy search returns empty array for empty directory")
    func fuzzySearchEmptyDirectory() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let matches = try Acervo.findModels(
            fuzzyMatching: "anything",
            editDistance: 10,
            in: base
        )
        #expect(matches.isEmpty)
    }

    @Test("Fuzzy search with typo finds correct model")
    func fuzzySearchWithTypo() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        // Typo: "Qwen25" instead of "Qwen2.5" (missing dot, distance ~1 after prefix strip)
        // Full query after strip: "Qwen25-7B-Instruct-4bit" vs "Qwen2.5-7B-Instruct-4bit"
        let matches = try Acervo.findModels(
            fuzzyMatching: "Qwen25-7B-Instruct-4bit",
            editDistance: 2,
            in: base
        )
        #expect(matches.count == 1)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("Fuzzy search sorts alphabetically for equidistant models")
    func fuzzySearchSortsAlphabeticallyForTies() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Two models equidistant from a query
        try createModelDir(in: base, slug: "org_bravo-model")
        try createModelDir(in: base, slug: "org_alpha-model")

        // Both "alpha-model" and "bravo-model" are at the same distance from "delta-model"
        // (they differ in similar number of characters)
        let matches = try Acervo.findModels(
            fuzzyMatching: "org/alpha-modex",
            editDistance: 5,
            in: base
        )
        // Both should match within threshold 5, and if equidistant, sorted by ID
        let ids = matches.map(\.id)
        // Verify alphabetical ordering for same-distance items
        for i in 0..<(ids.count - 1) {
            let dist1 = levenshteinDistance(
                Acervo.slugify(ids[i]).replacingOccurrences(of: "_", with: "/"),
                "org/alpha-modex"
            )
            let dist2 = levenshteinDistance(
                Acervo.slugify(ids[i + 1]).replacingOccurrences(of: "_", with: "/"),
                "org/alpha-modex"
            )
            if dist1 == dist2 {
                #expect(ids[i] < ids[i + 1])
            }
        }
    }

    // MARK: - closestModel(to:) Tests

    @Test("closestModel returns the closest match")
    func closestModelReturnsClosest() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // "Qwen2.5-7B-Instruct-4bit" should be closest match (distance 0 after prefix strip)
        let closest = try Acervo.closestModel(
            to: "Qwen2.5-7B-Instruct-4bit",
            editDistance: 5,
            in: base
        )
        #expect(closest != nil)
        #expect(closest?.id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("closestModel returns nil when no match within threshold")
    func closestModelReturnsNilWhenNoMatch() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        // Completely unrelated query with tight threshold
        let closest = try Acervo.closestModel(
            to: "ZZZZZZZZZZZ",
            editDistance: 2,
            in: base
        )
        #expect(closest == nil)
    }

    @Test("closestModel returns nil for empty directory")
    func closestModelReturnsNilForEmptyDir() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let closest = try Acervo.closestModel(
            to: "anything",
            editDistance: 10,
            in: base
        )
        #expect(closest == nil)
    }

    @Test("closestModel returns first result when multiple equidistant matches")
    func closestModelReturnsFirstEquidistant() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Two models that are equidistant from a query
        // "org/alpha-model" and "org/bravo-model" both differ from "org/xxxxx-model"
        // by the same distance (5 character substitutions in prefix)
        try createModelDir(in: base, slug: "org_alpha-model")
        try createModelDir(in: base, slug: "org_bravo-model")

        let closest = try Acervo.closestModel(
            to: "org/alpha-model",
            editDistance: 10,
            in: base
        )
        #expect(closest != nil)
        // Should be "org/alpha-model" since it's distance 0 (exact match)
        #expect(closest?.id == "org/alpha-model")
    }

    @Test("closestModel with typo returns correct model")
    func closestModelWithTypo() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // Typo: "Qwen25" instead of "Qwen2.5"
        let closest = try Acervo.closestModel(
            to: "Qwen25-7B-Instruct-4bit",
            editDistance: 3,
            in: base
        )
        #expect(closest != nil)
        #expect(closest?.id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    // MARK: - modelFamilies() Tests

    @Test("modelFamilies groups models by family name")
    func modelFamiliesGroupsByFamily() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        let families = try Acervo.modelFamilies(in: base)

        // Each model should be in its own family since they have different base names
        #expect(families.count == 2)
        #expect(families["mlx-community/Qwen2.5"] != nil)
        #expect(families["mlx-community/Phi-3-mini-4k"] != nil)
    }

    @Test("modelFamilies groups models with same base name together")
    func modelFamiliesSameBaseName() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Qwen2.5 variants with different quantizations
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")

        let families = try Acervo.modelFamilies(in: base)

        // Both should be in the same family "mlx-community/Qwen2.5"
        let qwenFamily = families["mlx-community/Qwen2.5"]
        #expect(qwenFamily != nil)
        #expect(qwenFamily?.count == 2)
    }

    @Test("modelFamilies groups quantization variants together")
    func modelFamiliesQuantizationVariants() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-bf16")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-fp16")

        let families = try Acervo.modelFamilies(in: base)

        // All four should be in the same Qwen2.5 family
        let qwenFamily = families["mlx-community/Qwen2.5"]
        #expect(qwenFamily != nil)
        #expect(qwenFamily?.count == 4)
    }

    @Test("modelFamilies groups size variants together")
    func modelFamiliesSizeVariants() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen3-TTS-12Hz-0.6B-Base-bf16")
        try createModelDir(in: base, slug: "mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16")

        let families = try Acervo.modelFamilies(in: base)

        // Both should be in "mlx-community/Qwen3-TTS-12Hz" family
        let ttsFamily = families["mlx-community/Qwen3-TTS-12Hz"]
        #expect(ttsFamily != nil)
        #expect(ttsFamily?.count == 2)
    }

    @Test("modelFamilies sorts models within each family by ID")
    func modelFamiliesSortedWithinFamily() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        // Create in reverse alphabetical order
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-fp16")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-bf16")

        let families = try Acervo.modelFamilies(in: base)
        let qwenFamily = families["mlx-community/Qwen2.5"]!

        // Verify sorted by ID
        for i in 0..<(qwenFamily.count - 1) {
            #expect(qwenFamily[i].id < qwenFamily[i + 1].id)
        }
    }

    @Test("modelFamilies returns empty dictionary for empty directory")
    func modelFamiliesEmptyDirectory() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let families = try Acervo.modelFamilies(in: base)
        #expect(families.isEmpty)
    }

    @Test("modelFamilies groups variant suffixes together")
    func modelFamiliesVariantSuffixes() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16")
        try createModelDir(in: base, slug: "mlx-community_Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16")

        let families = try Acervo.modelFamilies(in: base)

        // Both are variants of "mlx-community/Qwen3-TTS-12Hz"
        let ttsFamily = families["mlx-community/Qwen3-TTS-12Hz"]
        #expect(ttsFamily != nil)
        #expect(ttsFamily?.count == 2)
    }
}
