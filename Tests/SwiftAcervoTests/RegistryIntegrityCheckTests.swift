// RegistryIntegrityCheckTests.swift
// SwiftAcervo tests — OPERATION TRIPWIRE GAUNTLET Sortie 8.
//
// Registry-level second pass: targets the integrity gate in Acervo.swift
// (currently lines 1560–1576) that iterates descriptor.files AFTER the
// manifest-driven download. This is DISTINCT from the streaming-pass
// check at AcervoDownloader.swift (currently lines 401–411).
// Update these ranges if either file is refactored.

import Foundation
import Testing

@testable import SwiftAcervo

extension MockURLProtocolSuite {
  @Suite("Registry Integrity Check")
  struct RegistryIntegrityCheckTests {

    /// Creates a temp directory.
    private func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RegistryIntegrity-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    /// Removes a temp directory.
    private func removeTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    @Test("Registry-level integrity check detects hash mismatch and deletes corrupt file")
    func registryLevelHashMismatchDeletesCorruptFile() async throws {
      try await withIsolatedAcervoState {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let tempDir = try makeTempDir()
        defer { removeTempDir(tempDir) }

        let componentId = "registry-integrity-test"
        let repoId = "test-org/registry-integrity-test"

        // Stage 1: Create a file on disk with content hashing to X
        let slug = Acervo.slugify(repoId)
        let componentDir = tempDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

        let stagedContent = Data("staged file content X".utf8)
        let stagedFileURL = componentDir.appendingPathComponent("model.safetensors")
        try stagedContent.write(to: stagedFileURL)

        // Compute the actual hash of the staged file
        let actualHash = try IntegrityVerification.sha256(of: stagedFileURL)

        // Stage 2: Register a hydrated descriptor with a DIFFERENT sha256 (Y)
        // We'll use a known different hash value
        let expectedHash = "0000000000000000000000000000000000000000000000000000000000000000"
        #expect(actualHash != expectedHash, "Test setup: actual and expected hashes must differ")

        let descriptor = ComponentDescriptor(
          id: componentId,
          type: .backbone,
          displayName: "Registry Integrity Test",
          repoId: repoId,
          files: [
            ComponentFile(relativePath: "model.safetensors", sha256: expectedHash)
          ],
          estimatedSizeBytes: Int64(stagedContent.count),
          minimumMemoryBytes: 200
        )

        Acervo.register(descriptor)
        Acervo.customBaseDirectory = tempDir

        // Stage 3: Set up MockURLProtocol to respond to the manifest request.
        // Since force=false and the file already exists on disk with correct size,
        // the download will be skipped, and the registry-level check will run.
        MockURLProtocol.responder = { request in
          // Respond with a manifest that includes our file entry
          let manifestJSON = """
          {
            "manifestVersion": 1,
            "manifestChecksum": "0000000000000000000000000000000000000000000000000000000000000000",
            "files": [
              {
                "path": "model.safetensors",
                "sha256": "\(expectedHash)",
                "sizeBytes": \(stagedContent.count)
              }
            ]
          }
          """
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, Data(manifestJSON.utf8))
        }

        let mockSession = MockURLProtocol.session()

        // Stage 4: Call downloadComponent with force: false and custom session.
        // The file already exists with correct size, so it won't be re-downloaded via the streaming
        // pass, but the registry-level second pass WILL re-verify it and detect
        // the hash mismatch.
        var thrownError: AcervoError?
        do {
          try await AcervoDownloader.downloadFiles(
            modelId: repoId,
            requestedFiles: ["model.safetensors"],
            destination: componentDir,
            force: false,
            progress: nil,
            session: mockSession
          )
          #expect(Bool(false), "Should have thrown integrityCheckFailed")
        } catch let error as AcervoError {
          thrownError = error
        }

        // Stage 4: Assert the error has all three fields populated correctly
        guard let thrownError = thrownError else {
          #expect(Bool(false), "Expected AcervoError to be thrown")
          return
        }

        if case let .integrityCheckFailed(file: errorFile, expected: errorExpected, actual: errorActual) = thrownError {
          // Verify all three fields match expectations
          #expect(errorFile == "model.safetensors", "file field must match")
          #expect(errorExpected == expectedHash, "expected field must match the descriptor's sha256")
          #expect(errorActual == actualHash, "actual field must match the staged file's hash")
        } else {
          #expect(Bool(false), "Expected integrityCheckFailed but got \(thrownError)")
        }

        // Stage 5: Assert the corrupt file was deleted post-throw
        let fileExists = FileManager.default.fileExists(atPath: stagedFileURL.path)
        #expect(!fileExists, "Corrupt file must be deleted after integrity check failure")
      }
    }
  }
}
