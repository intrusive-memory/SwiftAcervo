// Acervo+ComponentCatalog.swift
// SwiftAcervo
//
// Read-side catalog queries: enumerate, look up, and introspect registered
// component descriptors and their download status. Depends on
// Acervo+ComponentRegistration.swift (registration facade) and the
// ComponentRegistry actor for storage.

import Foundation

extension Acervo {

  /// Returns all registered component descriptors (whether downloaded or not).
  ///
  /// This is the "what exists in the world?" API. A UI can use this to
  /// show all known components regardless of download status.
  ///
  /// - Returns: An array of all registered descriptors, in no particular order.
  public static func registeredComponents() -> [ComponentDescriptor] {
    ComponentRegistry.shared.allComponents()
  }

  /// Returns all registered components of the specified type.
  ///
  /// - Parameter type: The component type to filter by (e.g., `.encoder`, `.backbone`).
  /// - Returns: An array of matching descriptors.
  public static func registeredComponents(ofType type: ComponentType) -> [ComponentDescriptor] {
    ComponentRegistry.shared.components(ofType: type)
  }

  /// Looks up a specific component by its ID.
  ///
  /// - Parameter id: The component ID to look up (e.g., "t5-xxl-encoder-int4").
  /// - Returns: The matching `ComponentDescriptor`, or `nil` if not registered.
  public static func component(_ id: String) -> ComponentDescriptor? {
    ComponentRegistry.shared.component(id)
  }

  /// Checks if a registered component is fully downloaded and available on disk.
  ///
  /// For each file in the component's descriptor:
  /// - Verifies the file exists at the expected path
  /// - If `expectedSizeBytes` is declared, verifies the actual file size matches
  ///
  /// Returns `false` if the component is not registered or any file is missing/wrong size.
  ///
  /// - Parameter id: The component ID to check.
  /// - Returns: `true` if all declared files are present with correct sizes.
  public static func isComponentReady(_ id: String) -> Bool {
    isComponentReady(id, in: sharedModelsDirectory)
  }

  /// Checks if a registered component is fully downloaded, using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories
  /// without touching the real `sharedModelsDirectory`.
  ///
  /// - Parameters:
  ///   - id: The component ID to check.
  ///   - baseDirectory: The base directory to resolve component paths against.
  /// - Returns: `true` if all declared files are present with correct sizes.
  static func isComponentReady(_ id: String, in baseDirectory: URL) -> Bool {
    guard let descriptor = ComponentRegistry.shared.component(id) else {
      return false
    }

    // Un-hydrated descriptors have no file list; return false (safe default — not ready, ask for it).
    guard descriptor.isHydrated else {
      return false
    }

    let fm = FileManager.default
    let componentDir = baseDirectory.appendingPathComponent(slugify(descriptor.repoId))

    for file in descriptor.files {
      let filePath = componentDir.appendingPathComponent(file.relativePath).path
      guard fm.fileExists(atPath: filePath) else {
        return false
      }

      // If expected size is declared, verify it matches
      if let expectedSize = file.expectedSizeBytes {
        guard let attrs = try? fm.attributesOfItem(atPath: filePath),
          let actualSize = attrs[.size] as? Int64,
          actualSize == expectedSize
        else {
          return false
        }
      }
    }

    return true
  }

  /// Async variant of `isComponentReady` that auto-hydrates un-hydrated descriptors before checking.
  ///
  /// - Throws: `AcervoError.componentNotRegistered` if `id` is not in the registry.
  public static func isComponentReadyAsync(_ id: String) async throws -> Bool {
    try await isComponentReadyAsync(id, in: sharedModelsDirectory)
  }

  /// Internal overload of `isComponentReadyAsync` for testing with custom base directories.
  static func isComponentReadyAsync(_ id: String, in baseDirectory: URL) async throws -> Bool {
    guard let descriptor = ComponentRegistry.shared.component(id) else {
      throw AcervoError.componentNotRegistered(id)
    }
    if descriptor.needsHydration {
      try await hydrateComponent(id)
    }
    return isComponentReady(id, in: baseDirectory)
  }

  /// Returns all registered components that are not yet downloaded.
  ///
  /// Filters `registeredComponents()` to those where `isComponentReady` is `false`.
  ///
  /// Un-hydrated components are excluded from this result; their size is unknown until `hydrateComponent` is called. Use `unhydratedComponents()` to enumerate them.
  ///
  /// - Returns: An array of component descriptors for components awaiting download.
  public static func pendingComponents() -> [ComponentDescriptor] {
    pendingComponents(in: sharedModelsDirectory)
  }

  /// Returns all registered components that are not yet downloaded,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameter baseDirectory: The base directory to resolve component paths against.
  /// - Returns: An array of component descriptors for components awaiting download.
  static func pendingComponents(in baseDirectory: URL) -> [ComponentDescriptor] {
    registeredComponents().filter { $0.isHydrated && !isComponentReady($0.id, in: baseDirectory) }
  }

  /// Returns the total catalog size split between downloaded and pending components.
  ///
  /// Sums `estimatedSizeBytes` for ready components (downloaded) and
  /// not-ready components (pending). This allows a UI to display something
  /// like "3 of 7 components downloaded, 4.2 GB cached, 8.1 GB available."
  ///
  /// Un-hydrated components are excluded from this result; their size is unknown until `hydrateComponent` is called. Use `unhydratedComponents()` to enumerate them.
  ///
  /// - Returns: A tuple of `(downloaded: Int64, pending: Int64)` byte counts.
  public static func totalCatalogSize() -> (downloaded: Int64, pending: Int64) {
    totalCatalogSize(in: sharedModelsDirectory)
  }

  /// Returns the total catalog size split between downloaded and pending components,
  /// using a custom base directory.
  ///
  /// This internal overload enables testing with temporary directories.
  ///
  /// - Parameter baseDirectory: The base directory to resolve component paths against.
  /// - Returns: A tuple of `(downloaded: Int64, pending: Int64)` byte counts.
  static func totalCatalogSize(in baseDirectory: URL) -> (downloaded: Int64, pending: Int64) {
    var downloaded: Int64 = 0
    var pending: Int64 = 0

    for descriptor in registeredComponents() where descriptor.isHydrated {
      if isComponentReady(descriptor.id, in: baseDirectory) {
        downloaded += descriptor.estimatedSizeBytes
      } else {
        pending += descriptor.estimatedSizeBytes
      }
    }

    return (downloaded: downloaded, pending: pending)
  }

  /// Returns the IDs of all registered components that are awaiting hydration.
  ///
  /// - Returns: An array of component IDs for components whose file list has not yet been populated.
  public static func unhydratedComponents() -> [String] {
    registeredComponents().filter(\.needsHydration).map(\.id)
  }
}
