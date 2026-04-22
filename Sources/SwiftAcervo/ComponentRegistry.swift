// ComponentRegistry.swift
// SwiftAcervo
//
// Internal thread-safe in-memory registry for component descriptors.
// This is the backing store for all registry operations. Not publicly
// exposed -- only Acervo static methods touch it.

import Foundation

/// Thread-safe in-memory registry of component descriptors.
///
/// `ComponentRegistry` is the single source of truth for which components
/// have been declared by model plugins. It uses `NSLock` for synchronization,
/// allowing safe concurrent access from any thread or task.
///
/// This class is internal to SwiftAcervo. External consumers interact with
/// the registry through `Acervo` static methods (`register`, `unregister`,
/// `registeredComponents`, etc.).
final class ComponentRegistry: @unchecked Sendable {

  /// The shared singleton instance used by all Acervo static methods.
  static let shared = ComponentRegistry()

  /// Storage keyed by component ID.
  private var descriptors: [String: ComponentDescriptor] = [:]

  /// Lock protecting all reads and writes to `descriptors`.
  private let lock = NSLock()

  /// Creates an empty registry. Use `shared` for the singleton instance.
  init() {}

  // MARK: - Registration

  /// Registers a component descriptor, applying deduplication rules.
  ///
  /// Deduplication behavior (per REQUIREMENTS A1.2):
  /// - Same `id`, same `repoId` and `files`: silent overwrite.
  /// - Same `id`, different `repoId` or `files`: warning logged, last registration wins.
  /// - `metadata` dictionaries are merged (newer keys overwrite on conflict).
  /// - `estimatedSizeBytes` and `minimumMemoryBytes` take the max of both values.
  ///
  /// - Parameter descriptor: The component descriptor to register.
  func register(_ descriptor: ComponentDescriptor) {
    lock.lock()
    defer { lock.unlock() }

    if let existing = descriptors[descriptor.id] {
      // Check if this is a conflict (different repo or files)
      let sameRepo = existing.repoId == descriptor.repoId
      let sameFiles = existing.files == descriptor.files
      if !sameRepo || !sameFiles {
        // Log warning to stderr for conflicting registrations
        let message =
          "[SwiftAcervo] Warning: re-registering component '\(descriptor.id)' with different repoId or files. Last registration wins."
        FileHandle.standardError.write(Data((message + "\n").utf8))
      }

      // Merge metadata: existing + new (new keys overwrite on conflict)
      var mergedMetadata = existing.metadata
      for (key, value) in descriptor.metadata {
        mergedMetadata[key] = value
      }

      // Take max of size estimates
      let mergedEstimatedSize = max(existing.estimatedSizeBytes, descriptor.estimatedSizeBytes)
      let mergedMinimumMemory = max(existing.minimumMemoryBytes, descriptor.minimumMemoryBytes)

      // Create merged descriptor (new values win for non-merged fields)
      let merged = ComponentDescriptor(
        id: descriptor.id,
        type: descriptor.type,
        displayName: descriptor.displayName,
        repoId: descriptor.repoId,
        files: descriptor.files,
        estimatedSizeBytes: mergedEstimatedSize,
        minimumMemoryBytes: mergedMinimumMemory,
        metadata: mergedMetadata
      )
      descriptors[descriptor.id] = merged
    } else {
      descriptors[descriptor.id] = descriptor
    }
  }

  /// Registers multiple component descriptors at once.
  ///
  /// Each descriptor is registered individually, applying the same
  /// deduplication rules as `register(_:)`.
  ///
  /// - Parameter descriptors: The component descriptors to register.
  func register(_ descriptors: [ComponentDescriptor]) {
    for descriptor in descriptors {
      register(descriptor)
    }
  }

  /// Overwrites the stored descriptor for `descriptor.id` with no merging.
  ///
  /// Unlike `register(_:)`, this method replaces every field wholesale.
  /// Used by hydration where the CDN manifest is authoritative and merge
  /// semantics would silently mask drift.
  func replace(_ descriptor: ComponentDescriptor) {
    lock.lock()
    defer { lock.unlock() }
    descriptors[descriptor.id] = descriptor
  }

  // MARK: - Unregistration

  /// Removes a component from the registry by its ID.
  ///
  /// This does NOT delete downloaded files from disk. The component
  /// simply stops appearing in catalog queries.
  ///
  /// - Parameter componentId: The ID of the component to unregister.
  func unregister(_ componentId: String) {
    lock.lock()
    defer { lock.unlock() }
    descriptors.removeValue(forKey: componentId)
  }

  // MARK: - Queries

  /// Returns the descriptor for a specific component, or `nil` if not registered.
  ///
  /// - Parameter id: The component ID to look up.
  /// - Returns: The matching `ComponentDescriptor`, or `nil`.
  func component(_ id: String) -> ComponentDescriptor? {
    lock.lock()
    defer { lock.unlock() }
    return descriptors[id]
  }

  /// Returns all registered component descriptors.
  ///
  /// - Returns: An array of all registered descriptors, in no particular order.
  func allComponents() -> [ComponentDescriptor] {
    lock.lock()
    defer { lock.unlock() }
    return Array(descriptors.values)
  }

  /// Returns all registered components of the specified type.
  ///
  /// - Parameter type: The component type to filter by.
  /// - Returns: An array of matching descriptors.
  func components(ofType type: ComponentType) -> [ComponentDescriptor] {
    lock.lock()
    defer { lock.unlock() }
    return descriptors.values.filter { $0.type == type }
  }

  // MARK: - Testing Support

  /// Removes all registered components. Intended for use in tests.
  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    descriptors.removeAll()
  }
}
