import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for Acervo pattern matching: findModels(matching:).
///
/// All tests use temporary directories for isolation, ensuring no interaction
/// with the real SharedModels directory.
struct AcervoSearchTests {

    // MARK: - Test Helpers

    /// Creates a temporary base directory for test model directories.
    /// Returns the base URL and a cleanup closure.
    private func makeTempBase() throws -> (url: URL, cleanup: @Sendable () -> Void) {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcervoSearchTests-\(UUID().uuidString)")
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

    // MARK: - findModels(matching:) Tests

    @Test("findModels returns exact substring match")
    func findModelsExactSubstringMatch() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        let matches = try Acervo.findModels(matching: "Qwen2.5-7B-Instruct-4bit", in: base)
        #expect(matches.count == 1)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("findModels is case insensitive")
    func findModelsCaseInsensitive() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        // Search with lowercase
        let matchesLower = try Acervo.findModels(matching: "qwen2.5", in: base)
        #expect(matchesLower.count == 1)
        #expect(matchesLower[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")

        // Search with uppercase
        let matchesUpper = try Acervo.findModels(matching: "QWEN2.5", in: base)
        #expect(matchesUpper.count == 1)
        #expect(matchesUpper[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")

        // Search with mixed case
        let matchesMixed = try Acervo.findModels(matching: "qWeN2.5", in: base)
        #expect(matchesMixed.count == 1)
        #expect(matchesMixed[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("findModels returns all matches sorted by ID")
    func findModelsReturnsAllMatches() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // Search for "Qwen" should match all three Qwen models
        let matches = try Acervo.findModels(matching: "Qwen", in: base)
        #expect(matches.count == 3)
        // Verify sorted by ID
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(matches[1].id == "mlx-community/Qwen2.5-7B-Instruct-8bit")
        #expect(matches[2].id == "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")
    }

    @Test("findModels returns empty array if no matches")
    func findModelsNoMatches() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        let matches = try Acervo.findModels(matching: "Llama", in: base)
        #expect(matches.isEmpty)
    }

    @Test("findModels returns empty array for empty directory")
    func findModelsEmptyDirectory() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        let matches = try Acervo.findModels(matching: "anything", in: base)
        #expect(matches.isEmpty)
    }

    @Test("findModels partial match finds model")
    func findModelsPartialMatch() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")

        // "Qwen" is a partial match for "Qwen2.5-7B-Instruct-4bit"
        let matches = try Acervo.findModels(matching: "Qwen", in: base)
        #expect(matches.count == 1)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("findModels matches against full model ID including org")
    func findModelsMatchesOrg() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "other-org_Qwen2.5-7B-Instruct-4bit")

        // Search for org name
        let matches = try Acervo.findModels(matching: "mlx-community", in: base)
        #expect(matches.count == 1)
        #expect(matches[0].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }

    @Test("findModels with single character pattern")
    func findModelsSingleCharPattern() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "org_alpha")
        try createModelDir(in: base, slug: "org_beta")

        // "a" should match both ("alpha" and "beta" both contain "a")
        let matches = try Acervo.findModels(matching: "a", in: base)
        #expect(matches.count == 2)
    }

    @Test("findModels matches quantization suffix pattern")
    func findModelsQuantizationPattern() throws {
        let (base, cleanup) = try makeTempBase()
        defer { cleanup() }

        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-4bit")
        try createModelDir(in: base, slug: "mlx-community_Qwen2.5-7B-Instruct-8bit")
        try createModelDir(in: base, slug: "mlx-community_Phi-3-mini-4k-instruct-4bit")

        // Search for "4bit" should match both 4bit models
        let matches = try Acervo.findModels(matching: "4bit", in: base)
        #expect(matches.count == 2)
        #expect(matches[0].id == "mlx-community/Phi-3-mini-4k-instruct-4bit")
        #expect(matches[1].id == "mlx-community/Qwen2.5-7B-Instruct-4bit")
    }
}
