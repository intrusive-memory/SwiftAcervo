import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  /// Tamper-detection coverage for `CDNManifest`'s checksum-of-checksums.
  ///
  /// Per `CDNManifest.computeChecksum(from:)`, the algorithm is exactly
  /// "sort `files[].sha256` lexicographically, concatenate, SHA-256 the bytes."
  /// That means `manifestChecksum` protects ONLY:
  ///
  ///   - the set of per-file SHA-256 values (any add / remove / mutation flips
  ///     the concatenation, which flips the digest)
  ///   - the `manifestChecksum` field itself (we compare declared vs. computed)
  ///
  /// It does NOT protect `path` or `sizeBytes`. Those are caught later in the
  /// download pipeline (path mismatches surface as `fileNotInManifest` when a
  /// caller asks for a file by name; size mismatches surface as
  /// `downloadSizeMismatch` once bytes start arriving). Tests for those
  /// downstream paths live in `EnsureAvailableEmptyFilesTests` and the
  /// downloader-level suites; this file covers manifest-level integrity only.
  ///
  /// Each test stubs the manifest URL with `MockURLProtocol` and drives
  /// `Acervo.fetchManifest(for:session:)`, which is the public entry point that
  /// wraps `AcervoDownloader.downloadManifest` (where the integrity check
  /// lives, currently AcervoDownloader.swift line ~263).
  @Suite("CDN Manifest Integrity Tests")
  struct CDNManifestIntegrityTests {

    // MARK: - Helpers

    private static func uniqueModelId() -> String {
      let uid = UUID().uuidString.prefix(8)
      return "manifest-integrity-test/repo-\(uid)"
    }

    /// Builds a valid 3-file manifest for `modelId` with a correct
    /// `manifestChecksum` derived from its files' SHA-256s.
    private static func makeValidManifest(modelId: String) -> CDNManifest {
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: "1111111111111111111111111111111111111111111111111111111111111111",
          sizeBytes: 16
        ),
        CDNManifestFile(
          path: "weights.safetensors",
          sha256: "2222222222222222222222222222222222222222222222222222222222222222",
          sizeBytes: 1024
        ),
        CDNManifestFile(
          path: "tokenizer.model",
          sha256: "3333333333333333333333333333333333333333333333333333333333333333",
          sizeBytes: 4096
        ),
      ]
      let slug = modelId.replacingOccurrences(of: "/", with: "_")
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-04-25T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    /// Stubs the URL protocol to return `manifest` for every request, then
    /// drives `fetchManifest` and asserts the result is `manifestIntegrityFailed`
    /// with the declared (`expected`) checksum from the served manifest and the
    /// `actual` checksum recomputed from its files.
    private static func assertIntegrityFailure(
      modelId: String,
      manifestData: Data,
      declaredChecksum: String,
      recomputedChecksum: String
    ) async {
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, manifestData)
      }

      do {
        _ = try await Acervo.fetchManifest(
          for: modelId,
          session: MockURLProtocol.session()
        )
        Issue.record("expected manifestIntegrityFailed to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .manifestIntegrityFailed(let expected, let actual):
          #expect(
            expected == declaredChecksum,
            "expected field should match the manifest's declared checksum")
          #expect(
            actual == recomputedChecksum,
            "actual field should match the recomputed checksum")
        default:
          Issue.record("expected .manifestIntegrityFailed, got \(error)")
        }
      } catch {
        Issue.record("expected AcervoError.manifestIntegrityFailed, got \(error)")
      }
    }

    // MARK: - Round-trip baseline

    @Test("Round-trip: untampered manifest decodes and validates cleanly")
    func roundTripUntamperedPasses() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let manifest = Self.makeValidManifest(modelId: modelId)
      let encoded = try JSONEncoder().encode(manifest)

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      let fetched = try await Acervo.fetchManifest(
        for: modelId,
        session: MockURLProtocol.session()
      )

      #expect(fetched.modelId == modelId)
      #expect(fetched.files.count == 3)
      #expect(fetched.verifyChecksum())
      #expect(fetched.manifestChecksum == manifest.manifestChecksum)
    }

    // MARK: - Mutation 1: tamper with an entry's sha256

    @Test("Tampered file sha256 throws manifestIntegrityFailed")
    func tamperedSha256ThrowsIntegrityFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let valid = Self.makeValidManifest(modelId: modelId)

      // Replace files[1].sha256 with a different digest, but keep the
      // manifest's stored checksum unchanged. The computed checksum of the
      // mutated file list will no longer match.
      let tamperedFiles = [
        valid.files[0],
        CDNManifestFile(
          path: valid.files[1].path,
          sha256: String(repeating: "a", count: 64),
          sizeBytes: valid.files[1].sizeBytes
        ),
        valid.files[2],
      ]
      let tampered = CDNManifest(
        manifestVersion: valid.manifestVersion,
        modelId: valid.modelId,
        slug: valid.slug,
        updatedAt: valid.updatedAt,
        files: tamperedFiles,
        manifestChecksum: valid.manifestChecksum  // stale: computed before mutation
      )
      let encoded = try JSONEncoder().encode(tampered)
      let recomputed = CDNManifest.computeChecksum(from: tamperedFiles.map(\.sha256))

      await Self.assertIntegrityFailure(
        modelId: modelId,
        manifestData: encoded,
        declaredChecksum: valid.manifestChecksum,
        recomputedChecksum: recomputed
      )
    }

    // MARK: - Mutation 2: add a file entry

    @Test("Added file entry throws manifestIntegrityFailed")
    func addedFileThrowsIntegrityFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let valid = Self.makeValidManifest(modelId: modelId)

      // Append a file the manifest didn't account for when its checksum was
      // computed. The recomputed checksum picks up the extra sha256 entry.
      let tamperedFiles = valid.files + [
        CDNManifestFile(
          path: "smuggled.bin",
          sha256: "4444444444444444444444444444444444444444444444444444444444444444",
          sizeBytes: 8
        )
      ]
      let tampered = CDNManifest(
        manifestVersion: valid.manifestVersion,
        modelId: valid.modelId,
        slug: valid.slug,
        updatedAt: valid.updatedAt,
        files: tamperedFiles,
        manifestChecksum: valid.manifestChecksum
      )
      let encoded = try JSONEncoder().encode(tampered)
      let recomputed = CDNManifest.computeChecksum(from: tamperedFiles.map(\.sha256))

      await Self.assertIntegrityFailure(
        modelId: modelId,
        manifestData: encoded,
        declaredChecksum: valid.manifestChecksum,
        recomputedChecksum: recomputed
      )
    }

    // MARK: - Mutation 3: remove a file entry

    @Test("Removed file entry throws manifestIntegrityFailed")
    func removedFileThrowsIntegrityFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let valid = Self.makeValidManifest(modelId: modelId)

      // Drop the middle file. The recomputed checksum is over a shorter list.
      let tamperedFiles = [valid.files[0], valid.files[2]]
      let tampered = CDNManifest(
        manifestVersion: valid.manifestVersion,
        modelId: valid.modelId,
        slug: valid.slug,
        updatedAt: valid.updatedAt,
        files: tamperedFiles,
        manifestChecksum: valid.manifestChecksum
      )
      let encoded = try JSONEncoder().encode(tampered)
      let recomputed = CDNManifest.computeChecksum(from: tamperedFiles.map(\.sha256))

      await Self.assertIntegrityFailure(
        modelId: modelId,
        manifestData: encoded,
        declaredChecksum: valid.manifestChecksum,
        recomputedChecksum: recomputed
      )
    }

    // MARK: - Mutation 4: mutate manifestChecksum itself

    @Test("Mutated manifestChecksum field throws manifestIntegrityFailed")
    func mutatedChecksumFieldThrowsIntegrityFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let valid = Self.makeValidManifest(modelId: modelId)

      // Files are untouched, so the recomputed checksum equals the original
      // valid one. Only the declared `manifestChecksum` field is wrong.
      let wrongChecksum = String(repeating: "f", count: 64)
      let tampered = CDNManifest(
        manifestVersion: valid.manifestVersion,
        modelId: valid.modelId,
        slug: valid.slug,
        updatedAt: valid.updatedAt,
        files: valid.files,
        manifestChecksum: wrongChecksum
      )
      let encoded = try JSONEncoder().encode(tampered)

      await Self.assertIntegrityFailure(
        modelId: modelId,
        manifestData: encoded,
        declaredChecksum: wrongChecksum,
        recomputedChecksum: valid.manifestChecksum
      )
    }

    // MARK: - Documenting what manifestChecksum does NOT cover
    //
    // The two tests below assert the current contract: tampering with `path`
    // or `sizeBytes` does NOT trip `manifestIntegrityFailed`, because the
    // checksum-of-checksums is computed over `sha256` values only. Those
    // mutations are caught downstream — `path` via `file(at:)` lookup
    // (`fileNotInManifest`) when a caller names files explicitly, and
    // `sizeBytes` via per-file streaming verification (`downloadSizeMismatch`).
    //
    // These are kept here as regression sentinels so that anyone tightening
    // `computeChecksum` to cover additional fields will see them break and
    // remember to update the contract documentation in CDNManifest.swift.

    @Test("Tampered path passes manifest integrity check (current contract)")
    func tamperedPathPassesManifestIntegrity() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let valid = Self.makeValidManifest(modelId: modelId)

      // Rewrite a file's path; sha256 list is unchanged so the checksum still
      // matches.
      let tamperedFiles = [
        valid.files[0],
        CDNManifestFile(
          path: "evil.safetensors",
          sha256: valid.files[1].sha256,
          sizeBytes: valid.files[1].sizeBytes
        ),
        valid.files[2],
      ]
      let tampered = CDNManifest(
        manifestVersion: valid.manifestVersion,
        modelId: valid.modelId,
        slug: valid.slug,
        updatedAt: valid.updatedAt,
        files: tamperedFiles,
        manifestChecksum: valid.manifestChecksum
      )
      let encoded = try JSONEncoder().encode(tampered)

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      // The fetch succeeds because path is not in the checksum input.
      let fetched = try await Acervo.fetchManifest(
        for: modelId,
        session: MockURLProtocol.session()
      )
      #expect(fetched.files.contains { $0.path == "evil.safetensors" })
    }

    @Test("Tampered sizeBytes passes manifest integrity check (current contract)")
    func tamperedSizeBytesPassesManifestIntegrity() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = Self.uniqueModelId()
      let valid = Self.makeValidManifest(modelId: modelId)

      // Inflate sizeBytes; sha256 list is unchanged so the checksum still
      // matches.
      let tamperedFiles = [
        valid.files[0],
        CDNManifestFile(
          path: valid.files[1].path,
          sha256: valid.files[1].sha256,
          sizeBytes: valid.files[1].sizeBytes * 1024
        ),
        valid.files[2],
      ]
      let tampered = CDNManifest(
        manifestVersion: valid.manifestVersion,
        modelId: valid.modelId,
        slug: valid.slug,
        updatedAt: valid.updatedAt,
        files: tamperedFiles,
        manifestChecksum: valid.manifestChecksum
      )
      let encoded = try JSONEncoder().encode(tampered)

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encoded)
      }

      // The fetch succeeds because sizeBytes is not in the checksum input.
      let fetched = try await Acervo.fetchManifest(
        for: modelId,
        session: MockURLProtocol.session()
      )
      #expect(fetched.files[1].sizeBytes == valid.files[1].sizeBytes * 1024)
    }
  }
}
