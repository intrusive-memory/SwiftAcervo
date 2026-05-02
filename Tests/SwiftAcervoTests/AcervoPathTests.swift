import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.AppGroupEnvironmentSuite {

  /// Tests for Acervo path resolution: sharedModelsDirectory, slugify(), and modelDirectory(for:).
  ///
  /// Nested under `AppGroupEnvironmentSuite` (`.serialized`) because tests
  /// that read `Acervo.sharedModelsDirectory` indirectly read
  /// `ACERVO_APP_GROUP_ID`, and concurrent writers would race.
  @Suite("AcervoPathTests")
  struct AcervoPathTests {

    // MARK: - sharedModelsDirectory
    //
    // The default-value test ("ends with SharedModels") was deleted as a
    // chronic CI flake. Coverage of the resolved path lives in the
    // integration tests in AcervoFilesystemEdgeCaseTests +
    // ModelDownloadManagerTests, which exercise the same code path with
    // self-owned base directories via `withIsolatedSharedModelsDirectory`.

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
      withIsolatedSharedModelsDirectory { _ in
        #expect(throws: AcervoError.self) {
          _ = try Acervo.modelDirectory(for: "no-slash-model")
        }
      }
    }

    @Test("modelDirectory throws for invalid ID with multiple slashes")
    func modelDirectoryMultipleSlashes() {
      withIsolatedSharedModelsDirectory { _ in
        #expect(throws: AcervoError.self) {
          _ = try Acervo.modelDirectory(for: "a/b/c")
        }
      }
    }

    @Test("modelDirectory throws invalidModelId for empty string")
    func modelDirectoryEmptyString() {
      withIsolatedSharedModelsDirectory { _ in
        #expect(throws: AcervoError.self) {
          _ = try Acervo.modelDirectory(for: "")
        }
      }
    }

    @Test("modelDirectory constructs correct path for valid ID")
    func modelDirectoryValidId() throws {
      try withIsolatedSharedModelsDirectory { sharedDir in
        let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
        let expected = sharedDir.appendingPathComponent("mlx-community_Qwen2.5-7B-Instruct-4bit")
        #expect(dir == expected)
      }
    }

    @Test("modelDirectory path is under sharedModelsDirectory")
    func modelDirectoryUnderShared() throws {
      try withIsolatedSharedModelsDirectory { sharedDir in
        let dir = try Acervo.modelDirectory(for: "org/repo")
        #expect(dir.path.hasPrefix(sharedDir.path))
      }
    }

    @Test("modelDirectory uses slugified name as last path component")
    func modelDirectoryLastComponent() throws {
      try withIsolatedSharedModelsDirectory { _ in
        let dir = try Acervo.modelDirectory(for: "mlx-community/Phi-3-mini-4k-instruct-4bit")
        #expect(dir.lastPathComponent == "mlx-community_Phi-3-mini-4k-instruct-4bit")
      }
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

    @Test("slugify preserves spaces")
    func slugifyPreservesSpaces() {
      let result = Acervo.slugify("org/model with spaces")
      #expect(result == "org_model with spaces")
    }

    @Test("slugify preserves uppercase")
    func slugifyPreservesUppercase() {
      let result = Acervo.slugify("Org/Model-Name")
      #expect(result == "Org_Model-Name")
    }

    // MARK: - ACERVO_APP_GROUP_ID resolution

    @Test("ACERVO_APP_GROUP_ID env var drives sharedModelsDirectory path")
    func envVarDrivesSharedModelsDirectory() {
      withIsolatedSharedModelsDirectory { sharedDir in
        let envValue = ProcessInfo.processInfo.environment[
          Acervo.appGroupEnvironmentVariable
        ]
        #expect(envValue != nil, "Helper should have set the env var")
        guard let envValue else { return }
        #if os(macOS)
          // macOS computes the path deterministically from the group ID, so
          // the env value appears verbatim as a path component.
          #expect(
            sharedDir.path.contains(envValue),
            "sharedModelsDirectory path \(sharedDir.path) must contain group ID \(envValue)"
          )
        #else
          // iOS resolves through containerURL(...), which on Simulator returns
          // a UUID-keyed path that does not contain the group ID literally.
          // Verify the resolved path matches what containerURL hands back for
          // the same identifier.
          let expected = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: envValue
          )?.appendingPathComponent("SharedModels")
          #expect(expected != nil, "containerURL should resolve for env-supplied group ID")
          if let expected {
            #expect(
              sharedDir.standardizedFileURL == expected.standardizedFileURL,
              "sharedModelsDirectory \(sharedDir.path) should equal containerURL-derived path \(expected.path)"
            )
          }
        #endif
      }
    }

    @Test("sharedModelsDirectory ends with SharedModels")
    func sharedModelsDirectoryEndsWithSharedModels() {
      withIsolatedSharedModelsDirectory { sharedDir in
        #expect(sharedDir.lastPathComponent == "SharedModels")
      }
    }
  }

}  // extension SharedStaticStateSuite.AppGroupEnvironmentSuite
