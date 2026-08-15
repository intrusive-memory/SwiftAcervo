// ManifestCache.swift
// SwiftAcervo
//
// In-memory cache for fetched CDN manifests, keyed by the slug-keyed API
// contract (slug, url?). Introduced for the slug-registry mission so that
// slug-keyed APIs (`availability(slug:url:)`, `ensureAvailable(slug:url:...)`,
// `deleteModel(slug:url:)`) can resolve a manifest once and reuse the result.
//
// Contract:
//
//   - Lookup by `(slug, nil)` derives the canonical CDN URL from the slug
//     (via `AcervoDownloader.buildManifestURL(modelId:)`) and uses it as the
//     internal key. Lookup by `(slug, derivedURL)` resolves to the same key,
//     so the two lookup shapes return the same cached instance.
//
//   - Lookup by `(slug, explicitURL)` (where `explicitURL` is anything other
//     than the derived URL) uses `(slug, explicitURL)` as a distinct key.
//
//   - Lookup by an HF repo string (`"org/repo"`) is the special case where
//     `slug == "org/repo"` and the URL is derived — handled identically to
//     `(slug, nil)`.
//
// The implementation is a single backing dictionary keyed by the canonical
// `(slug, URL)` pair. There is no need for an index dictionary: derivation
// happens at lookup time, so `(slug, nil)` and `(slug, derivedURL)` collapse
// to the same key by construction.

import Foundation

/// In-memory cache for resolved CDN manifests keyed by `(slug, URL)`.
///
/// Thread-safe via actor isolation. The cache is a soft cache: entries are
/// never automatically evicted; callers can clear all entries via `clear()`
/// (primarily used by tests).
actor ManifestCache {

  /// Process-wide shared cache. Hosts that need a private cache can
  /// instantiate their own.
  static let shared = ManifestCache()

  /// Canonical key. Equality on both fields, so `(slug, nil)` resolved into
  /// `(slug, derivedURL(slug))` collapses with an explicit lookup that
  /// supplied the same derived URL.
  struct Key: Hashable, Sendable {
    let slug: String
    let url: URL
  }

  private var entries: [Key: CDNManifest] = [:]

  init() {}

  // MARK: - URL derivation

  /// Returns the canonical CDN manifest URL for a slug, mirroring
  /// `AcervoDownloader.buildManifestURL(modelId:)`. Centralized here so the
  /// (slug, url?) → Key resolution stays in one place.
  static func derivedURL(forSlug slug: String) -> URL {
    AcervoDownloader.buildManifestURL(modelId: slug)
  }

  /// Resolves `(slug, url?)` to the canonical lookup key.
  ///
  /// - `url == nil` → key URL is `derivedURL(forSlug: slug)`.
  /// - `url` supplied → key URL is the supplied URL (may equal the derived
  ///   URL, in which case the two lookup shapes produce the same key).
  static func key(slug: String, url: URL? = nil) -> Key {
    Key(slug: slug, url: url ?? derivedURL(forSlug: slug))
  }

  // MARK: - Read / write

  /// Returns the cached manifest for `(slug, url?)`, or `nil` if absent.
  func manifest(slug: String, url: URL? = nil) -> CDNManifest? {
    entries[Self.key(slug: slug, url: url)]
  }

  /// Stores `manifest` under `(slug, url?)`. The internal key is
  /// `(slug, url ?? derivedURL(slug))`.
  func store(_ manifest: CDNManifest, slug: String, url: URL? = nil) {
    entries[Self.key(slug: slug, url: url)] = manifest
  }

  /// Removes the entry for `(slug, url?)`. No-op if absent.
  func remove(slug: String, url: URL? = nil) {
    entries.removeValue(forKey: Self.key(slug: slug, url: url))
  }

  /// Drops every cached entry.
  func clear() {
    entries.removeAll()
  }

  /// Test affordance: number of distinct cache entries.
  var count: Int { entries.count }
}
