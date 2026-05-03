// CacheBypassingRequest.swift
// SwiftAcervo
//
// Shared helper used by `Acervo.publishModel` (library) and `CDNUploader`
// (acervo CLI) to build `URLRequest`s for post-upload public-CDN readback
// that defeat every layer of caching between client and origin.
//
// Why this exists: immediately after a publish completes, the public
// readback verifying the new content can be satisfied by stale entries
// from any of three layers — the URLCache on the client, intermediate
// proxies, or the CDN edge cache. Any of those can produce false-negative
// (or, in some topologies, false-positive) verification outcomes that
// make CI/CD pipelines flaky and obscure deployment correctness.
//
// Both code paths (library publish, CLI ship/upload/verify) need the same
// hardening, so this helper is `package`-visible.

import Foundation

extension URLRequest {

  /// Builds a `URLRequest` for post-upload public verification that defeats
  /// every layer of caching between the client and the CDN origin:
  ///
  /// 1. **Query cache-buster** — appends `cb=<cacheBuster>` to the URL.
  ///    The caller picks a value that's unique enough for their context:
  ///    for content-correlated readbacks (e.g. verifying a specific
  ///    manifest), a content hash gives deterministic-per-deployment URLs
  ///    that still differ across deployments. For one-shot reads (e.g.
  ///    a CDN smoke test) a per-call UUID/timestamp is appropriate.
  ///    Defeats CDN edge caches that key on the full URL.
  /// 2. **`Cache-Control: no-cache`** header — instructs intermediaries to
  ///    revalidate with the origin before serving.
  /// 3. **`.reloadIgnoringLocalCacheData`** cache policy — bypasses the
  ///    process-local `URLCache` so we don't read a response from an
  ///    earlier publish.
  ///
  /// All three layers matter: (1) and (2) handle network-side caches,
  /// (3) handles process-local caching. Without all three, post-upload
  /// readbacks can return stale responses from any layer.
  package static func cacheBypassing(
    url: URL,
    cacheBuster: String
  ) -> URLRequest {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    items.append(URLQueryItem(name: "cb", value: cacheBuster))
    components?.queryItems = items
    let finalURL = components?.url ?? url

    var request = URLRequest(url: finalURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
    return request
  }
}
