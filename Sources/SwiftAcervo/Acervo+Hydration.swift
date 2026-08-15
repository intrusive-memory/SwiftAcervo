// Acervo+Hydration.swift
// SwiftAcervo
//
// Manifest-driven component hydration: fetches the CDN manifest for a
// registered component and rebuilds its descriptor with a populated file list.
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

  /// Fetches the CDN manifest for a registered component and rebuilds its
  /// descriptor with a populated file list.
  ///
  /// Concurrent calls for the same `componentId` coalesce into a single
  /// network fetch. A later call (after completion) re-fetches so that
  /// CDN manifest updates between app launches are picked up.
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
  /// stub the CDN via `MockURLProtocol`.
  static func hydrateComponent(
    _ componentId: String,
    session: URLSession,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    try await hydrationCoalescer.hydrate(componentId) {
      try await performHydration(componentId, session: session, telemetry: telemetry)
    }
  }

  /// Does the actual manifest fetch + descriptor rebuild + registry replace.
  /// Called from within the coalescer so only one runs per componentId at a time.
  private static func performHydration(
    _ componentId: String,
    session: URLSession,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws {
    guard let existing = ComponentRegistry.shared.component(componentId) else {
      throw AcervoError.componentNotRegistered(componentId)
    }

    let manifest = try await AcervoDownloader.downloadManifest(
      for: existing.repoId,
      session: session,
      telemetry: telemetry
    )

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
