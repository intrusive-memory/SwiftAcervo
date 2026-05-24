// Companion tests for Sources/SwiftAcervo/Acervo+DeleteModel.swift (legacy repo-keyed variant).
//
// Tests for the legacy `Acervo.deleteModel(_:)` API — the synchronous, repo-keyed
// variant that removes a single model directory identified by "org/repo" format.
//
// Lifted from AcervoDownloadAPITests.swift (S7 of OPERATION DRAWER DIVIDERS) —
// the legacy-delete-specific tests now live here so each concern has a focused file:
//   - DeleteModelTests.swift     → legacy repo-keyed deleteModel (this file)
//   - SlugDeleteModelTests.swift → slug-keyed deleteModel(slug:url:)
//
// All tests use temporary directories and the internal overload that accepts
// a base directory parameter to avoid touching the real SharedModels directory.

import Foundation
import Testing

@testable import SwiftAcervo

struct DeleteModelTests {

  // MARK: - Test Helpers

  /// Creates a temporary base directory for testing and returns its URL.
  private func makeTempBase() throws -> URL {
    let tempBase = FileManager.default.temporaryDirectory
      .appendingPathComponent("DeleteModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempBase,
      withIntermediateDirectories: true
    )
    return tempBase
  }

  /// Creates a fake model directory with config.json in the given base directory.
  private func createFakeModel(
    modelId: String,
    in baseDirectory: URL,
    files: [String] = ["config.json"]
  ) throws {
    let slug = Acervo.slugify(modelId)
    let modelDir = baseDirectory.appendingPathComponent(slug)
    try FileManager.default.createDirectory(
      at: modelDir,
      withIntermediateDirectories: true
    )
    for file in files {
      let fileURL = modelDir.appendingPathComponent(file)
      let parentDir = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: parentDir,
        withIntermediateDirectories: true
      )
      try Data("{}".utf8).write(to: fileURL)
    }
  }

  // MARK: - deleteModel() Tests

  @Test("deleteModel() removes model directory")
  func deleteModelRemovesDirectory() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/deletable-model"
    let slug = Acervo.slugify(modelId)
    let modelDir = tempBase.appendingPathComponent(slug)

    // Create fake model
    try createFakeModel(modelId: modelId, in: tempBase)

    // Verify directory exists
    #expect(FileManager.default.fileExists(atPath: modelDir.path))

    // Delete the model
    try Acervo.deleteModel(modelId, in: tempBase)

    // Verify directory no longer exists
    #expect(!FileManager.default.fileExists(atPath: modelDir.path))
  }

  @Test("deleteModel() removes directory with multiple files")
  func deleteModelRemovesMultipleFiles() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/multi-file-model"

    // Create model with multiple files including subdirectory
    try createFakeModel(
      modelId: modelId,
      in: tempBase,
      files: [
        "config.json",
        "tokenizer.json",
        "model.safetensors",
        "speech_tokenizer/config.json",
      ]
    )

    let slug = Acervo.slugify(modelId)
    let modelDir = tempBase.appendingPathComponent(slug)
    #expect(FileManager.default.fileExists(atPath: modelDir.path))

    // Delete the model
    try Acervo.deleteModel(modelId, in: tempBase)

    // Verify entire directory tree is gone
    #expect(!FileManager.default.fileExists(atPath: modelDir.path))
  }

  @Test("deleteModel() throws modelNotFound if directory doesn't exist")
  func deleteModelThrowsForNonexistent() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/nonexistent-model"

    do {
      try Acervo.deleteModel(modelId, in: tempBase)
      #expect(Bool(false), "Expected deleteModel to throw modelNotFound")
    } catch let error as AcervoError {
      if case .modelNotFound(let id) = error {
        #expect(id == modelId)
      } else {
        #expect(Bool(false), "Expected modelNotFound but got \(error)")
      }
    }
  }

  @Test("deleteModel() validates model ID")
  func deleteModelValidatesModelId() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    do {
      try Acervo.deleteModel("no-slash", in: tempBase)
      #expect(Bool(false), "Expected deleteModel to throw invalidModelId")
    } catch let error as AcervoError {
      if case .invalidModelId(let id) = error {
        #expect(id == "no-slash")
      } else {
        #expect(Bool(false), "Expected invalidModelId but got \(error)")
      }
    }
  }

  @Test("deleteModel() throws invalidModelId for multiple slashes")
  func deleteModelThrowsForMultipleSlashes() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    do {
      try Acervo.deleteModel("a/b/c", in: tempBase)
      #expect(Bool(false), "Expected deleteModel to throw invalidModelId")
    } catch let error as AcervoError {
      if case .invalidModelId(let id) = error {
        #expect(id == "a/b/c")
      } else {
        #expect(Bool(false), "Expected invalidModelId but got \(error)")
      }
    }
  }

  @Test("deleteModel() does not affect other models")
  func deleteModelDoesNotAffectOthers() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelToDelete = "test-org/to-delete"
    let modelToKeep = "test-org/to-keep"

    // Create both models
    try createFakeModel(modelId: modelToDelete, in: tempBase)
    try createFakeModel(modelId: modelToKeep, in: tempBase)

    // Delete one model
    try Acervo.deleteModel(modelToDelete, in: tempBase)

    // Verify the deleted model is gone
    let deletedDir = tempBase.appendingPathComponent(Acervo.slugify(modelToDelete))
    #expect(!FileManager.default.fileExists(atPath: deletedDir.path))

    // Verify the other model is untouched
    let keptDir = tempBase.appendingPathComponent(Acervo.slugify(modelToKeep))
    #expect(FileManager.default.fileExists(atPath: keptDir.path))
    let keptConfig = keptDir.appendingPathComponent("config.json")
    #expect(FileManager.default.fileExists(atPath: keptConfig.path))
  }
}
