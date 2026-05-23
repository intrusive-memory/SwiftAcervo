// Acervo.swift
// SwiftAcervo
//
// Static API namespace for shared AI model discovery and management.
//
// Acervo ("collection" / "repository" in Portuguese) provides a single
// canonical location for AI models across the intrusive-memory
// ecosystem. All model path resolution, availability checks, discovery,
// and download operations are accessed through static methods
// on this enum.
//
// Usage:
//
//     import SwiftAcervo
//
//     let dir = Acervo.sharedModelsDirectory
//     let available = Acervo.isModelAvailable("mlx-community/Qwen2.5-7B-Instruct-4bit")
//

import Foundation

/// Static API namespace for shared AI model discovery and management.
///
/// `Acervo` is a caseless enum used purely as a namespace. All functionality
/// is provided through static properties and methods. For thread-safe
/// operations with per-model locking, see `AcervoManager`.
public enum Acervo {

  /// The current version of SwiftAcervo.
  public static let version = "0.15.1-dev"

  /// The name of the environment variable that gates outbound HTTP fetches.
  ///
  /// When this variable is set to `"1"` in the process environment, every
  /// SwiftAcervo code path that would otherwise contact the CDN refuses the
  /// fetch and throws ``AcervoError/offlineModeActive`` instead. Read paths
  /// that only touch the local filesystem (e.g. ``modelDirectory(for:)``,
  /// ``isModelAvailable(_:)``, hydrate-from-cache) are unaffected.
  static let offlineModeEnvironmentVariable = "ACERVO_OFFLINE"

  /// `true` when the `ACERVO_OFFLINE` environment variable is set to `"1"`.
  ///
  /// Evaluated on every read; tests can toggle the variable with
  /// `setenv` / `unsetenv` between cases. Other values (including the empty
  /// string, `"true"`, and `"yes"`) do **not** activate offline mode — only
  /// the literal string `"1"` does, matching the documented contract for
  /// downstream consumers.
  static var isOfflineModeActive: Bool {
    ProcessInfo.processInfo.environment[offlineModeEnvironmentVariable] == "1"
  }
}

// MARK: - Ensure Available

extension Acervo {

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
}

// MARK: - Component Downloads

extension Acervo {

  /// Downloads a registered component using the registry's file list and CDN manifest.
  ///
  /// The caller does not need to specify which files to download -- the registry
  /// knows. The CDN manifest provides SHA-256 checksums for per-file verification
  /// during download. Registry-level checksums are verified as an additional check.
  ///
  /// - Parameters:
  ///   - componentId: The ID of the registered component to download.
  ///   - force: When `true`, re-downloads files even if they already exist. Defaults to `false`.
  ///   - progress: A callback invoked periodically with download progress.
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  ///   `AcervoError.integrityCheckFailed` if a downloaded file fails checksum verification.
  public static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await downloadComponent(
      componentId,
      force: force,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Downloads a registered component using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    guard let initialDescriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    if initialDescriptor.needsHydration {
      try await hydrateComponent(componentId, telemetry: telemetry)
    }

    guard let descriptor = ComponentRegistry.shared.component(componentId),
      descriptor.isHydrated
    else {
      throw AcervoError.componentNotHydrated(id: componentId)
    }

    let fileList = descriptor.files.map(\.relativePath)

    // Manifest-driven download with CDN integrity verification
    try await download(
      descriptor.repoId,
      files: fileList,
      force: force,
      progress: progress,
      in: baseDirectory,
      telemetry: telemetry
    )

    // Additional registry-level checksum verification
    let componentDir = baseDirectory.appendingPathComponent(
      slugify(descriptor.repoId)
    )
    for file in descriptor.files {
      guard let expectedHash = file.sha256 else { continue }
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      let actualHash = try IntegrityVerification.sha256(of: fileURL)
      if actualHash != expectedHash {
        try? FileManager.default.removeItem(at: fileURL)
        if let telemetry {
          await telemetry.capture(
            .errorThrown(
              phase: .fileDownloadIntegrity,
              errorDescription:
                "Registry-level SHA mismatch for \(file.relativePath): expected \(expectedHash), got \(actualHash)",
              modelID: descriptor.repoId,
              fileName: file.relativePath
            )
          )
        }
        throw AcervoError.integrityCheckFailed(
          file: file.relativePath,
          expected: expectedHash,
          actual: actualHash
        )
      }
    }
  }

