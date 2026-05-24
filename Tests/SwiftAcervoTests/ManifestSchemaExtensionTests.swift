// ManifestSchemaExtensionTests.swift
// SwiftAcervo
//
// Sortie 1 of OPERATION QUARTERMASTER TORRENT (slug-registry/S1).
//
// Locks in the three exit-criterion tests for the manifest schema extension:
//
//   (a) Decoding a manifest carrying modelId + primaryRepo + components
//       succeeds and the values round-trip.
//   (b) Decoding a manifest missing any of those three fields throws
//       DecodingError. No legacy fallback, no migration shim.
//   (c) ManifestCache lookup by `(slug, nil)` returns the same cached
//       instance as lookup by `(slug, derivedURL)` — the (slug, url?)
//       contract collapses to one key when the URL is derived.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Manifest Schema Extension Tests")
struct ManifestSchemaExtensionTests {

  // MARK: - Fixtures

  /// Builds a manifest JSON literal with optional omission of the three
  /// required slug-registry fields. Each `nil` argument drops that field
  /// from the JSON entirely so we can assert the strict-decode contract.
  private static func makeManifestJSON(
    includeModelId: Bool = true,
    includePrimaryRepo: Bool = true,
    includeComponents: Bool = true
  ) -> String {
    var lines: [String] = []
    lines.append("  \"manifestVersion\": 1")
    if includeModelId {
      lines.append("  \"modelId\": \"org/repo\"")
    }
    if includePrimaryRepo {
      lines.append("  \"primaryRepo\": \"org/repo\"")
    }
    if includeComponents {
      lines.append("  \"components\": [\"org/repo\"]")
    }
    lines.append("  \"slug\": \"org_repo\"")
    lines.append("  \"updatedAt\": \"2026-05-19T00:00:00Z\"")
    lines.append(
      "  \"files\": [{\"path\": \"config.json\", \"sha256\": \"aa\", \"sizeBytes\": 1}]")
    lines.append("  \"manifestChecksum\": \"placeholder\"")
    return "{\n" + lines.joined(separator: ",\n") + "\n}"
  }

  // MARK: - (a) Strict-decode success

  @Test("decode succeeds when modelId + primaryRepo + components all present")
  func decodeSucceedsWithAllThreeFields() throws {
    let json = Self.makeManifestJSON()
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    #expect(manifest.modelId == "org/repo")
    #expect(manifest.primaryRepo == "org/repo")
    #expect(manifest.components == ["org/repo"])
  }

  @Test("decode preserves multi-component primaryRepo invariant on the wire")
  func decodePreservesMultiComponentPrimaryRepo() throws {
    // Multi-component VAE manifest: modelId is the VAE's own repo, but
    // primaryRepo is the shared slug-level value. This is the invariant
    // S5's spec-file uploader is required to satisfy.
    let json = """
      {
        "manifestVersion": 1,
        "modelId": "black-forest-labs/FLUX.2-vae",
        "primaryRepo": "black-forest-labs/FLUX.2-klein-4B",
        "components": [
          "black-forest-labs/FLUX.2-klein-4B",
          "black-forest-labs/FLUX.2-vae",
          "google/t5-v1_1-xxl"
        ],
        "slug": "black-forest-labs_FLUX.2-vae",
        "updatedAt": "2026-05-19T00:00:00Z",
        "files": [{"path": "config.json", "sha256": "aa", "sizeBytes": 1}],
        "manifestChecksum": "placeholder"
      }
      """
    let manifest = try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    #expect(manifest.modelId == "black-forest-labs/FLUX.2-vae")
    #expect(manifest.primaryRepo == "black-forest-labs/FLUX.2-klein-4B")
    #expect(manifest.modelId != manifest.primaryRepo)
    #expect(manifest.components.count == 3)
    #expect(manifest.components.contains("black-forest-labs/FLUX.2-vae"))
    #expect(manifest.components.first == manifest.primaryRepo)
  }

  // MARK: - (b) Strict-decode failure: missing field → DecodingError

