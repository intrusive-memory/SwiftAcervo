#if os(macOS)
  import Foundation
  import Testing

  @testable import SwiftAcervo
  @testable import acervo

  /// Read-only CDN smoke test. Fetches a known-good manifest from the **public**
  /// R2 URL, verifies its checksum-of-checksums signature, and spot-checks one
  /// file's SHA-256 against the bytes served by the CDN.
  ///
  /// No credentials required — this exercises only the download side of the
  /// pipeline against live infrastructure. It is wired into PR CI (via the
  /// `make test-acervo-cdn` target) so every pull request gets a signal that:
  ///   1. The public CDN is still reachable.
  ///   2. A known-published manifest still verifies.
  ///   3. The download-and-verify code path still produces correct hashes
  ///      against bytes-on-the-wire.
  ///
  /// If the default slug is ever rotated off the CDN, override it by exporting
  /// `ACERVO_CI_CDN_MODEL_SLUG=<slug>` (e.g. via a repository-level variable in
  /// GitHub Actions) — no code change required.
  @Suite("CDN Manifest Fetch (Read-Only Smoke)")
  struct CDNManifestFetchTests {

    /// A small, stable, publicly-hosted model. Picked because the manifest is
    /// < 1 KB and the largest file is a few MB, so the whole suite runs in a
    /// few seconds even on a cold CI runner.
    private static let defaultSlug = "mlx-community_snac_24khz"

    private static var publicBaseURL: URL {
      let raw =
        ProcessInfo.processInfo.environment["R2_PUBLIC_URL"]
        ?? "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"
      return URL(string: raw)!
    }

    private static var slug: String {
      ProcessInfo.processInfo.environment["ACERVO_CI_CDN_MODEL_SLUG"] ?? defaultSlug
    }

    @Test("Published manifest fetches, decodes, and passes verifyChecksum()")
    func manifestVerifiesOnCDN() async throws {
      let uploader = CDNUploader()
      let manifest = try await uploader.verifyManifestOnCDN(
        publicBaseURL: Self.publicBaseURL,
        slug: Self.slug
      )

      #expect(manifest.verifyChecksum(), "CDN manifest must pass verifyChecksum()")
      #expect(!manifest.files.isEmpty, "Manifest must declare at least one file")
      #expect(!manifest.modelId.isEmpty, "Manifest must carry a non-empty modelId")
    }

    @Test("Spot-checking the smallest published file recomputes to the manifest SHA-256")
    func spotCheckSmallestFileMatchesManifest() async throws {
      let uploader = CDNUploader()
      let manifest = try await uploader.verifyManifestOnCDN(
        publicBaseURL: Self.publicBaseURL,
        slug: Self.slug
      )

      // Pick the smallest entry to keep the download cheap.
      guard let smallest = manifest.files.min(by: { $0.sizeBytes < $1.sizeBytes }) else {
        Issue.record("Manifest has no file entries to spot-check")
        return
      }

      try await uploader.spotCheckFileOnCDN(
        publicBaseURL: Self.publicBaseURL,
        slug: Self.slug,
        filename: smallest.path,
        expectedSHA256: smallest.sha256
      )
    }
  }
#endif