  /// Ensures a registered component is downloaded and ready.
  ///
  /// If the component is already fully downloaded and verified (via `isComponentReady`),
  /// this method returns immediately without performing any downloads. Otherwise,
  /// it downloads the component using the registry's file list.
  ///
  /// - Parameters:
  ///   - componentId: The ID of the registered component.
  ///   - progress: A callback invoked periodically with download progress.
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  public static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureComponentReady(
      componentId,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Ensures a registered component is downloaded and ready, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    // Check registration first
    guard let initialDescriptor = ComponentRegistry.shared.component(componentId) else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .other,
            errorDescription: "Component not registered: \(componentId)",
            modelID: nil,
            fileName: nil
          )
        )
      }
      throw AcervoError.componentNotRegistered(componentId)
    }

    let startTime = Date()
    if let telemetry {
      await telemetry.capture(
        .componentResolveStart(
          componentID: componentId,
          repoID: initialDescriptor.repoId
        )
      )
    }

    if initialDescriptor.needsHydration {
      try await hydrateComponent(componentId, telemetry: telemetry)
    }

    // If already ready, emit cacheHit-style completion and no-op
    if isComponentReady(componentId, in: baseDirectory) {
      if let telemetry {
        let descriptor = ComponentRegistry.shared.component(componentId) ?? initialDescriptor
        let totalBytes = descriptor.files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) }
        await telemetry.capture(
          .componentResolveComplete(
            componentID: componentId,
            repoID: descriptor.repoId,
            fileCount: descriptor.files.count,
            totalBytes: totalBytes,
            cacheState: .alreadyReady,
            durationSeconds: Date().timeIntervalSince(startTime)
          )
        )
      }
      return
    }

    // Download the component (descriptor is now hydrated; downloadComponent will not re-hydrate)
    try await downloadComponent(
      componentId,
      force: false,
      progress: progress,
      in: baseDirectory,
      telemetry: telemetry
    )

    if let telemetry {
      let descriptor = ComponentRegistry.shared.component(componentId) ?? initialDescriptor
      let totalBytes = descriptor.files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) }
      await telemetry.capture(
        .componentResolveComplete(
          componentID: componentId,
          repoID: descriptor.repoId,
          fileCount: descriptor.files.count,
          totalBytes: totalBytes,
          cacheState: .downloaded,
          durationSeconds: Date().timeIntervalSince(startTime)
        )
      )
    }
  }

  /// Ensures multiple registered components are downloaded and ready.
  ///
  /// Iterates through the component IDs and ensures each one is ready,
  /// downloading any that are missing. Components already cached are skipped.
  ///
  /// - Parameters:
  ///   - componentIds: The IDs of the registered components to ensure.
  ///   - progress: A callback invoked periodically with download progress.
  /// - Throws: `AcervoError.componentNotRegistered` if any ID is not in the registry.
  public static func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await ensureComponentsReady(
      componentIds,
      progress: progress,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Ensures multiple registered components are downloaded and ready,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func ensureComponentsReady(
    _ componentIds: [String],
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    for componentId in componentIds {
      try await ensureComponentReady(
        componentId,
        progress: progress,
        in: baseDirectory,
        telemetry: telemetry
      )
    }
  }
}

// MARK: - Component Deletion

extension Acervo {

  /// Deletes a downloaded component's files from disk.
  ///
  /// Does NOT unregister the component -- it remains in the registry as
  /// "not downloaded." If the component is registered but not downloaded,
  /// this is a no-op (nothing to delete).
  ///
  /// - Parameter componentId: The ID of the registered component to delete.
  /// - Throws: `AcervoError.componentNotRegistered` if the ID is not in the registry.
  public static func deleteComponent(_ componentId: String) throws {
    try deleteComponent(componentId, in: sharedModelsDirectory)
  }

  /// Deletes a downloaded component's files from disk, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  static func deleteComponent(_ componentId: String, in baseDirectory: URL) throws {
    guard let descriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    let componentDir = baseDirectory.appendingPathComponent(
      slugify(descriptor.repoId)
    )

    // If the directory doesn't exist, nothing to delete -- no-op
    guard FileManager.default.fileExists(atPath: componentDir.path) else {
      return
    }

    // R4: Remove only the files declared in this descriptor — never the entire
    // slug directory. Multiple components may share the same repoId (bundle shape),
    // each owning a distinct subset of files in the same slug directory. Removing
    // the whole directory would silently destroy sibling components' files.
    let fm = FileManager.default
    for file in descriptor.files {
      let fileURL = componentDir.appendingPathComponent(file.relativePath)
      // Use try? — a missing file (never downloaded, or already removed) is fine.
      try? fm.removeItem(at: fileURL)

      // Best-effort: prune the immediate parent directory if it is now empty,
      // walking up to (but not including) componentDir itself. This handles the
      // case where a file lives in a subfolder (e.g., "transformer/model.safetensors")
      // whose folder becomes empty after the last file in it is deleted.
      var parent = fileURL.deletingLastPathComponent()
      while parent.standardizedFileURL != componentDir.standardizedFileURL {
        guard let contents = try? fm.contentsOfDirectory(atPath: parent.path),
          contents.isEmpty
        else { break }
        try? fm.removeItem(at: parent)
        parent = parent.deletingLastPathComponent()
      }
    }

    // Remove the slug directory itself if it is now empty (all components deleted).
    if let contents = try? fm.contentsOfDirectory(atPath: componentDir.path),
      contents.isEmpty
    {
      try? fm.removeItem(at: componentDir)
    }
  }
}

// MARK: - Ensure Available (slug-keyed, multi-component)

extension Acervo {

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

    // State box: holds the current (availability, bytesTotal) pair for each
    // component index.
    final class ComponentStateBox: @unchecked Sendable {
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
