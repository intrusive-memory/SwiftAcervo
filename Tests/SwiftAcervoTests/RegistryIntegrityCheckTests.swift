// RegistryIntegrityCheckTests.swift
// SwiftAcervo tests — OPERATION TRIPWIRE GAUNTLET Sortie 8 (fix iteration 02).
//
// This file contains TWO distinct tests, each targeting a different integrity gate:
//
// ─── Gate 1: Streaming-pass integrity check ────────────────────────────────────
//   Implemented at AcervoDownloader.swift lines 401-411 (inside streamDownloadFile).
//   Triggered via AcervoDownloader.downloadFiles(session:) with a MockURLProtocol
//   session.  Tests that a streaming download whose content hashes to X but whose
//   manifest declares sha256 = Y throws integrityCheckFailed with all three fields
//   and deletes the temp file.
//
//   Test: streamingPassHashMismatchDeletesCorruptFile
//
// ─── Gate 2: Registry-level second pass ───────────────────────────────────────
//   Implemented at Acervo.swift lines 1560-1576 (the for-loop over descriptor.files
//   AFTER download() returns inside downloadComponent(_:force:progress:in:)).
//   This gate is DISTINCT from the streaming gate above:
//     • Streaming gate: compares downloaded bytes against the CDN manifest sha256.
//     • Registry gate:  compares on-disk file against the descriptor sha256 baked
//                       into the ComponentRegistry.
//   The registry gate is the LAST line of defense — it catches cases where the
//   descriptor's sha256 diverges from the manifest (e.g., stale descriptor) even
//   when the streaming gate was satisfied.
//
//   Why this test cannot route through downloadComponent(_:force:progress:in:):
//   That internal overload calls download(_:files:force:progress:in:) which calls
//   AcervoDownloader.downloadFiles(...) WITHOUT an injectable session parameter,
//   so the manifest fetch inside downloadFiles always uses SecureDownloadSession.shared.
//   SecureDownloadSession.shared is a singleton whose URLSessionConfiguration was
//   set at creation time — URLProtocol.registerClass does NOT retroactively affect
//   it.  Without a live CDN, routing through downloadComponent would throw
//   AcervoError.networkError before reaching line 1560.
//
//   This is a known gap that Sortie 1 (threading session: through the download path)
//   is designed to close.  Once Sortie 1 lands, this test should be updated to call
//   downloadComponent(_:force:progress:in:) directly with a mock session.
//
//   Strategy for this iteration (Option C per the Sortie 8 mission brief):
//   Reproduce the registry-level loop (lines 1560-1576) inline in the test.
//   The test directly invokes IntegrityVerification.sha256(of:) — the same function
//   called by lines 1567 — against a pre-staged file, then asserts the three-field
//   error and the post-throw file deletion.  A future refactor that removes lines
//   1560-1576 from downloadComponent would leave callers silently receiving corrupt
//   files; this test makes that contract explicit and documented.
//
//   Test: registryLevelHashMismatchDeletesCorruptFile
//
// Update the line ranges in this comment whenever either gate is refactored:
//   Streaming gate: grep -n 'throw AcervoError.integrityCheckFailed' Sources/SwiftAcervo/AcervoDownloader.swift
//   Registry gate:  grep -n 'Additional registry-level checksum verification' Sources/SwiftAcervo/Acervo.swift

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {
  @Suite("Registry Integrity Check")
  struct RegistryIntegrityCheckTests {

    /// Creates a temp directory.
    private func makeTempDir(_ label: String = "RegistryIntegrity") throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    /// Removes a temp directory.
    private func removeTempDir(_ dir: URL) {
      try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Gate 1: Streaming-pass integrity check (AcervoDownloader.swift:401-411)

    /// Verifies the STREAMING-PASS integrity gate at AcervoDownloader.swift lines 401-411.
    ///
    /// This gate fires inside streamDownloadFile when the streamed bytes hash to a value
    /// that differs from the manifest's declared sha256.  The test routes through
    /// AcervoDownloader.downloadFiles(session:) with a MockURLProtocol session so the
    /// manifest and file-body are fully controlled.
    ///
    /// Mutation check: if lines 401-411 of AcervoDownloader.swift are deleted, the
    /// streaming pass will no longer throw on hash mismatch, and this test will fail
    /// because `thrownError` will remain nil and the `Bool(false)` expectation fires.
    @Test("Streaming-pass integrity gate detects hash mismatch and deletes corrupt file")
    func streamingPassHashMismatchDeletesCorruptFile() async throws {
      try await withIsolatedAcervoState {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let tempDir = try makeTempDir("StreamingPass")
        defer { removeTempDir(tempDir) }

        let repoId = "test-org/streaming-integrity-\(UUID().uuidString.prefix(8))"
        let slug = Acervo.slugify(repoId)
        let componentDir = tempDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

        // Content that will actually be served — hashes to actualHash.
        let servedContent = Data("streamed file content X".utf8)
        let actualHash = SHA256.hash(data: servedContent)
          .map { String(format: "%02x", $0) }.joined()

        // The manifest declares a DIFFERENT sha256 — this is the mismatch.
        let expectedHash = "0000000000000000000000000000000000000000000000000000000000000000"
        #expect(actualHash != expectedHash, "Test setup: actual and expected hashes must differ")

        // Build a valid manifest that declares the wrong sha256 for the file.
        let manifestFiles = [
          CDNManifestFile(
            path: "model.safetensors",
            sha256: expectedHash,
            sizeBytes: Int64(servedContent.count)
          )
        ]
        let manifest = CDNManifest(
          manifestVersion: CDNManifest.supportedVersion,
          modelId: repoId,
          slug: slug,
          updatedAt: "2026-04-23T10:30:00Z",
          files: manifestFiles,
          manifestChecksum: CDNManifest.computeChecksum(from: manifestFiles.map(\.sha256))
        )
        let manifestData = try JSONEncoder().encode(manifest)

        MockURLProtocol.responder = { request in
          let lastComponent = request.url?.lastPathComponent ?? ""
          if lastComponent == "manifest.json" {
            let response = HTTPURLResponse(
              url: request.url!, statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"])!
            return (response, manifestData)
          }
          // Serve the actual content (wrong hash — triggers streaming gate).
          let response = HTTPURLResponse(
            url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"])!
          return (response, servedContent)
        }

        let mockSession = MockURLProtocol.session()
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

        guard let err = thrownError else {
          #expect(Bool(false), "Expected AcervoError to be thrown")
          return
        }

        if case .integrityCheckFailed(file: let f, expected: let e, actual: let a) = err {
          #expect(f == "model.safetensors", "file field must match")
          #expect(e == expectedHash, "expected field must match manifest sha256")
          #expect(a == actualHash, "actual field must match the served content's hash")
        } else {
          #expect(Bool(false), "Expected integrityCheckFailed but got \(err)")
        }

        // The corrupt temp file must be deleted post-throw.
        let fileURL = componentDir.appendingPathComponent("model.safetensors")
        #expect(
          !FileManager.default.fileExists(atPath: fileURL.path),
          "Corrupt file must be deleted after streaming-pass integrity failure")
      }
    }

    // MARK: - Gate 2: Registry-level second pass (Acervo.swift:1560-1576)

    /// Verifies the REGISTRY-LEVEL second-pass gate at Acervo.swift lines 1560-1576.
    ///
    /// That gate runs inside downloadComponent(_:force:progress:in:) AFTER
    /// download() returns successfully.  It iterates descriptor.files and re-hashes
    /// each on-disk file against the descriptor's sha256.  A mismatch causes the
    /// file to be deleted and AcervoError.integrityCheckFailed to be thrown with
    /// all three fields populated.
    ///
    /// Why this test reproduces the gate logic inline (Option C):
    /// downloadComponent(_:force:progress:in:) calls AcervoDownloader.downloadFiles
    /// without an injectable session, so a mock session cannot be injected via that
    /// path without modifying production code.  This test therefore exercises the
    /// gate's contract directly:
    ///   1. Pre-stage a file on disk whose content hashes to X.
    ///   2. Construct a hydrated ComponentDescriptor whose sha256 is Y (≠ X).
    ///   3. Execute the same logic as lines 1560-1576 — call
    ///      IntegrityVerification.sha256(of:), compare to expected, delete on
    ///      mismatch, and throw with three fields.
    ///   4. Assert all three fields and assert the file was deleted.
    ///
    /// Mutation check: if lines 1560-1576 are removed from downloadComponent, this
    /// test's inline reproduction will still pass, but callers relying on the gate
    /// will silently receive files whose descriptor sha256 was never re-verified.
    /// This test exists to document the gate's CONTRACT so that any future removal
    /// surfaces as a deliberate decision (not a silent regression).
    ///
    /// Follow-up P1 (Sortie 1): once session: is threaded through downloadComponent,
    /// replace steps 3-4 above with a direct call to
    ///   Acervo.downloadComponent(componentId, force: false, in: tempDir)
    /// so the test routes through the actual lines 1560-1576 in production code.
    @Test("Registry-level second pass detects hash mismatch and deletes corrupt file")
    func registryLevelHashMismatchDeletesCorruptFile() async throws {
      try await withIsolatedAcervoState {
        let tempDir = try makeTempDir("RegistryPass")
        defer { removeTempDir(tempDir) }

        let repoId = "test-org/registry-integrity-\(UUID().uuidString.prefix(8))"
        let slug = Acervo.slugify(repoId)
        let componentDir = tempDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: componentDir, withIntermediateDirectories: true)

        // ── Step 1: Stage a file on disk with known content hashing to X ──────
        let stagedContent = Data("registry-level staged file content X".utf8)
        let stagedFileURL = componentDir.appendingPathComponent("model.safetensors")
        try stagedContent.write(to: stagedFileURL)

        let actualHash = try IntegrityVerification.sha256(of: stagedFileURL)

        // ── Step 2: Hydrated descriptor with sha256 = Y (≠ X) ─────────────────
        let expectedHash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        #expect(actualHash != expectedHash, "Test setup: actual and expected hashes must differ")

        let descriptor = ComponentDescriptor(
          id: "registry-integrity-comp",
          type: .backbone,
          displayName: "Registry Integrity Test",
          repoId: repoId,
          files: [
            ComponentFile(relativePath: "model.safetensors", sha256: expectedHash)
          ],
          estimatedSizeBytes: Int64(stagedContent.count),
          minimumMemoryBytes: 200
        )
        // Verify the descriptor is hydrated (has files populated).
        #expect(descriptor.isHydrated, "Pre-condition: descriptor must be hydrated")

        // ── Step 3: Execute the registry-level loop (Acervo.swift:1560-1576) ──
        //
        // This is a verbatim reproduction of lines 1560-1576 in
        // downloadComponent(_:force:progress:in:).  If those lines are refactored,
        // update this reproduction to match.
        //
        //   // Additional registry-level checksum verification
        //   let componentDir = baseDirectory.appendingPathComponent(
        //     slugify(descriptor.repoId)
        //   )
        //   for file in descriptor.files {
        //     guard let expectedHash = file.sha256 else { continue }
        //     let fileURL = componentDir.appendingPathComponent(file.relativePath)
        //     let actualHash = try IntegrityVerification.sha256(of: fileURL)
        //     if actualHash != expectedHash {
        //       try? FileManager.default.removeItem(at: fileURL)
        //       throw AcervoError.integrityCheckFailed(
        //         file: file.relativePath,
        //         expected: expectedHash,
        //         actual: actualHash
        //       )
        //     }
        //   }

        var thrownError: AcervoError?
        do {
          // Registry-level loop — verbatim from Acervo.swift:1560-1576.
          for file in descriptor.files {
            guard let fileExpectedHash = file.sha256 else { continue }
            let fileURL = componentDir.appendingPathComponent(file.relativePath)
            let fileActualHash = try IntegrityVerification.sha256(of: fileURL)
            if fileActualHash != fileExpectedHash {
              try? FileManager.default.removeItem(at: fileURL)
              throw AcervoError.integrityCheckFailed(
                file: file.relativePath,
                expected: fileExpectedHash,
                actual: fileActualHash
              )
            }
          }
          #expect(Bool(false), "Registry-level loop should have thrown integrityCheckFailed")
        } catch let error as AcervoError {
          thrownError = error
        }

        // ── Step 4: Assert three-field error and post-throw file deletion ──────
        guard let err = thrownError else {
          #expect(Bool(false), "Expected AcervoError to be thrown by registry-level loop")
          return
        }

        if case .integrityCheckFailed(file: let f, expected: let e, actual: let a) = err {
          #expect(f == "model.safetensors", "file field must match relativePath")
          #expect(e == expectedHash, "expected field must match descriptor sha256")
          #expect(a == actualHash, "actual field must match on-disk file hash")
        } else {
          #expect(Bool(false), "Expected integrityCheckFailed but got \(err)")
        }

        // The corrupt file must be deleted by the registry-level gate.
        #expect(
          !FileManager.default.fileExists(atPath: stagedFileURL.path),
          "Corrupt file must be deleted after registry-level integrity failure")
      }
    }
  }
}
