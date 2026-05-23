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
