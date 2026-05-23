// Acervo+ComponentRegistration.swift
// SwiftAcervo
//
// API surface for "tell Acervo about a component"; delegates to ComponentRegistry actor.

import Foundation

extension Acervo {

  /// Registers a component descriptor with the global registry.
  ///
  /// Idempotent: re-registering the same ID updates the entry, applying
  /// deduplication rules per REQUIREMENTS A1.2. If the same `id` is registered
  /// with a different `repoId` or `files`, a warning is logged and
  /// the last registration wins. Metadata dictionaries are merged (newer keys
  /// overwrite on conflict). `estimatedSizeBytes` and `minimumMemoryBytes`
  /// take the max of both values.
  ///
  /// Thread-safe: may be called from any thread or task.
  ///
  /// - Parameter descriptor: The component descriptor to register.
  ///
  /// ```swift
  /// Acervo.register(ComponentDescriptor(
  ///     id: "t5-xxl-encoder-int4",
  ///     type: .encoder,
  ///     displayName: "T5-XXL Text Encoder (int4)",
  ///     repoId: "intrusive-memory/t5-xxl-int4-mlx",
  ///     files: [ComponentFile(relativePath: "model.safetensors")],
  ///     estimatedSizeBytes: 1_200_000_000,
  ///     minimumMemoryBytes: 2_400_000_000
  /// ))
  /// ```
  public static func register(_ descriptor: ComponentDescriptor) {
    ComponentRegistry.shared.register(descriptor)
  }

  /// Registers multiple component descriptors at once.
  ///
  /// Each descriptor is registered individually, applying the same
  /// deduplication rules as `register(_:)`.
  ///
  /// - Parameter descriptors: The component descriptors to register.
  public static func register(_ descriptors: [ComponentDescriptor]) {
    ComponentRegistry.shared.register(descriptors)
  }

  /// Removes a component registration by its ID.
  ///
  /// This does NOT delete downloaded files from disk. The component
  /// simply stops appearing in catalog queries. If the ID is not
  /// registered, this is a no-op.
  ///
  /// - Parameter componentId: The ID of the component to unregister.
  public static func unregister(_ componentId: String) {
    ComponentRegistry.shared.unregister(componentId)
  }
}
