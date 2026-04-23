import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {

  /// Tests for `Acervo.ensureAvailable(modelId, files:)` empty-files behavior.
  /// Exercises the requestedFiles.isEmpty branch in AcervoDownloader.swift
  /// (currently line 710, `if requestedFiles.isEmpty { filesToDownload = manifest.files }`).
  /// Update the line number to match the first match of `grep -n "if requestedFiles.isEmpty" Sources/SwiftAcervo/AcervoDownloader.swift` at commit time.
  @Suite("Ensure Available Empty Files Tests")
  struct EnsureAvailableEmptyFilesTests {

    // MARK: - Helpers

    /// Builds a valid manifest with three files for the given modelId.
    private static func makeThreeFileManifest(modelId: String) -> CDNManifest {
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "cc8cd41cef907c4d216069122c4b89936211361f9050a717a1e37ad1862e952f",
          sizeBytes: 16
        ),
        CDNManifestFile(
          path: "weights.safetensors",
          sha256: "14d6fc848712815bc1b5fe1ced1b8980eea1e0db781a946dac5aded9769d1984",
          sizeBytes: 1024
        ),
        CDNManifestFile(
          path: "tokenizer.model",
          sha256: "4539cc1fbc3c22bb131672c62f20ff87f3f587ba2d3d4c5b161c271c98c07b38",
          sizeBytes: 4096
        ),
      ]
      let slug = modelId.replacingOccurrences(of: "/", with: "_")
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-22T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    /// Returns mock file data for the given file path.
    private static func mockFileData(for path: String) -> Data {
      // Return distinct data based on the file path so each file's SHA-256 matches
      // the expected hashes in the manifest above.
      switch path {
      case "config.json":
        return Data(repeating: 0x01, count: 16)
      case "weights.safetensors":
        return Data(repeating: 0x02, count: 1024)
      case "tokenizer.model":
        return Data(repeating: 0x03, count: 4096)
      default:
        return Data()
      }
    }

    // MARK: - Test A: Empty files array downloads everything in manifest

    @Test("empty files array [] downloads all manifest entries")
    func emptyFilesDownloadsAll() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "ensure-test/empty-files-\(UUID().uuidString.prefix(8))"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        Acervo.customBaseDirectory = tempDir

        let manifest = Self.makeThreeFileManifest(modelId: modelId)
        let encodedManifest = try JSONEncoder().encode(manifest)

        // Responder identifies requests by URL to determine what to return
        MockURLProtocol.responder = { request in
          let url = request.url?.absoluteString ?? ""
          // Check if this is a manifest request (contains /manifest.json)
          if url.contains("/manifest.json") {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
            )!
            return (response, encodedManifest)
          } else {
            // File request — extract filename from URL path
            let path = request.url?.lastPathComponent ?? ""
            let data = Self.mockFileData(for: path)
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, data)
          }
        }

        // Call downloadFiles directly (ensureAvailable doesn't wire session yet,
        // but downloadFiles does per Sortie 1)
        let slug = Acervo.slugify(modelId)
        let destination = tempDir.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        try await AcervoDownloader.downloadFiles(
          modelId: modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session()
        )

        // Verify all three files landed on disk
        // Note: destination is already where files go, files don't go in a SharedModels subdir
        let modelDir = destination

        let configPath = modelDir.appendingPathComponent("config.json")
        let weightsPath = modelDir.appendingPathComponent("weights.safetensors")
        let tokenizerPath = modelDir.appendingPathComponent("tokenizer.model")

        #expect(FileManager.default.fileExists(atPath: configPath.path), "config.json should exist")
        #expect(
          FileManager.default.fileExists(atPath: weightsPath.path),
          "weights.safetensors should exist")
        #expect(
          FileManager.default.fileExists(atPath: tokenizerPath.path), "tokenizer.model should exist"
        )

        // Verify request count: 1 manifest + 3 files = 4
        #expect(MockURLProtocol.requestCount == 4, "Should have made 1 manifest + 3 file requests")
      }
    }

    // MARK: - Test B: Named subset downloads only the named file

    @Test("named subset [\"config.json\"] downloads only that file")
    func namedSubsetDownloadsOnly() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "ensure-test/named-subset-\(UUID().uuidString.prefix(8))"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        Acervo.customBaseDirectory = tempDir

        let manifest = Self.makeThreeFileManifest(modelId: modelId)
        let encodedManifest = try JSONEncoder().encode(manifest)

        MockURLProtocol.responder = { request in
          let url = request.url?.absoluteString ?? ""
          if url.contains("/manifest.json") {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
            )!
            return (response, encodedManifest)
          } else {
            let path = request.url?.lastPathComponent ?? ""
            let data = Self.mockFileData(for: path)
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, data)
          }
        }

        // Call downloadFiles with just "config.json"
        let slug = Acervo.slugify(modelId)
        let destination = tempDir.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        try await AcervoDownloader.downloadFiles(
          modelId: modelId,
          requestedFiles: ["config.json"],
          destination: destination,
          session: MockURLProtocol.session()
        )

        // Verify only config.json landed on disk
        let modelDir = destination

        let configPath = modelDir.appendingPathComponent("config.json")
        let weightsPath = modelDir.appendingPathComponent("weights.safetensors")
        let tokenizerPath = modelDir.appendingPathComponent("tokenizer.model")

        #expect(FileManager.default.fileExists(atPath: configPath.path), "config.json should exist")
        #expect(
          !FileManager.default.fileExists(atPath: weightsPath.path),
          "weights.safetensors should NOT exist")
        #expect(
          !FileManager.default.fileExists(atPath: tokenizerPath.path),
          "tokenizer.model should NOT exist")

        // Verify request count: 1 manifest + 1 file = 2
        #expect(MockURLProtocol.requestCount == 2, "Should have made 1 manifest + 1 file request")
      }
    }

    // MARK: - Test C: File not in manifest throws

    @Test("unknown file in files array throws fileNotInManifest")
    func unknownFileThrows() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "ensure-test/not-in-manifest-\(UUID().uuidString.prefix(8))"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        Acervo.customBaseDirectory = tempDir

        let manifest = Self.makeThreeFileManifest(modelId: modelId)
        let encodedManifest = try JSONEncoder().encode(manifest)

        MockURLProtocol.responder = { request in
          // Only return the manifest; we should fail before any file request
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, encodedManifest)
        }

        // Call downloadFiles with a file that doesn't exist in the manifest
        let slug = Acervo.slugify(modelId)
        let destination = tempDir.appendingPathComponent(slug)
        try AcervoDownloader.ensureDirectory(at: destination)

        // Verify the error case
        do {
          try await AcervoDownloader.downloadFiles(
            modelId: modelId,
            requestedFiles: ["does-not-exist.bin"],
            destination: destination,
            session: MockURLProtocol.session()
          )
          Issue.record("expected fileNotInManifest to be thrown")
        } catch let error as AcervoError {
          switch error {
          case .fileNotInManifest(let fileName, let id):
            #expect(fileName == "does-not-exist.bin")
            #expect(id == modelId)
          default:
            Issue.record("expected fileNotInManifest but got \(error)")
          }
        }

        // Verify we only made the manifest request (no file downloads)
        #expect(MockURLProtocol.requestCount == 1, "Should have made 1 manifest request")
      }
    }
  }
}
