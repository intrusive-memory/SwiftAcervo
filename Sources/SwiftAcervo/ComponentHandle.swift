// ComponentHandle.swift
// SwiftAcervo
//
// Opaque handle providing scoped, path-agnostic file access to a
// downloaded component's files. Consumers get handles via
// `AcervoManager.withComponentAccess` and use them to resolve file
// URLs without ever constructing or storing filesystem paths directly.

import Foundation

/// An opaque handle providing scoped access to a downloaded component's files.
///
/// `ComponentHandle` resolves file URLs relative to the component's storage
/// directory. It is the primary abstraction for path-agnostic model access:
/// consumers request files by relative path or suffix pattern without knowing
/// where on disk the component is stored.
///
/// Handles are created internally by `AcervoManager.withComponentAccess`
/// and are valid only for the duration of the enclosing closure scope.
/// Do not cache or store handles or their URLs beyond the closure.
///
/// ```swift
/// let weights = try await AcervoManager.shared.withComponentAccess("t5-xxl-encoder-int4") { handle in
///     let url = try handle.url(matching: ".safetensors")
///     return try Data(contentsOf: url)
/// }
/// ```
public struct ComponentHandle: Sendable {

  /// The component this handle provides access to.
  public let descriptor: ComponentDescriptor

  /// The resolved base directory for this component on disk.
  let baseDirectory: URL

  /// Creates a handle for the given component and base directory.
  ///
  /// This initializer is internal: consumers never construct handles directly.
  /// They receive handles through `AcervoManager.withComponentAccess`.
  ///
  /// - Parameters:
  ///   - descriptor: The component descriptor.
  ///   - baseDirectory: The filesystem directory containing the component's files.
  init(descriptor: ComponentDescriptor, baseDirectory: URL) {
    self.descriptor = descriptor
    self.baseDirectory = baseDirectory
  }

  /// Resolves a file within the component by its relative path.
  ///
  /// The relative path must match one of the `ComponentFile.relativePath`
  /// entries in the descriptor, and the file must exist on disk.
  ///
  /// - Parameter relativePath: The file's path relative to the component root
  ///   (e.g., "model.safetensors" or "speech_tokenizer/config.json").
  /// - Returns: The resolved filesystem URL for the file.
  /// - Throws: `AcervoError.componentFileNotFound` if the file does not exist on disk.
  public func url(for relativePath: String) throws -> URL {
    let fileURL = baseDirectory.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw AcervoError.componentFileNotFound(
        component: descriptor.id,
        file: relativePath
      )
    }
    return fileURL
  }

  /// Resolves the first file in the descriptor whose relative path ends with the given suffix.
  ///
  /// Useful for finding files by extension without knowing the exact name
  /// (e.g., `.safetensors`, `.json`).
  ///
  /// - Parameter suffix: The suffix to match against `ComponentFile.relativePath`
  ///   (e.g., ".safetensors").
  /// - Returns: The resolved filesystem URL for the first matching file.
  /// - Throws: `AcervoError.componentFileNotFound` if no file matches the suffix
  ///   or if the matching file does not exist on disk.
  public func url(matching suffix: String) throws -> URL {
    guard let file = descriptor.files.first(where: { $0.relativePath.hasSuffix(suffix) }) else {
      throw AcervoError.componentFileNotFound(
        component: descriptor.id,
        file: "*\(suffix)"
      )
    }
    return try url(for: file.relativePath)
  }

  /// Resolves all files in the descriptor whose relative paths end with the given suffix.
  ///
  /// Useful for loading sharded weights where multiple files share the same
  /// extension (e.g., "model-00001-of-00003.safetensors").
  ///
  /// - Parameter suffix: The suffix to match against `ComponentFile.relativePath`
  ///   (e.g., ".safetensors").
  /// - Returns: An array of resolved filesystem URLs for all matching files.
  /// - Throws: `AcervoError.componentFileNotFound` if no files match the suffix.
  ///   Also throws if any matching file does not exist on disk.
  public func urls(matching suffix: String) throws -> [URL] {
    let matchingFiles = descriptor.files.filter { $0.relativePath.hasSuffix(suffix) }
    guard !matchingFiles.isEmpty else {
      throw AcervoError.componentFileNotFound(
        component: descriptor.id,
        file: "*\(suffix)"
      )
    }
    return try matchingFiles.map { try url(for: $0.relativePath) }
  }

  /// Lists all files from the descriptor that actually exist on disk.
  ///
  /// Returns the relative paths (matching `ComponentFile.relativePath`)
  /// for files that are present in the component's directory. Files
  /// declared in the descriptor but missing from disk are excluded.
  ///
  /// - Returns: An array of relative path strings for files present on disk.
  public func availableFiles() -> [String] {
    let fm = FileManager.default
    return descriptor.files
      .map(\.relativePath)
      .filter { relativePath in
        let fileURL = baseDirectory.appendingPathComponent(relativePath)
        return fm.fileExists(atPath: fileURL.path)
      }
  }
}