  @Test("decode throws DecodingError.keyNotFound when modelId is missing")
  func decodeFailsWhenModelIdMissing() {
    let json = Self.makeManifestJSON(includeModelId: false)
    #expect {
      try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    } throws: { error in
      // Must be a DecodingError.keyNotFound for "modelId" — no fallback path.
      guard case DecodingError.keyNotFound(let key, _) = error else {
        return false
      }
      return key.stringValue == "modelId"
    }
  }

  @Test("decode throws DecodingError.keyNotFound when primaryRepo is missing")
  func decodeFailsWhenPrimaryRepoMissing() {
    let json = Self.makeManifestJSON(includePrimaryRepo: false)
    #expect {
      try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    } throws: { error in
      guard case DecodingError.keyNotFound(let key, _) = error else {
        return false
      }
      return key.stringValue == "primaryRepo"
    }
  }

  @Test("decode throws DecodingError.keyNotFound when components is missing")
  func decodeFailsWhenComponentsMissing() {
    let json = Self.makeManifestJSON(includeComponents: false)
    #expect {
      try JSONDecoder().decode(CDNManifest.self, from: Data(json.utf8))
    } throws: { error in
      guard case DecodingError.keyNotFound(let key, _) = error else {
        return false
      }
      return key.stringValue == "components"
    }
  }

  // MARK: - (c) Cache lookup contract: (slug, nil) == (slug, derivedURL)

  @Test(
    "ManifestCache: lookup by (slug, nil) and (slug, derivedURL) resolves to the same entry"
  )
  func cacheCollapsesSlugAndDerivedURL() async throws {
    let cache = ManifestCache()
    let slug = "schema-cache-test/repo-\(UUID().uuidString.prefix(8))"
    let manifest = CDNManifest(
      manifestVersion: 1,
      modelId: slug,
      slug: slug.replacingOccurrences(of: "/", with: "_"),
      updatedAt: "2026-05-19T00:00:00Z",
      files: [],
      manifestChecksum: CDNManifest.computeChecksum(from: [])
    )

    // Store via the (slug, nil) shape — which derives the URL internally.
    await cache.store(manifest, slug: slug)

    // Look up via (slug, nil): hit.
    let viaNil = await cache.manifest(slug: slug)
    #expect(viaNil != nil)
    #expect(viaNil?.modelId == slug)

    // Look up via (slug, derivedURL): must hit the same entry.
    let derived = ManifestCache.derivedURL(forSlug: slug)
    let viaDerived = await cache.manifest(slug: slug, url: derived)
    #expect(viaDerived != nil)
    #expect(viaDerived?.modelId == slug)

    // Both call shapes resolved to the canonical key, so the cache holds
    // exactly one entry — no double-storage.
    let count = await cache.count
    #expect(count == 1)
  }

  @Test("ManifestCache: explicit non-derived URL is a distinct key from (slug, nil)")
  func cacheTreatsExplicitNonDerivedURLAsDistinct() async throws {
    let cache = ManifestCache()
    let slug = "schema-cache-test/repo-\(UUID().uuidString.prefix(8))"
    let manifest = CDNManifest(
      manifestVersion: 1,
      modelId: slug,
      slug: slug.replacingOccurrences(of: "/", with: "_"),
      updatedAt: "2026-05-19T00:00:00Z",
      files: [],
      manifestChecksum: CDNManifest.computeChecksum(from: [])
    )

    // Store under (slug, nil) — derived URL key.
    await cache.store(manifest, slug: slug)

    // Look up under (slug, explicitURL) where explicitURL is NOT the derived
    // one. Must miss, since that's a different canonical key.
    let other = URL(string: "https://example.invalid/staging/\(slug)/manifest.json")!
    let viaOther = await cache.manifest(slug: slug, url: other)
    #expect(viaOther == nil)

    // Now store under (slug, explicitURL) and confirm it lives alongside,
    // not on top of, the derived-URL entry.
    await cache.store(manifest, slug: slug, url: other)
    let count = await cache.count
    #expect(count == 2)

    // Both remain independently retrievable.
    let nilHit = await cache.manifest(slug: slug)
    let explicitHit = await cache.manifest(slug: slug, url: other)
    #expect(nilHit?.modelId == slug)
    #expect(explicitHit?.modelId == slug)
  }

  @Test("ManifestCache: HF-repo-style slug lookup is just (slug, nil) — derives canonical URL")
  func cacheHFRepoStyleSlugIsNilURLCase() async throws {
    // The "HF repo string" lookup path the sortie spec calls out is just the
    // special case where slug looks like "org/repo" and the caller supplies
    // no URL. There is no separate code path — it goes through the same
    // (slug, nil) entry as any other slug.
    let cache = ManifestCache()
    let hfRepo = "black-forest-labs/FLUX.2-klein-4B-test-\(UUID().uuidString.prefix(8))"
    let manifest = CDNManifest(
      manifestVersion: 1,
      modelId: hfRepo,
      slug: hfRepo.replacingOccurrences(of: "/", with: "_"),
      updatedAt: "2026-05-19T00:00:00Z",
      files: [],
      manifestChecksum: CDNManifest.computeChecksum(from: [])
    )

    await cache.store(manifest, slug: hfRepo)

    // Lookup by the HF repo string with no URL → hits the canonical entry.
    let viaRepoString = await cache.manifest(slug: hfRepo)
    #expect(viaRepoString != nil)

    // Lookup by the same slug + the derived URL → same entry.
    let derived = ManifestCache.derivedURL(forSlug: hfRepo)
    let viaDerived = await cache.manifest(slug: hfRepo, url: derived)
    #expect(viaDerived != nil)

    let count = await cache.count
    #expect(count == 1)
  }
}
