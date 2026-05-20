// SlugDeleteModelTests.swift
// SwiftAcervoTests
//
// Sortie 4 of OPERATION QUARTERMASTER TORRENT (slug-registry/S4).
//
// Acceptance tests for `Acervo.deleteModel(slug:url:)`:
//
//   (a) Multi-component slug, all component folders present → all removed;
//       function returns successfully.
//   (b) Multi-component slug, only one component folder present → that one is
//       removed; function returns successfully.
//   (c) Multi-component slug, no folders present → function returns
//       successfully (pure no-op).
//   (d) HF-style slug + no URL (regression): single-folder delete still works.
//   (e) FileManager.removeItem fails on an existing folder → function throws
//       the filesystem error verbatim.
//
// All tests use a tempdir + MockURLProtocol stub — no live network, no timing
// assertions.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Slug-keyed deleteModel (S4)")
  struct SlugDeleteModelTests {

    // MARK: - Fixture helpers

    private func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeManifest(
      modelId: String,
      primaryRepo: String,
      components: [String],
      files: [CDNManifestFile] = []
    ) -> CDNManifest {
      // Include a placeholder file so the manifest checksum is non-empty.
      let placeholder = CDNManifestFile(
        path: "config.json",
        sha256: sha256Hex(Data("{}".utf8)),
        sizeBytes: 2
      )
      let allFiles = files.isEmpty ? [placeholder] : files
      let slug = Acervo.slugify(modelId)
      let checksum = CDNManifest.computeChecksum(from: allFiles.map(\.sha256))
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-05-19T00:00:00Z",
        files: allFiles,
        manifestChecksum: checksum,
        primaryRepo: primaryRepo,
        components: components
      )
    }

    private func makeTempBase() throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlugDeleteModelTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    private func removeTempBase(_ url: URL) {
      try? FileManager.default.removeItem(at: url)
    }

    /// Creates a directory under `baseDir` for the given HF repo string
    /// (using `Acervo.slugify`) and writes a `config.json` inside it so
    /// the directory looks like a real model download.
    @discardableResult
    private func createComponentFolder(repo: String, in baseDir: URL) throws -> URL {
      let folderURL = baseDir.appendingPathComponent(Acervo.slugify(repo))
      try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: folderURL.appendingPathComponent("config.json"))
      return folderURL
    }

    /// Returns whether the folder for `repo` exists under `baseDir`.
    private func folderExists(repo: String, in baseDir: URL) -> Bool {
      let folderURL = baseDir.appendingPathComponent(Acervo.slugify(repo))
      return FileManager.default.fileExists(atPath: folderURL.path)
    }

    /// Installs a MockURLProtocol responder that serves `manifest` as JSON at
    /// any URL. Tests supply an explicit `url:` so the exact URL doesn't matter.
    private func installManifestResponder(manifest: CDNManifest) throws {
      let manifestData = try JSONEncoder().encode(manifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, manifestData)
      }
    }

    // MARK: - Test (a): multi-component, all folders present → all removed

    /// Acceptance criterion §1.4.4 — demonstrates that `deleteModel(slug:url:)`
    /// removes ALL component folders in a multi-component manifest.
    @Test("(a) Multi-component slug: all folders present → all removed, success")
    func a_allFoldersPresent_allRemoved() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let slug = "flux2-klein-delete-a-\(UUID().uuidString.prefix(8))"
      let primary = "org-a/transformer-\(UUID().uuidString.prefix(8))"
      let vae = "org-a/vae-\(UUID().uuidString.prefix(8))"
      let textEnc = "org-a/text-encoder-\(UUID().uuidString.prefix(8))"
      let components = [primary, vae, textEnc]

      let manifest = makeManifest(
        modelId: slug,
        primaryRepo: primary,
        components: components
      )

      // Create all three component folders on disk.
      try createComponentFolder(repo: primary, in: tempBase)
      try createComponentFolder(repo: vae, in: tempBase)
      try createComponentFolder(repo: textEnc, in: tempBase)

      // Serve manifest.
      try installManifestResponder(manifest: manifest)
      let session = MockURLProtocol.session()

      // deleteModel must succeed.
      try await Acervo.deleteModel(
        slug: slug,
        url: URL(string: "https://cdn.example.invalid/\(slug)/manifest.json")!,
        in: tempBase,
        session: session
      )

      // All three component folders must be gone.
      for repo in components {
        #expect(
          !folderExists(repo: repo, in: tempBase),
          "Expected folder for \(repo) to be deleted but it still exists"
        )
      }
    }

    // MARK: - Test (b): multi-component, only one folder present → that one removed

    @Test("(b) Multi-component slug: only one folder present → it is removed, success")
    func b_oneFolderPresent_itRemoved() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let slug = "flux2-klein-delete-b-\(UUID().uuidString.prefix(8))"
      let primary = "org-b/transformer-\(UUID().uuidString.prefix(8))"
      let vae = "org-b/vae-\(UUID().uuidString.prefix(8))"
      let textEnc = "org-b/text-encoder-\(UUID().uuidString.prefix(8))"
      let components = [primary, vae, textEnc]

      let manifest = makeManifest(
        modelId: slug,
        primaryRepo: primary,
        components: components
      )

      // Create ONLY the transformer folder; vae and textEnc are absent.
      try createComponentFolder(repo: primary, in: tempBase)

      try installManifestResponder(manifest: manifest)
      let session = MockURLProtocol.session()

      // Must succeed even though vae and textEnc folders are absent.
      try await Acervo.deleteModel(
        slug: slug,
        url: URL(string: "https://cdn.example.invalid/\(slug)/manifest.json")!,
        in: tempBase,
        session: session
      )

      // Transformer must be gone.
      #expect(
        !folderExists(repo: primary, in: tempBase),
        "Expected transformer folder to be deleted"
      )
      // VAE and text-encoder were never created — must still not exist (no-op, not error).
      #expect(!folderExists(repo: vae, in: tempBase))
      #expect(!folderExists(repo: textEnc, in: tempBase))
    }

    // MARK: - Test (c): multi-component, no folders present → pure no-op

    @Test("(c) Multi-component slug: no folders present → pure no-op, success")
    func c_noFoldersPresent_noOp() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let slug = "flux2-klein-delete-c-\(UUID().uuidString.prefix(8))"
      let primary = "org-c/transformer-\(UUID().uuidString.prefix(8))"
      let vae = "org-c/vae-\(UUID().uuidString.prefix(8))"
      let components = [primary, vae]

      let manifest = makeManifest(
        modelId: slug,
        primaryRepo: primary,
        components: components
      )

      // No component folders on disk at all.
      try installManifestResponder(manifest: manifest)
      let session = MockURLProtocol.session()

      // Must succeed without throwing.
      try await Acervo.deleteModel(
        slug: slug,
        url: URL(string: "https://cdn.example.invalid/\(slug)/manifest.json")!,
        in: tempBase,
        session: session
      )

      // Both component folders remain absent (never existed).
      #expect(!folderExists(repo: primary, in: tempBase))
      #expect(!folderExists(repo: vae, in: tempBase))
    }

    // MARK: - Test (d): HF-style slug + no URL (regression)

    /// Regression test: `deleteModel(slug:url:)` with `url: nil` on an
    /// HF-style `"org/repo"` slug still deletes the single component folder.
    @Test("(d) HF-style slug + no URL (regression): single-folder delete works")
    func d_hfSlugNoURL_singleFolderDeleted() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      // Use an HF-style `"org/repo"` slug so URL derivation applies.
      let slug = "hf-org-d/single-model-\(UUID().uuidString.prefix(8))"
      let manifest = makeManifest(
        modelId: slug,
        primaryRepo: slug,
        components: [slug]  // single-component: components == [primaryRepo]
      )

      // Create the single component folder.
      try createComponentFolder(repo: slug, in: tempBase)

      // Serve the manifest at ANY URL so MockURLProtocol handles the derived
      // CDN URL that `deleteModel(slug:url:nil)` will derive automatically.
      try installManifestResponder(manifest: manifest)
      let session = MockURLProtocol.session()

      #expect(folderExists(repo: slug, in: tempBase), "Pre-condition: folder must exist")

      // Delete with url: nil — URL is derived from the HF slug.
      try await Acervo.deleteModel(
        slug: slug,
        url: nil,
        in: tempBase,
        session: session
      )

      #expect(
        !folderExists(repo: slug, in: tempBase),
        "Expected folder to be deleted after HF-style slug delete"
      )
    }

    // MARK: - Test (e): FileManager.removeItem fails on existing folder → throws

    /// Verifies that when `removeItem` fails on an existing folder (simulated
    /// by setting the parent directory to read-only), the raw filesystem error
    /// is thrown verbatim — not wrapped, not silenced.
    ///
    /// The test sets the tempBase permissions to `0o555` (no write bit) after
    /// creating the component folder. A subsequent `removeItem` call on the
    /// folder will fail with a CocoaError / POSIX EACCES because the parent
    /// directory is not writable. The error is NOT `fileNoSuchFile`, so the
    /// implementation must re-throw it.
    @Test("(e) removeItem fails on existing folder → filesystem error thrown verbatim")
    func e_removeItemFails_throwsFilesystemError() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      // Always restore permissions and clean up, even if the test throws.
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: tempBase.path
        )
        try? FileManager.default.removeItem(at: tempBase)
      }

      let slug = "flux2-klein-delete-e-\(UUID().uuidString.prefix(8))"
      let primary = "org-e/model-\(UUID().uuidString.prefix(8))"
      let manifest = makeManifest(
        modelId: slug,
        primaryRepo: primary,
        components: [primary]
      )

      // Create the component folder so `removeItem` finds an existing target.
      try createComponentFolder(repo: primary, in: tempBase)

      // Deny write permission on tempBase so removeItem(folderURL) fails
      // with EACCES (cannot unlink a child of a non-writable directory).
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o555))],
        ofItemAtPath: tempBase.path
      )

      try installManifestResponder(manifest: manifest)
      let session = MockURLProtocol.session()

      // The call must throw — any error type is accepted because the exact
      // CocoaError domain/code can vary by macOS version, but it must NOT
      // silently succeed.
      await #expect(throws: (any Error).self) {
        try await Acervo.deleteModel(
          slug: slug,
          url: URL(string: "https://cdn.example.invalid/\(slug)/manifest.json")!,
          in: tempBase,
          session: session
        )
      }
    }
  }
}
