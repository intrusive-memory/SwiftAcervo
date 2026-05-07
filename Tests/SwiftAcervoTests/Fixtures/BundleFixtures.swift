// BundleFixtures.swift
// SwiftAcervoTests
//
// Shared mock-CDN fixtures for the bundle-component tests (Sorties 2–4).
// Exposes a Flux-style bundle manifest covering 5 files across 3 subfolders
// and typed body data for MockURLProtocol responders.
//
// Usage (from any test file):
//
//   let (manifest, bodies) = BundleFixtures.fluxStyleManifest()
//   MockURLProtocol.responder = BundleFixtures.makeResponder(manifest: manifest, bodies: bodies)

import CryptoKit
import Foundation

@testable import SwiftAcervo

// MARK: - BundleFixtures

/// Shared fixture factory for bundle-component tests.
///
/// All Sorties that need a multi-subfolder CDN manifest call the same static
/// factory so the fixture stays consistent across Sorties 2, 3, and 4.
enum BundleFixtures {

  // MARK: - File contents (deterministic byte sequences)

  /// Deterministic content for each file in the fixture bundle.
  /// Keys are the CDN-relative paths used in the manifest.
  static let fileContents: [String: Data] = [
    "transformer/model.safetensors": Data("bundle-transformer-weights".utf8),
    "text_encoder/config.json": Data("bundle-text-encoder-config".utf8),
    "text_encoder/model.safetensors": Data("bundle-text-encoder-weights".utf8),
    "vae/config.json": Data("bundle-vae-config".utf8),
    "vae/diffusion_pytorch_model.safetensors": Data("bundle-vae-weights".utf8),
  ]

  // MARK: - Static factory

  /// Builds a Flux-style CDN manifest covering 5 files across 3 subfolders.
  ///
  /// Returns the `CDNManifest` value and a dictionary of `path → Data` that
  /// callers should serve from `MockURLProtocol.responder`.
  ///
  /// - Parameter repoId: The `org/repo` identifier to embed in the manifest.
  ///   Defaults to a stable test repo ID. Pass a unique value when tests need
  ///   isolation between different registrations.
  /// - Returns: A tuple of `(manifest, fileBodies)` where `fileBodies` maps
  ///   CDN-relative path strings to the `Data` that the mock server should serve.
  static func fluxStyleManifest(
    repoId: String = "test-bundle-org/flux-style-bundle"
  ) -> (manifest: CDNManifest, fileBodies: [String: Data]) {
    let slug = Acervo.slugify(repoId)

    // Build manifest file entries with precomputed SHA-256 digests.
    let manifestFiles: [CDNManifestFile] = fileContents
      .sorted(by: { $0.key < $1.key })
      .map { path, data in
        CDNManifestFile(
          path: path,
          sha256: sha256Hex(data),
          sizeBytes: Int64(data.count)
        )
      }

    let manifest = CDNManifest(
      manifestVersion: CDNManifest.supportedVersion,
      modelId: repoId,
      slug: slug,
      updatedAt: "2026-05-01T00:00:00Z",
      files: manifestFiles,
      manifestChecksum: CDNManifest.computeChecksum(from: manifestFiles.map(\.sha256))
    )

    return (manifest, fileContents)
  }

  // MARK: - MockURLProtocol responder factory

  /// Creates a `MockURLProtocol.Responder` that serves the given manifest JSON
  /// and file bodies keyed by their last path component.
  ///
  /// The responder matches requests by last URL path component:
  ///   - "manifest.json" → encoded manifest
  ///   - any other key found in `fileBodies` by *full relative path suffix* match → file body
  ///   - unknown → 418 (surfaced in test output for debugging)
  ///
  /// Note: Because CDN URLs embed the relative path in their URL, the responder
  /// matches the longest matching suffix against the `fileBodies` dictionary keys.
  /// For example `https://cdn.example.com/models/org_repo/transformer/model.safetensors`
  /// is matched by iterating `fileBodies` keys and finding "transformer/model.safetensors"
  /// as a suffix of the URL path.
  static func makeResponder(
    manifest: CDNManifest,
    fileBodies: [String: Data]
  ) -> MockURLProtocol.Responder {
    let manifestData = (try? JSONEncoder().encode(manifest)) ?? Data()

    return { request in
      let urlPath = request.url?.path ?? ""
      let urlString = request.url?.absoluteString ?? "(nil)"

      // Serve manifest
      if request.url?.lastPathComponent == "manifest.json" {
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, manifestData)
      }

      // Match file body by longest-suffix match of the URL path.
      // Sort keys longest-first so more-specific paths win.
      let sortedKeys = fileBodies.keys.sorted { $0.count > $1.count }
      for key in sortedKeys {
        if urlPath.hasSuffix(key) || urlPath.hasSuffix("/" + key) {
          let body = fileBodies[key]!
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
          )!
          return (response, body)
        }
      }

      // Unknown URL — 418 to surface debugging info.
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 418,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      return (response, Data("BundleFixtures: unexpected URL: \(urlString)".utf8))
    }
  }

  // MARK: - ComponentDescriptor factories

  /// Creates the three bundle component descriptors (pre-hydrated) that share
  /// `repoId` but each declare a distinct subset of files.
  ///
  /// - Parameter repoId: CDN repo identifier. Must match the one used in
  ///   `fluxStyleManifest(repoId:)`.
  /// - Returns: A tuple `(transformer, textEncoder, vae)` of pre-hydrated descriptors.
  static func bundleDescriptors(
    repoId: String = "test-bundle-org/flux-style-bundle"
  ) -> (transformer: ComponentDescriptor, textEncoder: ComponentDescriptor, vae: ComponentDescriptor) {
    let transformer = ComponentDescriptor(
      id: "bundle-transformer",
      type: .backbone,
      displayName: "Bundle Transformer",
      repoId: repoId,
      files: [
        ComponentFile(relativePath: "transformer/model.safetensors"),
      ],
      estimatedSizeBytes: 100,
      minimumMemoryBytes: 0
    )

    let textEncoder = ComponentDescriptor(
      id: "bundle-text-encoder",
      type: .encoder,
      displayName: "Bundle Text Encoder",
      repoId: repoId,
      files: [
        ComponentFile(relativePath: "text_encoder/config.json"),
        ComponentFile(relativePath: "text_encoder/model.safetensors"),
      ],
      estimatedSizeBytes: 200,
      minimumMemoryBytes: 0
    )

    let vae = ComponentDescriptor(
      id: "bundle-vae",
      type: .decoder,
      displayName: "Bundle VAE",
      repoId: repoId,
      files: [
        ComponentFile(relativePath: "vae/config.json"),
        ComponentFile(relativePath: "vae/diffusion_pytorch_model.safetensors"),
      ],
      estimatedSizeBytes: 200,
      minimumMemoryBytes: 0
    )

    return (transformer, textEncoder, vae)
  }

  // MARK: - Private helpers

  /// Returns the SHA-256 digest of `data` as a lowercase hex string.
  private static func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}
