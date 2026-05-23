// Acervo+DeleteModel.swift
// SwiftAcervo
//
// Local-disk model deletion: removes a model's on-disk directory and clears
// any associated manifest cache entries.
//
// This file is symmetric with Acervo+CDNMutation.swift — that file deletes
// models FROM the CDN (remote objects in R2); this file deletes models FROM
// DISK (local cached copies in the shared models directory). Both files share
// the "delete" verb but operate on different storage layers.
//
// Two variants live here together because they share the same contract
// ("remove + clean up") and the same place in the consumer's mental model
// ("I want to free disk space for this model"):
//
//   §11 — deleteModel(_:telemetry:)          legacy repo-keyed (synchronous)
//   §12 — deleteModel(slug:url:)             slug-keyed (async, multi-component)

import Foundation

// MARK: - Delete Model

extension Acervo {

  /// Deletes a model's directory from the canonical shared models directory.
  ///
  /// Validates the model ID format, verifies the directory exists, then
  /// removes the entire model directory recursively.
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format
  ///   (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   `AcervoError.modelNotFound` if the model directory does not exist.
  ///
  /// ```swift
  /// try Acervo.deleteModel("mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// ```
  public static func deleteModel(
    _ modelId: String,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) throws {
    try deleteModel(modelId, in: sharedModelsDirectory, telemetry: telemetry)
  }

  /// Deletes a model's directory from the specified base directory.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format.
  ///   - baseDirectory: The base directory to use instead of `sharedModelsDirectory`.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   `AcervoError.modelNotFound` if the model directory does not exist.
  static func deleteModel(
    _ modelId: String,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) throws {
    // Validate model ID format (must contain exactly one "/")
    let slashCount = modelId.filter { $0 == "/" }.count
    guard slashCount == 1 else {
      throw AcervoError.invalidModelId(modelId)
    }

    let modelDir = baseDirectory.appendingPathComponent(slugify(modelId))

    // Verify directory exists
    guard FileManager.default.fileExists(atPath: modelDir.path) else {
      throw AcervoError.modelNotFound(modelId)
    }

    // Remove directory recursively
    try FileManager.default.removeItem(at: modelDir)
  }
}

// MARK: - Delete Model (slug-keyed)

extension Acervo {

  /// Deletes all component directories for a slug-keyed model.
  ///
  /// Resolves the manifest for `slug` (via the cache or a network fetch) to
  /// obtain the full list of component repos, then removes each component's
  /// on-disk folder unconditionally — **no existence check before removal**.
  ///
  /// ## Error model
  ///
  /// - Component folder does not exist → no-op success for that component.
  /// - Some component folders present, others not → deletes the ones that
  ///   exist and succeeds.
  /// - Manifest cannot be fetched (HTTP error) → throws
  ///   ``AcervoError/manifestFetchFailed(slug:status:)`` because Acervo
  ///   cannot know what to delete without the manifest.
  /// - `FileManager.removeItem` fails on an **existing** folder
  ///   (permission denied, I/O error, etc.) → throws the underlying
  ///   filesystem error verbatim.
  ///
  /// ## URL resolution rule
  ///
  /// Mirrors ``availability(slug:url:telemetry:)``:
  /// - `url` supplied → the manifest is fetched from that URL; `slug` is the
  ///   on-disk identifier.
  /// - `url` omitted + slug parses as `"org/repo"` → the canonical CDN
  ///   manifest URL is derived.
  /// - `url` omitted + slug does not parse as `"org/repo"` → throws
  ///   ``AcervoError/urlRequiredForSlug(_:)``.
  ///
  /// - Parameters:
  ///   - slug: The NAME_SLUG identifying the model (may be `"org/repo"` for
  ///     HF-style slugs or a plain slug when a `url` is provided).
  ///   - url: Optional manifest URL. If `nil` and `slug` is `"org/repo"`,
  ///     the URL is derived from the canonical CDN path.
  /// - Throws: ``AcervoError/urlRequiredForSlug(_:)`` when URL resolution is
  ///   impossible, ``AcervoError/manifestFetchFailed(slug:status:)`` on HTTP
  ///   failures, or a filesystem error when a present folder cannot be removed.
  ///
  /// ```swift
  /// // HF-style slug — URL derived automatically:
  /// try await Acervo.deleteModel(slug: "black-forest-labs/FLUX.2-klein-4B")
  ///
  /// // Opaque slug — explicit manifest URL required:
  /// try await Acervo.deleteModel(
  ///     slug: "flux2-klein-4b",
  ///     url: URL(string: "https://cdn.example/flux2-klein-4b/manifest.json")!
  /// )
  /// ```
  public static func deleteModel(slug: String, url: URL? = nil) async throws {
    try await deleteModel(slug: slug, url: url, in: sharedModelsDirectory, session: nil)
  }

  /// Internal overload of ``deleteModel(slug:url:)`` that accepts a custom
  /// base directory and an injected `URLSession` for tests.
  ///
  /// - Parameters:
  ///   - slug: The slug identifying the model.
  ///   - url: Optional manifest URL.
  ///   - baseDirectory: Base directory to resolve component folder paths against.
  ///   - session: Injected `URLSession` for tests (uses `SecureDownloadSession`
  ///     when `nil`).
  static func deleteModel(
    slug: String,
    url: URL? = nil,
    in baseDirectory: URL,
    session: URLSession? = nil
  ) async throws {
    // Resolve manifest URL per the API model (mirrors availability(slug:url:)).
    let manifestURL: URL
    if let url {
      manifestURL = url
    } else if isOrgRepoSlug(slug) {
      manifestURL = ManifestCache.derivedURL(forSlug: slug)
    } else {
      throw AcervoError.urlRequiredForSlug(slug)
    }

    // Fetch manifest (cache-aware). Throws manifestFetchFailed on HTTP errors.
    let manifest = try await fetchSlugManifest(
      slug: slug,
      manifestURL: manifestURL,
      session: session
    )

    // Delete each component folder unconditionally.
    // Per the exit criterion: no existence check before removeItem.
    // CocoaError.fileNoSuchFile (code 4 / NSFileNoSuchFileError) → no-op success.
    // Any other removeItem failure → re-throw verbatim.
    for componentRepo in manifest.components {
      let folderURL = baseDirectory.appendingPathComponent(slugify(componentRepo))
      do {
        try FileManager.default.removeItem(at: folderURL)
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
        // Folder does not exist — treat as success (no-op).
        _ = error
      }
      // Clear the per-component ManifestCache entry (idempotent).
      await ManifestCache.shared.remove(slug: componentRepo, url: nil)
    }

    // Clear the slug-level ManifestCache entry (idempotent).
    await ManifestCache.shared.remove(slug: slug, url: url)
  }
}
