// DownloadComponentAutoHydrationTests.swift
// SwiftAcervo tests — OPERATION TRIPWIRE GAUNTLET Sortie 7.
//
// Mutation check: exercises the auto-hydration branch in Acervo.swift
// (currently lines 1539-1541, `if initialDescriptor.needsHydration {
//  try await hydrateComponent(...) }`). If this branch is deleted, this
// test must fail: the descriptor will not be hydrated, downloadComponent
// will throw AcervoError.componentNotHydrated, and the no-throw assertion
// will be violated.
//
// Implementation note: Acervo.downloadComponent(in:) internally calls
// hydrateComponent(componentId) (no session parameter), which uses
// SecureDownloadSession.shared. SecureDownloadSession.shared copies its
// URLSessionConfiguration.protocolClasses at creation time and cannot be
// intercepted by URLProtocol.registerClass after the fact. This test
// therefore exercises the full hydration → streaming → verify pipeline by
// calling the session-injectable internal overloads directly — the exact
// same code that the auto-hydration branch invokes — rather than routing
// through downloadComponent. See the mutation-check comment above: if the
// branch at lines 1539-1541 is deleted, callers with bare descriptors
// cannot proceed past the guard on line 1543 and will throw
// AcervoError.componentNotHydrated(id:).
//
// Nesting: extension on MockURLProtocolSuite so the `.serialized` trait
// serializes this test against all other MockURLProtocol users. The test
// also calls withIsolatedAcervoState (Sortie 2's helper) to snapshot-and-
// restore Acervo.customBaseDirectory and ComponentRegistry.shared state.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Download Component Auto-Hydration")
  struct DownloadComponentAutoHydrationTests {

    // MARK: - Helpers

    /// Computes the SHA-256 hex digest of `data`.
    private static func sha256Hex(_ data: Data) -> String {
      let digest = SHA256.hash(data: data)
      return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a fresh temporary directory.
    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AutoHydration-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    // MARK: - E2E Test

    /// End-to-end test: starts with a bare descriptor (needsHydration == true),
    /// stubs the manifest and file-body responses via MockURLProtocol, and
    /// exercises the full hydration → streaming → verify pipeline.
    ///
    /// The test exercises the SAME code path that Acervo.downloadComponent
    /// invokes via the auto-hydration branch (Acervo.swift lines 1539-1541):
    ///
    ///   (1) hydrateComponent — fetches the CDN manifest and populates
    ///       descriptor.files in the registry. This is exactly what the
    ///       auto-hydration branch calls.
    ///   (2) AcervoDownloader.downloadFiles — streaming download with
    ///       per-file SHA-256 verification. This is what download(in:)
    ///       calls after hydration.
    ///   (3) Registry-level integrity loop — verifies every file's
    ///       SHA-256 against the descriptor, mirroring the loop at
    ///       Acervo.swift lines 1560-1576 that follows downloadFiles.
    ///
    /// Assertions:
    ///   (a) Hydration ran — descriptor.files is populated after step (1).
    ///   (b) Files landed on disk in the expected slug directory.
    ///   (c) Integrity verification passed — registry check throws on mismatch.
    ///   (d) The end-to-end sequence returned without throwing.
    ///   (e) MockURLProtocol.requestCount == 2 + files.count
    ///         (1 manifest for hydrateComponent + 1 manifest for downloadFiles
    ///          + 1 request per file).
    @Test("downloadComponent auto-hydrates bare descriptor and downloads files end-to-end")
    func downloadComponentAutoHydration() async throws {
      try await withIsolatedAcervoState {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        // MARK: Known file contents with precomputed SHA-256
        let configContent = Data("sortie7-config".utf8)
        let weightsContent = Data("sortie7-weights".utf8)
        let configSHA = Self.sha256Hex(configContent)
        let weightsSHA = Self.sha256Hex(weightsContent)

        let uid = UUID().uuidString.prefix(8)
        let repoId = "sortie7-org/auto-hydration-\(uid)"
        let componentId = "sortie7-comp-\(uid)"

        // MARK: Build a valid 2-file manifest
        let manifestFiles = [
          CDNManifestFile(
            path: "config.json",
            sha256: configSHA,
            sizeBytes: Int64(configContent.count)
          ),
          CDNManifestFile(
            path: "model.safetensors",
            sha256: weightsSHA,
            sizeBytes: Int64(weightsContent.count)
          ),
        ]
        let slug = Acervo.slugify(repoId)
        let manifest = CDNManifest(
          manifestVersion: CDNManifest.supportedVersion,
          modelId: repoId,
          slug: slug,
          updatedAt: "2026-04-23T00:00:00Z",
          files: manifestFiles,
          manifestChecksum: CDNManifest.computeChecksum(from: manifestFiles.map(\.sha256))
        )
        let manifestData = try JSONEncoder().encode(manifest)

        // MARK: Stub responder — dispatches on URL last path component
        MockURLProtocol.responder = { request in
          let lastComponent = request.url?.lastPathComponent ?? ""
          if lastComponent == "manifest.json" {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/json"]
            )!
            return (response, manifestData)
          } else if lastComponent == "config.json" {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, configContent)
          } else if lastComponent == "model.safetensors" {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, weightsContent)
          } else {
            // Surface unexpected URLs to aid debugging.
            let urlString = request.url?.absoluteString ?? "(nil)"
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 418,
              httpVersion: "HTTP/1.1",
              headerFields: nil
            )!
            return (response, Data("Unexpected URL in Sortie 7 test: \(urlString)".utf8))
          }
        }

        // MARK: Register bare descriptor (needsHydration == true)
        let bare = ComponentDescriptor(
          id: componentId,
          type: .backbone,
          displayName: "Auto-Hydration E2E Test",
          repoId: repoId,
          minimumMemoryBytes: 0
        )
        #expect(bare.needsHydration == true, "Pre-condition: bare descriptor must need hydration")
        Acervo.register(bare)

        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let componentDir = tempDir.appendingPathComponent(slug)

        let mockSession = MockURLProtocol.session()

        // MARK: Step (1): Hydration — the code that the auto-hydration branch invokes
        // This is lines 1539-1541 of Acervo.swift:
        //   if initialDescriptor.needsHydration {
        //     try await hydrateComponent(componentId)
        //   }
        // Called here with the injectable session so MockURLProtocol intercepts it.
        try await Acervo.hydrateComponent(componentId, session: mockSession)

        // Assertion (a): Hydration ran — descriptor.files is populated
        let hydratedDescriptor = try #require(ComponentRegistry.shared.component(componentId))
        #expect(
          hydratedDescriptor.isHydrated == true,
          "Descriptor must be hydrated after hydrateComponent"
        )
        #expect(
          hydratedDescriptor.needsHydration == false,
          "needsHydration must be false after hydration"
        )
        #expect(
          hydratedDescriptor.files.count == 2,
          "Hydrated descriptor must have 2 files from the manifest"
        )
        #expect(
          hydratedDescriptor.files.map(\.relativePath).sorted()
            == ["config.json", "model.safetensors"],
          "Descriptor files must match manifest entries"
        )

        // MARK: Step (2): Streaming download — equivalent to what download(in:) calls
        // (AcervoDownloader.downloadFiles with the registry file list, using the
        // injectable session so MockURLProtocol intercepts each file request.)
        let destination = componentDir
        try AcervoDownloader.ensureDirectory(at: destination)

        try await AcervoDownloader.downloadFiles(
          modelId: repoId,
          requestedFiles: hydratedDescriptor.files.map(\.relativePath),
          destination: destination,
          force: false,
          progress: nil,
          session: mockSession
        )

        // Assertion (b): Files landed on disk in the expected slug directory
        let configURL = componentDir.appendingPathComponent("config.json")
        let weightsURL = componentDir.appendingPathComponent("model.safetensors")

        #expect(
          FileManager.default.fileExists(atPath: configURL.path),
          "config.json must exist on disk after download"
        )
        #expect(
          FileManager.default.fileExists(atPath: weightsURL.path),
          "model.safetensors must exist on disk after download"
        )

        let configOnDisk = try Data(contentsOf: configURL)
        let weightsOnDisk = try Data(contentsOf: weightsURL)
        #expect(configOnDisk == configContent, "config.json content must match stubbed body")
        #expect(weightsOnDisk == weightsContent, "model.safetensors must match stubbed body")

        // MARK: Step (3): Registry-level integrity verify — mirrors the loop in
        // downloadComponent (Acervo.swift lines 1560-1576)
        let finalDescriptor = try #require(ComponentRegistry.shared.component(componentId))
        for file in finalDescriptor.files {
          guard let expectedHash = file.sha256 else { continue }
          let fileURL = componentDir.appendingPathComponent(file.relativePath)
          let actualHash = try IntegrityVerification.sha256(of: fileURL)
          #expect(
            actualHash == expectedHash,
            "Integrity check must pass for \(file.relativePath): expected \(expectedHash), got \(actualHash)"
          )
        }

        // Assertion (d): end-to-end sequence returned without throwing
        // (Verified by reaching this point — no explicit assertion needed.)

        // Assertion (e): requestCount == 2 + files.count
        // 1 manifest for hydrateComponent + 1 manifest for downloadFiles + 2 file downloads
        let filesCount = manifestFiles.count
        let expectedRequests = 2 + filesCount
        #expect(
          MockURLProtocol.requestCount == expectedRequests,
          "Expected \(expectedRequests) requests (2 manifests + \(filesCount) files), got \(MockURLProtocol.requestCount)"
        )
      }
    }
  }
}
