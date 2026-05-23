// Acervo+ManifestAccess.swift
// SwiftAcervo
//
// Manifest-only CDN queries: `fetchManifest(for:)` and `fetchManifest(forComponent:)`.
// Both overloads support direct `modelId` and component-registry-mediated lookup.
// Consumers use this API to inspect model structure without triggering downloads.

import Foundation

extension Acervo {

  /// Returns the CDN manifest for a model by its model ID.
  ///
  /// Takes a model ID in `org/repo` format. Bypasses the component registry.
  /// For registry-aware lookup, use `fetchManifest(forComponent:)`. For the
  /// registry-aware download-side alternative that also rebuilds descriptors,
  /// use `hydrateComponent(_:)`.
  ///
  /// Use this for custom catalogs, cache warmers, or CI verification tools
  /// that need manifest data but don't want to trigger downloads.
  ///
  /// - Parameter modelId: The model identifier (e.g., `"mlx-community/Qwen2.5-7B-Instruct-4bit"`).
  /// - Returns: The validated `CDNManifest` for the model.
  /// - Throws: `AcervoError` for download, decoding, or validation failures
  ///   (including `manifestModelIdMismatch` if the server returns a manifest
  ///   whose `modelId` does not match the request).
  public static func fetchManifest(for modelId: String) async throws -> CDNManifest {
    try await fetchManifest(for: modelId, session: SecureDownloadSession.shared)
  }

  /// Public overload that accepts an injected `URLSession` so tests can
  /// stub the CDN via `MockURLProtocol`.
  public static func fetchManifest(
    for modelId: String,
    session: URLSession
  ) async throws -> CDNManifest {
    try await AcervoDownloader.downloadManifest(for: modelId, session: session)
  }

  /// Returns the CDN manifest for a registered component by looking up its
  /// `repoId` in `ComponentRegistry.shared`.
  ///
  /// Registry-aware counterpart to `fetchManifest(for:)`. Does not hydrate or
  /// mutate the registry — for that, use `hydrateComponent(_:)` instead.
  ///
  /// - Parameter componentId: The ID of a component registered with Acervo.
  /// - Returns: The validated `CDNManifest` for the component's `repoId`.
  /// - Throws: `AcervoError.componentNotRegistered` if `componentId` is unknown;
  ///   any manifest-related error propagated from `fetchManifest(for:)`.
  public static func fetchManifest(forComponent componentId: String) async throws -> CDNManifest {
    try await fetchManifest(forComponent: componentId, session: SecureDownloadSession.shared)
  }

  /// Public overload that accepts an injected `URLSession` so tests can
  /// stub the CDN via `MockURLProtocol`.
  public static func fetchManifest(
    forComponent componentId: String,
    session: URLSession
  ) async throws -> CDNManifest {
    guard let descriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }
    return try await fetchManifest(for: descriptor.repoId, session: session)
  }
}
