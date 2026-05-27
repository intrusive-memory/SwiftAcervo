import Foundation
import SwiftAcervo

/// CLI-internal seam around `Acervo.publishModel`.
///
/// `ShipCommand` and `UploadCommand` both end in a call to
/// `Acervo.publishModel(...)`. Production code goes straight through
/// `Acervo.publishModel`, which manages the live HTTP traffic and uses
/// `URLSession.shared` for the public CHECK 5 / CHECK 6 fetch. Tests
/// register an `override` closure here to assert call routing (e.g.
/// `keepOrphans` propagation) and drive the pipeline against a mocked
/// `URLSession` without touching the network.
///
/// This file lives in the CLI target (`Sources/acervo/`) so it does **not**
/// expand the public surface of `Sources/SwiftAcervo/` (REQUIREMENTS §4.4 /
/// framework control F5).
enum PublishRunner {

  /// Same shape as `Acervo.publishModel(modelId:directory:credentials:keepOrphans:progress:primaryRepo:components:slugOverride:)`
  /// but lifted to a value so it can be swapped out in tests. The
  /// `telemetry:` parameter is omitted because the CLI never wires
  /// telemetry today.
  ///
  /// The trailing `primaryRepo` / `components` / `slugOverride` parameters
  /// carry the slug-registry triple for `acervo ship --spec` multi-
  /// component flows. Single-component callers pass `nil` for all three
  /// and the library applies the existing defaults
  /// (`primaryRepo == modelId`, `components == [modelId]`,
  /// `slug == slug(from: modelId)`).
  typealias Function =
    @Sendable (
      _ modelId: String,
      _ directory: URL,
      _ credentials: AcervoCDNCredentials,
      _ keepOrphans: Bool,
      _ progress: (@Sendable (AcervoPublishProgress) -> Void)?,
      _ primaryRepo: String?,
      _ components: [String]?,
      _ slugOverride: String?
    ) async throws -> CDNManifest

  /// Tests set this to capture calls and short-circuit the live pipeline.
  /// Production leaves it `nil`, which means `run(...)` delegates straight
  /// through to `Acervo.publishModel`.
  nonisolated(unsafe) static var override: Function?

  /// Restores the default (no override). Tests should call this in a
  /// `defer` block after setting `override`.
  static func reset() {
    override = nil
  }

  /// Routes to the override if one is set, otherwise to the live
  /// `Acervo.publishModel(...)`.
  @discardableResult
  static func run(
    modelId: String,
    directory: URL,
    credentials: AcervoCDNCredentials,
    keepOrphans: Bool,
    progress: (@Sendable (AcervoPublishProgress) -> Void)?,
    primaryRepo: String? = nil,
    components: [String]? = nil,
    slugOverride: String? = nil
  ) async throws -> CDNManifest {
    if let override {
      return try await override(
        modelId, directory, credentials, keepOrphans, progress,
        primaryRepo, components, slugOverride
      )
    }
    return try await Acervo.publishModel(
      modelId: modelId,
      directory: directory,
      credentials: credentials,
      keepOrphans: keepOrphans,
      progress: progress,
      primaryRepo: primaryRepo,
      components: components,
      slugOverride: slugOverride
    )
  }
}
