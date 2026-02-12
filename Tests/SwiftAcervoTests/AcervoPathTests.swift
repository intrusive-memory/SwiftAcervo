import Testing
import Foundation
@testable import SwiftAcervo

/// Tests for Acervo path resolution: sharedModelsDirectory, slugify(), and modelDirectory(for:).
struct AcervoPathTests {

    // MARK: - sharedModelsDirectory

    @Test("sharedModelsDirectory ends with Library/SharedModels")
    func sharedModelsDirectoryPath() {
        let dir = Acervo.sharedModelsDirectory
        #expect(dir.path.hasSuffix("Library/SharedModels"))
    }

    @Test("sharedModelsDirectory is under home directory")
    func sharedModelsDirectoryIsUnderHome() {
        let dir = Acervo.sharedModelsDirectory
        let home = URL(filePath: NSHomeDirectory())
        #expect(dir.path.hasPrefix(home.path))
    }

    // MARK: - slugify

    @Test("slugify converts / to _")
    func slugifyConvertsSlash() {
        let result = Acervo.slugify("mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(result == "mlx-community_Qwen2.5-7B-Instruct-4bit")
    }

    @Test("slugify handles multiple slashes")
    func slugifyMultipleSlashes() {
        let result = Acervo.slugify("a/b/c")
        #expect(result == "a_b_c")
    }

    @Test("slugify handles empty string")
    func slugifyEmpty() {
        let result = Acervo.slugify("")
        #expect(result == "")
    }

    @Test("slugify preserves string without slashes")
    func slugifyNoSlashes() {
        let result = Acervo.slugify("no-slashes-here")
        #expect(result == "no-slashes-here")
    }

    // MARK: - modelDirectory(for:)

    @Test("modelDirectory throws for invalid ID with no slash")
    func modelDirectoryNoSlash() {
        #expect(throws: AcervoError.self) {
            _ = try Acervo.modelDirectory(for: "no-slash-model")
        }
    }

    @Test("modelDirectory throws for invalid ID with multiple slashes")
    func modelDirectoryMultipleSlashes() {
        #expect(throws: AcervoError.self) {
            _ = try Acervo.modelDirectory(for: "a/b/c")
        }
    }

    @Test("modelDirectory throws invalidModelId for empty string")
    func modelDirectoryEmptyString() {
        #expect(throws: AcervoError.self) {
            _ = try Acervo.modelDirectory(for: "")
        }
    }

    @Test("modelDirectory constructs correct path for valid ID")
    func modelDirectoryValidId() throws {
        let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        let expected = Acervo.sharedModelsDirectory
            .appendingPathComponent("mlx-community_Qwen2.5-7B-Instruct-4bit")
        #expect(dir == expected)
    }

    @Test("modelDirectory path is under sharedModelsDirectory")
    func modelDirectoryUnderShared() throws {
        let dir = try Acervo.modelDirectory(for: "org/repo")
        #expect(dir.path.hasPrefix(Acervo.sharedModelsDirectory.path))
    }

    @Test("modelDirectory uses slugified name as last path component")
    func modelDirectoryLastComponent() throws {
        let dir = try Acervo.modelDirectory(for: "mlx-community/Phi-3-mini-4k-instruct-4bit")
        #expect(dir.lastPathComponent == "mlx-community_Phi-3-mini-4k-instruct-4bit")
    }

    // MARK: - slugify() Edge Cases

    @Test("slugify handles org containing underscore")
    func slugifyOrgWithUnderscore() {
        let result = Acervo.slugify("my_org/model-name")
        #expect(result == "my_org_model-name")
    }

    @Test("slugify handles model ID with hyphens")
    func slugifyWithHyphens() {
        let result = Acervo.slugify("org-name/model-with-many-hyphens")
        #expect(result == "org-name_model-with-many-hyphens")
    }

    @Test("slugify handles model ID with numbers")
    func slugifyWithNumbers() {
        let result = Acervo.slugify("org123/model456v2")
        #expect(result == "org123_model456v2")
    }

    @Test("slugify handles very long model ID")
    func slugifyVeryLongId() {
        let longOrg = String(repeating: "a", count: 100)
        let longRepo = String(repeating: "b", count: 200)
        let modelId = "\(longOrg)/\(longRepo)"
        let result = Acervo.slugify(modelId)
        #expect(result == "\(longOrg)_\(longRepo)")
        #expect(result.count == 301)
        #expect(!result.contains("/"))
    }

    @Test("slugify handles org with multiple underscores")
    func slugifyOrgMultipleUnderscores() {
        let result = Acervo.slugify("my_special_org/model")
        #expect(result == "my_special_org_model")
    }

    @Test("slugify handles dots and special characters in model name")
    func slugifySpecialCharacters() {
        let result = Acervo.slugify("mlx-community/Qwen2.5-7B-Instruct-4bit")
        #expect(result.contains("Qwen2.5"))
        #expect(result.contains("-7B-"))
        #expect(!result.contains("/"))
    }

    @Test("slugify handles single character org and repo")
    func slugifySingleCharParts() {
        let result = Acervo.slugify("a/b")
        #expect(result == "a_b")
    }
}
