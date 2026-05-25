// Acervo+ComponentDownloads.swift
// SwiftAcervo
//
// Component download orchestration (§18) and component deletion (§19).
// Both operate on the same component-directory layout and delegate to
// AcervoDownloader.downloadComponent internally.
//
// Sections:
//
//   §18 — Component Downloads
//        downloadComponent(_:force:progress:telemetry:)                  public
//        downloadComponent(_:force:progress:in:telemetry:)               internal — test seam
//        ensureComponentReady(_:progress:telemetry:)                     public
//        ensureComponentReady(_:progress:in:telemetry:)                  internal — test seam
//        ensureComponentsReady(_:progress:telemetry:)                    public
//        ensureComponentsReady(_:progress:in:telemetry:)                 internal — test seam
//
//   §19 — Component Deletion
//        deleteComponent(_:)                                             public
//        deleteComponent(_:in:)                                          internal — test seam
//

import Foundation

extension Acervo {

  // MARK: - Downloads

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
  /// `session` is an internal test-injection seam (default `nil` uses
  /// `SecureDownloadSession.shared`). The public API does not surface it.
  static func downloadComponent(
    _ componentId: String,
    force: Bool = false,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    guard let initialDescriptor = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    if initialDescriptor.needsHydration {
      if let session {
        try await hydrateComponent(componentId, session: session, telemetry: telemetry)
      } else {
        try await hydrateComponent(componentId, telemetry: telemetry)
      }
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
      telemetry: telemetry,
      session: session
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
  ///
  /// ## In-flight registration
  ///
  /// When a download is actually performed (cache miss), this method registers
  /// the component's `repoId` with ``InFlightDownloads/shared`` for the
  /// duration of the underlying Task. This is what makes
  /// ``Acervo/availability(_:)`` return `.downloading(progress:)` for the same
  /// `repoId` while the download is running, and is the contract UI consumers
  /// rely on for progress display.
  ///
  /// Dedup is keyed by `repoId` (matching ``ensureAvailable(_:files:progress:telemetry:)``).
  /// Concurrent callers requesting the same component converge on a single
  /// underlying Task; the joiner's caller-supplied `progress` callback does
  /// not receive ticks (the originator's does), but UI consumers polling
  /// `availability(_:)` see the registered `.downloading` state regardless.
  static func ensureComponentReady(
    _ componentId: String,
    progress: (@Sendable (AcervoDownloadProgress) -> Void)? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
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
      if let session {
        try await hydrateComponent(componentId, session: session, telemetry: telemetry)
      } else {
        try await hydrateComponent(componentId, telemetry: telemetry)
      }
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

    // Resolve the hydrated descriptor — repoId is the dedup/in-flight key.
    guard let hydratedDescriptor = ComponentRegistry.shared.component(componentId),
      hydratedDescriptor.isHydrated
    else {
      throw AcervoError.componentNotHydrated(id: componentId)
    }
    let repoId = hydratedDescriptor.repoId

    // Build a progress wrapper that publishes each tick into the in-flight
    // registry so `Acervo.availability(repoId)` can surface the current
    // fraction as `.downloading(progress:)`. The caller's `progress` callback
    // still fires; the wrapper is a strict superset.
    let wrappedProgress: (@Sendable (AcervoDownloadProgress) -> Void) = { p in
      Task { await InFlightDownloads.shared.publishProgress(p.overallProgress, for: repoId) }
      progress?(p)
    }

    // Capture by-value so the @Sendable `start` closure can reference them.
    let capturedComponentId = componentId
    let capturedRepoId = repoId
    let capturedBase = baseDirectory
    let capturedTelemetry = telemetry
    let capturedSession = session

    // Track who originated the underlying Task (so we can label telemetry
    // and only fire the matched `inFlightDownloadCleared` from the originator).
    // The `start` closure runs while `InFlightDownloads` is actor-isolated, so
    // the write completes before `task(for:)` returns — no read/write race.
    let originatorFlag = OriginatorFlag()

    let sharedTask = await InFlightDownloads.shared.task(for: repoId) {
      originatorFlag.didOriginate = true
      return Task {
        var didFail = false
        defer {
          let outcome: AcervoTelemetryEvent.InFlightOutcome = didFail ? .failure : .success
          // `defer` is synchronous; `finish` and telemetry capture are async,
          // so we re-launch them in a Task. The Task captures `outcome` by
          // value (a `let` inside the defer scope).
          Task {
            await InFlightDownloads.shared.finish(capturedRepoId)
            await capturedTelemetry?.capture(
              .inFlightDownloadCleared(
                modelID: capturedRepoId,
                componentID: capturedComponentId,
                outcome: outcome
              )
            )
          }
        }
        do {
          try await downloadComponent(
            capturedComponentId,
            force: false,
            progress: wrappedProgress,
            in: capturedBase,
            telemetry: capturedTelemetry,
            session: capturedSession
          )
        } catch {
          didFail = true
          throw error
        }
      }
    }

    // Emit the registration event once `task(for:)` has resolved the role.
    if let telemetry {
      await telemetry.capture(
        .inFlightDownloadRegistered(
          modelID: repoId,
          componentID: componentId,
          role: originatorFlag.didOriginate ? .originator : .joiner
        )
      )
    }

    // Both originator and joiners await the same Task; both observe the
    // same success/throw outcome.
    try await sharedTask.value

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
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws {
    for componentId in componentIds {
      try await ensureComponentReady(
        componentId,
        progress: progress,
        in: baseDirectory,
        telemetry: telemetry,
        session: session
      )
    }
  }

  // MARK: - Deletion

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

// MARK: - OriginatorFlag (file-private)

/// One-shot Bool flag used by `ensureComponentReady` to learn whether the
/// caller actually originated the in-flight Task (vs. joined an existing one).
/// The `start` closure passed to ``InFlightDownloads/task(for:start:)`` runs
/// while the actor is isolated, so the write here completes before
/// `task(for:)` returns — readers in the calling task see a coherent value
/// without further synchronization.
private final class OriginatorFlag: @unchecked Sendable {
  var didOriginate = false
}
