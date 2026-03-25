import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for Acervo availability checks: isModelAvailable() and modelFileExists().
///
/// These tests create temporary directories that mimic the SharedModels structure
/// to verify file presence detection without touching real model storage.
struct AcervoAvailabilityTests {

  // MARK: - Test Helpers

  /// Creates a temporary base directory for testing.
  private func makeTempBase() throws -> URL {
    let tempBase = FileManager.default.temporaryDirectory
      .appendingPathComponent("AcervoAvailabilityTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: tempBase,
      withIntermediateDirectories: true
    )
    return tempBase
  }

  /// Removes a temporary directory.
  private func removeTempBase(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - isModelAvailable

  @Test("isModelAvailable returns false for nonexistent model")
  func isModelAvailableNonexistent() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let result = Acervo.isModelAvailable(
      "nonexistent-org/nonexistent-model-\(UUID().uuidString)",
      in: tempBase
    )
    #expect(result == false)
  }

  @Test("isModelAvailable returns false when directory exists but no config.json")
  func isModelAvailableNoConfig() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/no-config"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == false)
  }

  @Test("isModelAvailable returns true when config.json is present")
  func isModelAvailableWithConfig() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/with-config"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("config.json"))

    #expect(Acervo.isModelAvailable(modelId, in: tempBase) == true)
  }

  @Test("isModelAvailable returns false for invalid model ID")
  func isModelAvailableInvalidId() {
    #expect(Acervo.isModelAvailable("no-slash") == false)
  }

  // MARK: - modelFileExists

  @Test("modelFileExists returns false for nonexistent model")
  func modelFileExistsNonexistent() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let result = Acervo.modelFileExists(
      "nonexistent-org/nonexistent-model",
      fileName: "config.json",
      in: tempBase
    )
    #expect(result == false)
  }

  @Test("modelFileExists returns true for root-level file")
  func modelFileExistsRootFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/root-file"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: modelDir.appendingPathComponent("tokenizer.json"))

    #expect(Acervo.modelFileExists(modelId, fileName: "tokenizer.json", in: tempBase) == true)
  }

  @Test("modelFileExists returns false for missing root-level file")
  func modelFileExistsMissingRootFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/missing-file"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    #expect(Acervo.modelFileExists(modelId, fileName: "nonexistent.json", in: tempBase) == false)
  }

  @Test("modelFileExists returns true for subdirectory file")
  func modelFileExistsSubdirectoryFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/subdir-file"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    let subdirURL = modelDir.appendingPathComponent("speech_tokenizer")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: subdirURL.appendingPathComponent("config.json"))

    #expect(
      Acervo.modelFileExists(modelId, fileName: "speech_tokenizer/config.json", in: tempBase)
        == true)
  }

  @Test("modelFileExists returns false for missing subdirectory file")
  func modelFileExistsMissingSubdirFile() throws {
    let tempBase = try makeTempBase()
    defer { removeTempBase(tempBase) }

    let modelId = "test-org/missing-subdir"
    let modelDir = tempBase.appendingPathComponent(Acervo.slugify(modelId))
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    #expect(
      Acervo.modelFileExists(modelId, fileName: "speech_tokenizer/config.json", in: tempBase)
        == false)
  }

  @Test("modelFileExists returns false for invalid model ID")
  func modelFileExistsInvalidId() {
    #expect(Acervo.modelFileExists("invalid", fileName: "config.json") == false)
  }
}
