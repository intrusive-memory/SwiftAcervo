// Acervo+Hydration.swift
// SwiftAcervo
//
// Manifest-driven component hydration: resolves the manifest for a
// registered component (local persisted copy first, CDN on miss) and
// rebuilds its descriptor with a populated file list.
//
// Contains the public `Acervo.hydrateComponent` API and the companion
// `HydrationCoalescer` actor — following the ValidityOracle.swift template
// of concern + single-use helper type in one file.

import Foundation

/// Coalesces concurrent hydration requests for the same component ID into a
/// single in-flight `Task`. All subsequent callers await the same work until
/// it completes; the slot is cleared on completion so a later call re-fetches.
internal actor HydrationCoalescer {
  private var inflight: [String: Task<Void, Error>] = [:]

  func hydrate(
    _ id: String,
    fetch: @Sendable @escaping () async throws -> Void
  ) async throws {
    if let existing = inflight[id] {
      try await existing.value
      return
    }
    let task = Task { try await fetch() }
    inflight[id] = task
    defer { inflight[id] = nil }
    try await task.value
  }
}

extension Acervo {

  /// Shared coalescer; single-flight key is componentId.
  private static let hydrationCoalescer = HydrationCoalescer()

  /// Resolves the manifest for a registered component and rebuilds its
  /// descriptor with a populated file list.
  ///
  /// **Local-first:** a completed download persists the byte-equal CDN
  /// manifest at `<modelDir>/manifest.json`. When that authoritative local
  /// copy exists, hydration reads it and performs no network I/O — the CDN
  /// is only contacted for a component whose model has never finished
  /// downloading on this device. To force a re-fetch of an updated CDN
  /// manifest, delete the local model first (or use the CLI's re-download
  /// path).
  ///
  /// Concurrent calls for the same `componentId` coalesce into a single
  /// resolution.
  ///
  /// - Parameter componentId: The ID of a component registered with Acervo.
  /// - Throws: `AcervoError.componentNotRegistered` if `componentId` is
  ///   unknown; any manifest-related error from `fetchManifest`.
  public static func hydrateComponent(
    _ componentId: String,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await hydrateComponent(
      componentId,
      session: SecureDownloadSession.shared,
      telemetry: telemetry
    )
  }

  /// Internal overload that accepts an injected `URLSession` so tests can
  /// stub the CDN via `MockURLProtocol`, and an optional `baseDirectory`
  /// against which the local-manifest fast path is resolved (defaults to
  /// the shared models directory when `nil`).
  static func hydrateComponent(
    _ componentId: String,
    session: URLSession,
    in baseDirectory: URL? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await hydrationCoalescer.hydrate(componentId) {
      try await performHydration(
        componentId, session: session, in: baseDirectory, telemetry: telemetry)
    }
  }

  /// Does the actual manifest resolution + descriptor rebuild + registry
  /// replace. Called from within the coalescer so only one runs per
  /// componentId at a time.
  private static func performHydration(
    _ componentId: String,
    session: URLSession,
    in baseDirectory: URL? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    guard let existing = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    // Local-first: hydrate from the persisted on-disk manifest when one
    // exists, so a device with a complete local copy never touches the CDN
    // (and keeps working when the CDN is unreachable). `resolvedShared…` is
    // the non-trapping resolver — an unconfigured storage location simply
    // skips the fast path.
    let manifest: CDNManifest
    if let base = baseDirectory ?? resolvedSharedModelsDirectory,
      let local = ValidityOracle.loadLocalManifestEitherShape(
        modelId: existing.repoId,
        modelDir: base.appendingPathComponent(slugify(existing.repoId)),
        baseDirectory: base
      )
    {
      manifest = local
    } else {
      manifest = try await AcervoDownloader.downloadManifest(
        for: existing.repoId,
        session: session,
        telemetry: telemetry
      )
    }

    // Drift warning: compare pre-existing declared file count against manifest.
    if existing.isHydrated && existing.files.count != manifest.files.count {
      let message =
        "[SwiftAcervo] Manifest drift detected for \(componentId): declared \(existing.files.count) files, manifest has \(manifest.files.count) files. Using manifest."
      FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // NOTE: Hydration replaces `files` with the full manifest. Bundle descriptors
    // (multiple components sharing one repoId, each owning a file subset) MUST be
    // registered pre-hydrated using the explicit `files:` initializer; calling
    // hydrateComponent on a bundle descriptor will overwrite the declared file
    // subset with the full manifest, breaking per-component file scope (R1).
    // See ComponentDescriptor.init(id:type:displayName:repoId:files:...) for details.
    let hydratedFiles = manifest.files.map { entry in
      ComponentFile(
        relativePath: entry.path,
        expectedSizeBytes: entry.sizeBytes,
        sha256: entry.sha256
      )
    }
    let totalSize = hydratedFiles.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) }

    let hydrated = ComponentDescriptor(
      id: existing.id,
      type: existing.type,
      displayName: existing.displayName,
      repoId: existing.repoId,
      files: hydratedFiles,
      estimatedSizeBytes: totalSize,
      minimumMemoryBytes: existing.minimumMemoryBytes,
      metadata: existing.metadata
    )

    ComponentRegistry.shared.replace(hydrated)
  }
}
