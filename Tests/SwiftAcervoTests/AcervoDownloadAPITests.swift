// Companion tests for Sources/SwiftAcervo/Acervo+Download.swift and
// Sources/SwiftAcervo/Acervo+EnsureAvailable.swift.
//
// Note: deleteModel()-specific tests were moved to DeleteModelTests.swift (S7
// of OPERATION DRAWER DIVIDERS). This file retains download and ensure-available
// tests only.
//
// These tests use temporary directories and the internal overloads that accept
// a base directory parameter to avoid touching the real SharedModels directory.
// Full integration tests with real CDN downloads are in Sprint 14.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Tests for the public download API: Acervo.download() and Acervo.ensureAvailable().
///
/// deleteModel() tests live in DeleteModelTests.swift (legacy repo-keyed variant)
/// and SlugDeleteModelTests.swift (slug-keyed variant).
struct AcervoDownloadAPITests {

  // MARK: - Test Helpers

  /// Creates a temporary base directory for testing and returns its URL.
  private func makeTempBase() throws -> URL {
    let tempBase = FileManager.default.temporaryDirectory
      .appendingPathComponent("AcervoDownloadAPITests-\(UUID().uuidString)")
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

  // MARK: - download() Model ID Validation

  @Test("download() throws invalidModelId for ID with no slash")
  func downloadThrowsForNoSlash() async {
    do {
      try await Acervo.download(
        "no-slash-model",
        files: ["config.json"],
        in: FileManager.default.temporaryDirectory
      )
      #expect(Bool(false), "Expected download to throw invalidModelId")
    } catch let error as AcervoError {
      if case .invalidModelId(let id) = error {
        #expect(id == "no-slash-model")
      } else {
        #expect(Bool(false), "Expected invalidModelId but got \(error)")
      }
    } catch {
      #expect(Bool(false), "Expected AcervoError but got \(error)")
    }
  }

  @Test("download() throws invalidModelId for ID with multiple slashes")
  func downloadThrowsForMultipleSlashes() async {
    do {
      try await Acervo.download(
        "org/sub/model",
        files: ["config.json"],
        in: FileManager.default.temporaryDirectory
      )
      #expect(Bool(false), "Expected download to throw invalidModelId")
    } catch let error as AcervoError {
      if case .invalidModelId(let id) = error {
        #expect(id == "org/sub/model")
      } else {
        #expect(Bool(false), "Expected invalidModelId but got \(error)")
      }
    } catch {
      #expect(Bool(false), "Expected AcervoError but got \(error)")
    }
  }

  @Test("download() throws invalidModelId for empty string")
  func downloadThrowsForEmptyString() async {
    do {
      try await Acervo.download(
        "",
        files: ["config.json"],
        in: FileManager.default.temporaryDirectory
      )
      #expect(Bool(false), "Expected download to throw invalidModelId")
    } catch let error as AcervoError {
      if case .invalidModelId = error {
        // Expected
      } else {
        #expect(Bool(false), "Expected invalidModelId but got \(error)")
      }
    } catch {
      #expect(Bool(false), "Expected AcervoError but got \(error)")
    }
  }

  // MARK: - download() Directory Creation

  @Test("download() creates model directory")
  func downloadCreatesDirectory() async throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/test-model"
    let slug = Acervo.slugify(modelId)
    let expectedDir = tempBase.appendingPathComponent(slug)

    // Directory should not exist yet
    #expect(!FileManager.default.fileExists(atPath: expectedDir.path))

    // download() will create the directory, then attempt to download.
    // The download will fail (network error) because the model doesn't exist,
    // but the directory should have been created before the download attempt.
    do {
      try await Acervo.download(
        modelId,
        files: ["config.json"],
        in: tempBase
      )
    } catch {
      // Network error expected -- that's fine for this test
    }

    // Directory should have been created
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: expectedDir.path,
      isDirectory: &isDirectory
    )
    #expect(exists, "download() should create the model directory")
    #expect(isDirectory.boolValue, "Created path should be a directory")
  }

  @Test("download() with valid model ID attempts manifest fetch from CDN")
  func downloadAttemptsManifestFetch() async throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    // Pre-create the model directory with config.json
    try createFakeModel(modelId: "test-org/existing-model", in: tempBase)

    // download() now fetches the CDN manifest first, which will fail
    // for a fake model not on the CDN. This verifies that the manifest
    // fetch happens even when files exist locally.
    do {
      try await Acervo.download(
        "test-org/existing-model",
        files: ["config.json"],
        force: false,
        in: tempBase
      )
      #expect(Bool(false), "Expected download to throw manifest error for fake model")
    } catch let error as AcervoError {
      // manifestDownloadFailed or networkError are both valid
      switch error {
      case .manifestDownloadFailed, .networkError:
        break  // Expected
      default:
        #expect(Bool(false), "Expected manifest/network error but got \(error)")
      }
    }

    // Verify pre-existing file was NOT deleted by the failed manifest fetch
    let configPath =
      tempBase
      .appendingPathComponent("test-org_existing-model")
      .appendingPathComponent("config.json")
    #expect(FileManager.default.fileExists(atPath: configPath.path))
  }

  // MARK: - ensureAvailable() Skip Logic

  @Test("ensureAvailable() skips download when model is already fully present (manifest + files)")
  func ensureAvailableSkipsExistingModel() async throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/already-available"

    // Under Sortie-4 strict semantics, `ensureAvailable` skips the download
    // only when `Acervo.isModelAvailable(_:in:)` returns true — which
    // requires (a) a cached, self-consistent `.acervo-manifest.json` and
    // (b) every file declared in that manifest present on disk at the
    // recorded size. Write the model accordingly: a `config.json` with
    // known content plus a single-entry manifest that matches.
    let slug = Acervo.slugify(modelId)
    let modelDir = tempBase.appendingPathComponent(slug)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

    let knownContent = "{\"test\": \"original_content\"}"
    let configBody = Data(knownContent.utf8)
    let configURL = modelDir.appendingPathComponent("config.json")
    try configBody.write(to: configURL)

    let configSha = SHA256.hash(data: configBody)
      .map { String(format: "%02x", $0) }
      .joined()
    let files = [
      CDNManifestFile(
        path: "config.json",
        sha256: configSha,
        sizeBytes: Int64(configBody.count)
      )
    ]
    let manifest = CDNManifest(
      manifestVersion: CDNManifest.supportedVersion,
      modelId: modelId,
      slug: slug,
      updatedAt: "2026-05-18T00:00:00Z",
      files: files,
      manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
    )
    try AcervoDownloader.persistManifest(manifest, in: tempBase)

    // Sanity check: strict availability should return true before the call.
    #expect(Acervo.isModelAvailable(modelId, in: tempBase))

    // ensureAvailable() should return without downloading.
    // If it tried to download, it would fail with a network error for this
    // fake model ID — or it would overwrite the content with real bytes.
    try await Acervo.ensureAvailable(
      modelId,
      files: ["config.json"],
      in: tempBase
    )

    // Verify the file content is unchanged (no download occurred).
    let afterContent = try String(contentsOf: configURL, encoding: .utf8)
    #expect(
      afterContent == knownContent,
      "ensureAvailable should not modify existing model files")
  }

  @Test("ensureAvailable() validates model ID")
  func ensureAvailableValidatesModelId() async {
    do {
      try await Acervo.ensureAvailable(
        "invalid-no-slash",
        files: ["config.json"],
        in: FileManager.default.temporaryDirectory
      )
      #expect(Bool(false), "Expected ensureAvailable to throw invalidModelId")
    } catch let error as AcervoError {
      if case .invalidModelId = error {
        // Expected
      } else {
        #expect(Bool(false), "Expected invalidModelId but got \(error)")
      }
    } catch {
      #expect(Bool(false), "Expected AcervoError but got \(error)")
    }
  }

  @Test("ensureAvailable() attempts download when model is missing")
  func ensureAvailableDownloadsWhenMissing() async throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/missing-model"

    // Model directory does not exist -- ensureAvailable should attempt download.
    // Since this is a fake model, the download will fail with a network error.
    var downloadAttempted = false
    do {
      try await Acervo.ensureAvailable(
        modelId,
        files: ["config.json"],
        in: tempBase
      )
    } catch {
      // Any error (networkError or downloadFailed) proves the download was attempted
      downloadAttempted = true
    }
    #expect(
      downloadAttempted,
      "ensureAvailable should attempt download when model is missing")
  }

  @Test("isModelConfigPresent internal overload detects config.json in custom directory")
  func isModelConfigPresentInternalOverload() throws {
    let tempBase = try makeTempBase()
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let modelId = "test-org/custom-dir-model"

    // Model not yet created — neither strict nor loose check should pass.
    #expect(!Acervo.isModelAvailable(modelId, in: tempBase))
    #expect(!Acervo.isModelConfigPresent(modelId, in: tempBase))

    // Create fake model (writes only config.json — no manifest).
    try createFakeModel(modelId: modelId, in: tempBase)

    // Loose check sees config.json.
    #expect(Acervo.isModelConfigPresent(modelId, in: tempBase))
    // Strict check returns false: no manifest was written. (The strict
    // `isModelAvailable` helper is cached-manifest-only by design; the
    // consumer-facing `availability(_:)` is more lenient via Tier C.)
    #expect(!Acervo.isModelAvailable(modelId, in: tempBase))
  }

}
