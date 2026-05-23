// Acervo+EnsureAvailable.swift
// SwiftAcervo
//
// Combines legacy repo-keyed ensureAvailable and slug-keyed multi-component
// ensureAvailable. Both share the progress/aggregator contract via
// ComponentStateBox (also moved here).
//
// Sections:
//
//   §10 — Legacy (repo-keyed)
//        ensureAvailable(_:files:progress:telemetry:)        public
//        ensureAvailable(_:files:progress:in:telemetry:session:) internal — test seam
//
//   §22 — Slug-keyed (multi-component)
//        ensureAvailable(slug:url:files:progress:telemetry:)        public
//        ensureAvailable(slug:url:files:progress:in:telemetry:session:) internal — test seam
//        ComponentStateBox                                          file-private aggregator
//
// Cross-file dependencies (all reachable as `internal` symbols from
// Acervo+SlugAvailability.swift):
//   - Acervo.isOrgRepoSlug(_:)
//   - Acervo.componentTotalBytes(_:in:)
//   - Acervo.fetchSlugManifest(slug:manifestURL:session:)
//

import Foundation

extension Acervo {

  // MARK: - Legacy (repo-keyed)

  /// Ensures a model is available locally, downloading it if necessary.
  ///
  /// If the model is already available (the cached manifest is present and
  /// every declared file is on disk at the recorded byte size), this method
  /// returns immediately without performing any downloads. Otherwise, it
  /// calls `download()` with `force: false`.
  ///
  /// ## Concurrency: download deduplication
  ///
  /// This method participates in a process-wide in-flight registry
  /// (`InFlightDownloads`). When two callers invoke `ensureAvailable` for
  /// the same `modelId` concurrently, both await a SINGLE underlying
  /// download Task — the registry guarantees the work is performed exactly
  /// once. Both callers receive the same outcome (success or the same
  /// thrown error). The registry entry is cleared once the download Task
  /// completes (success or failure), so a subsequent call after the
  /// completion starts a fresh download.
  ///
  /// **Dedup key is `modelId`, NOT `(modelId, files)`.** A joiner that
  /// requests a different `files` subset rides on the originator's set:
  /// for example, if the originator requested `["config.json",
  /// "model.safetensors"]` and a joiner requested only `["config.json"]`,
  /// the joiner does not trigger an additional download of just
  /// `config.json` — it awaits the originator's two-file download and
  /// inherits both files on disk. This trade-off is intentional. The
  /// overwhelmingly common production caller passes `files: []` (i.e.
  /// "everything in the manifest"), in which case there is no observable
  /// difference. Callers that genuinely need disjoint per-file downloads
  /// for the same model must serialize themselves at the call site.
  ///
  /// - Parameters:
  ///   - modelId: A model identifier in "org/repo" format
  ///     (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///   - files: An array of file names or relative paths within the model.
  ///     Pass `[]` to download every file in the manifest.
  ///   - progress: An optional callback invoked periodically with download
  ///     progress. Must be `@Sendable` for Swift 6 strict concurrency.
  ///     When two callers dedup, only the originator's `progress` callback
  ///     receives ticks from the underlying download; joiners receive their
  ///     final outcome via the `await` but do not see per-tick callbacks.
  /// - Throws: `AcervoError.invalidModelId` if the model ID format is invalid,
  ///   or download/manifest-related errors from `AcervoDownloader`.
  ///
  /// ```swift
  /// try await Acervo.ensureAvailable(
  ///     "mlx-community/Qwen2.5-7B-Instruct-4bit",
  ///     files: ["config.json", "model.safetensors"]
  /// )
  /// // Model is now guaranteed to be available locally
  /// ```
  public static func ensureAvailable(
    _ modelId: String,
    files: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureAvailable(
      modelId,
      files: files,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Ensures a model is available locally within a specified base directory,
  /// downloading it if necessary.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`. It is the sole
  /// implementation of the dedup logic; the public `ensureAvailable(...)`
  /// forwards here. See the public overload's doc comment for the dedup
  /// contract.
  ///
  /// `session` is an internal test-injection seam (default `nil` uses
  /// `SecureDownloadSession.shared`). The public API does not surface it.
  static func ensureAvailable(
    _ modelId: String,
    files: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    // Fast path: model is already strictly available (cached manifest + all
    // files at recorded sizes). No download, no registry interaction.
    if isModelAvailable(modelId, in: baseDirectory) { return }

    // Wrap the caller's progress callback so each tick also publishes to
    // InFlightDownloads. The joiner's wrappedProgress closure is built but
    // never installed: only the originator's closure is wired into the
    // actual download (because only the originator's `start` runs).
    let wrappedProgress: (@Sendable (AcervoDownloadProgress) -> Void) = { p in
      Task { await InFlightDownloads.shared.publishProgress(p.overallProgress, for: modelId) }
      progress?(p)
    }

    // Capture by-value so the @Sendable `start` closure can reference them.
    let capturedFiles = files
    let capturedBase = baseDirectory
    let capturedTelemetry = telemetry
    let capturedSession = session

    let sharedTask = await InFlightDownloads.shared.task(for: modelId) {
      Task {
        // Clear the registry entry on BOTH the success and the failure path.
        // `defer` is synchronous; `finish` is async, so we re-launch it in a
        // Task. The next caller after a thrown error sees `contains == false`
        // and starts a fresh download.
        defer {
          Task { await InFlightDownloads.shared.finish(modelId) }
        }
        try await download(
          modelId,
          files: capturedFiles,
          force: false,
          progress: wrappedProgress,
          in: capturedBase,
          telemetry: capturedTelemetry,
          session: capturedSession
        )
      }
    }
    try await sharedTask.value
  }

  // MARK: - Slug-keyed (multi-component)

  /// Ensures all components of a slug-keyed model are available locally,
  /// downloading any that are missing.
  ///
  /// This is the slug-registry-mission entry point introduced in
  /// `slug-registry/S3`. It mirrors ``availability(slug:url:telemetry:)``'s
  /// slug + URL resolution rule and extends the existing
  /// ``ensureAvailable(_:files:progress:telemetry:)`` to multi-component models.
  ///
  /// ## Slug + URL resolution rule
  ///
  /// * If `url` is supplied, it is used verbatim as the manifest fetch URL.
  ///   The `slug` is treated purely as the on-disk directory key.
  /// * If `url` is `nil` and `slug` parses as `"org/repo"` (single forward
  ///   slash, non-empty halves), the canonical CDN manifest URL is derived
  ///   from the slug.
  /// * If `url` is `nil` and `slug` does NOT parse as `"org/repo"`, the
  ///   method throws ``AcervoError/urlRequiredForSlug(_:)``.
  /// * If manifest fetch returns a non-2xx status, the method throws
  ///   ``AcervoError/manifestFetchFailed(slug:status:)``.
  ///
  /// ## Multi-component download
  ///
  /// Once the slug's manifest is resolved, each entry in `manifest.components`
  /// is downloaded in sequence via the existing repo-keyed
  /// ``ensureAvailable(_:files:progress:telemetry:)`` path. Download
  /// deduplication (``InFlightDownloads``) is keyed by `(modelId, file)` via
  /// the per-component calls, preserving the existing dedup contract.
  ///
  /// ## Progress aggregation
  ///
  /// The `progress:` callback receives a bytes-weighted aggregate across all
  /// components, computed via ``AvailabilityAggregator/aggregate(_:)`` — the
  /// same helper that ``availability(slug:url:telemetry:)`` uses.  Every
  /// component tick fires the caller's callback with the current aggregate
  /// state, so the callback rate is proportional to the total download activity
  /// across components (not just the last-started one).
  ///
  /// ## HF-repo regression protection
  ///
  /// The existing ``ensureAvailable(_:files:progress:telemetry:)`` signature is
  /// preserved unchanged; it continues to use the repo-keyed path and is not
  /// rerouted through this method.
  ///
  /// - Parameters:
  ///   - slug: The slug-level identifier. May or may not look like `"org/repo"`.
  ///   - url: An explicit manifest URL. `nil` triggers slug-based URL derivation
  ///     (which requires the slug to parse as `"org/repo"`).
  ///   - files: An array of file names to download within each component. Pass
  ///     `[]` to download every file in each component's manifest.
  ///   - progress: An optional callback invoked periodically with the aggregate
  ///     download progress across all components. Must be `@Sendable`.
  ///   - telemetry: Optional reporter.
  /// - Throws: ``AcervoError/urlRequiredForSlug(_:)`` when the slug needs an
  ///   explicit URL and none was supplied;
  ///   ``AcervoError/manifestFetchFailed(slug:status:)`` when the manifest
  ///   fetch returns a non-2xx HTTP status;
  ///   any error from the underlying per-component download (network failures,
  ///   integrity errors, etc.).
  public static func ensureAvailable(
    slug: String,
    url: URL? = nil,
    files: [String],
    progress: (@Sendable (ModelAvailability) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureAvailable(
      slug: slug,
      url: url,
      files: files,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Internal test seam for ``ensureAvailable(slug:url:files:progress:telemetry:)``.
  ///
  /// Accepts a custom `baseDirectory` and injected `URLSession` so tests can
  /// drive the full path via `MockURLProtocol` without touching
  /// `sharedModelsDirectory` or the live CDN.
  static func ensureAvailable(
    slug: String,
    url: URL? = nil,
    files: [String],
    progress: (@Sendable (ModelAvailability) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    // ---- Resolve the manifest URL per the (slug, url?) contract. ----
    // (Identical resolution rule to availability(slug:url:in:telemetry:session:).)
    let manifestURL: URL
    if let explicit = url {
      manifestURL = explicit
    } else if isOrgRepoSlug(slug) {
      manifestURL = ManifestCache.derivedURL(forSlug: slug)
    } else {
      throw AcervoError.urlRequiredForSlug(slug)
    }

    // ---- Fetch the manifest (cache-aware). ----
    let manifest: CDNManifest
    do {
      manifest = try await fetchSlugManifest(
        slug: slug,
        manifestURL: manifestURL,
        session: session
      )
    } catch let error as AcervoError {
      throw error
    } catch {
      throw AcervoError.networkError(error)
    }

    // ---- Per-component state tracking for aggregate progress. ----
    // We maintain a mutable state vector — one entry per component — and
    // recompute the aggregate via AvailabilityAggregator.aggregate(_:) on
    // every callback tick. This is the same helper that availability(slug:url:)
    // uses, guaranteeing the two paths cannot drift.
    //
    // The vector is captured by reference (class box) so the per-component
    // progress closures can mutate it concurrently. We guard mutations with an
    // NSLock so the aggregate snapshot is always coherent.
    let componentIds = manifest.components
    let componentCount = componentIds.count

    let stateBox = ComponentStateBox(count: componentCount)

    // ---- Download each component sequentially. ----
    for (index, componentId) in componentIds.enumerated() {
      // Determine the total bytes for this component (best-effort; used as
      // the aggregator weight). Read from the local cached manifest if present;
      // the actual bytes will be known after the first successful download.
      let componentBytesTotal = await componentTotalBytes(componentId, in: baseDirectory)

      // Build a per-component progress closure that:
      //   1. Updates the component's slot in the state box.
      //   2. Aggregates across all slots via AvailabilityAggregator.
      //   3. Fires the caller's progress callback with the aggregate.
      let capturedIndex = index
      let componentProgress: (@Sendable (AcervoDownloadProgress) -> Void)? = progress.map {
        outerProgress in
        let box = stateBox
        let total = componentBytesTotal
        return { @Sendable (p: AcervoDownloadProgress) in
          // Translate per-component AcervoDownloadProgress into a ModelAvailability
          // state for this component slot.
          let componentState: ModelAvailability = p.overallProgress >= 1.0
            ? .available : .downloading(progress: p.overallProgress)
          box.update(index: capturedIndex, availability: componentState, bytesTotal: total)
          let aggregate = AvailabilityAggregator.aggregate(box.snapshot())
          outerProgress(aggregate)
        }
      }

      // Mark this component as downloading in the state box before we start,
      // so that any aggregate snapshot taken before the first progress tick
      // reflects the fact that work is in flight.
      stateBox.update(
        index: index, availability: .downloading(progress: 0.0),
        bytesTotal: componentBytesTotal)
      if let progress {
        progress(AvailabilityAggregator.aggregate(stateBox.snapshot()))
      }

      // Delegate to the existing repo-keyed ensureAvailable, which handles:
      //   - Fast-path if already on disk (cached manifest + size check).
      //   - InFlightDownloads deduplication keyed by modelId.
      //   - Per-file SHA-256 verification.
      try await ensureAvailable(
        componentId,
        files: files,
        progress: componentProgress,
        in: baseDirectory,
        telemetry: telemetry,
        session: session
      )

      // Component finished: mark it as available.
      let finalBytes = await componentTotalBytes(componentId, in: baseDirectory)
        ?? componentBytesTotal
      stateBox.update(index: index, availability: .available, bytesTotal: finalBytes)
      if let progress {
        progress(AvailabilityAggregator.aggregate(stateBox.snapshot()))
      }
    }
  }
}

// MARK: - ComponentStateBox (file-private aggregator)

/// Per-component state vector used by `ensureAvailable(slug:url:files:progress:...)`
/// to compute bytes-weighted aggregate progress via `AvailabilityAggregator`.
///
/// File-private to this extension — the slug-keyed ensureAvailable is the
/// sole caller. Mutations are NSLock-guarded so concurrent per-component
/// progress closures yield coherent snapshots.
private final class ComponentStateBox: @unchecked Sendable {
  var states: [ComponentAvailabilityInput]
  let lock = NSLock()
  init(count: Int) {
    states = Array(
      repeating: ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: nil),
      count: count
    )
  }
  func update(index: Int, availability: ModelAvailability, bytesTotal: Int64?) {
    lock.lock()
    defer { lock.unlock() }
    states[index] = ComponentAvailabilityInput(
      availability: availability, bytesTotal: bytesTotal)
  }
  func snapshot() -> [ComponentAvailabilityInput] {
    lock.lock()
    defer { lock.unlock() }
    return states
  }
}
