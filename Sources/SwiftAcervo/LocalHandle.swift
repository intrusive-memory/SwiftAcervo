// LocalHandle.swift
// SwiftAcervo
//
// Opaque handle providing scoped, path-agnostic file access to a
// caller-supplied local URL that is not registered in the component registry.
// Consumers get handles via `AcervoManager.withLocalAccess` and use them to
// resolve file URLs without constructing or storing filesystem paths directly.

import Foundation

/// An opaque handle providing scoped access to a caller-supplied local file or directory.
///
/// `LocalHandle` resolves file URLs relative to a root URL provided by the caller.
/// It is the counterpart to `ComponentHandle` for unregistered local paths — e.g.,
/// user-supplied LoRA adapters or weight files that Acervo did not download.
///
/// Handles are created internally by `AcervoManager.withLocalAccess` and are valid
/// only for the duration of the enclosing closure scope. Do not cache handles or
/// their URLs beyond the closure.
///
/// ```swift
/// let weights = try await AcervoManager.shared.withLocalAccess(loraURL) { handle in
///     let url = try handle.url(matching: ".safetensors")
///     return try loadSafetensors(from: url)
/// }
/// ```
public struct LocalHandle: Sendable {

  /// The resolved root URL (file or directory) provided by the caller.
  public let rootURL: URL

  private let isDirectory: Bool

  init(rootURL: URL) {
    self.rootURL = rootURL
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir)
    self.isDirectory = isDir.boolValue
  }

  /// Resolves a file by relative path from the root URL.
  ///
  /// If `relativePath` is empty or `"."` and `rootURL` points to a single file,
  /// returns `rootURL` itself.
  ///
  /// - Parameter relativePath: Path relative to `rootURL`.
  /// - Returns: The resolved filesystem URL.
  /// - Throws: `AcervoError.localPathNotFound` if the resolved path does not exist.
  public func url(for relativePath: String) throws -> URL {
    let resolved: URL
    if !isDirectory && (relativePath.isEmpty || relativePath == ".") {
      resolved = rootURL
    } else {
      resolved = rootURL.appendingPathComponent(relativePath)
    }
    guard FileManager.default.fileExists(atPath: resolved.path) else {
      throw AcervoError.localPathNotFound(url: resolved)
    }
    return resolved
  }

  /// Resolves the first file under `rootURL` whose path ends with `suffix`.
  ///
  /// Searches non-recursively in the root directory. If `rootURL` is a single
  /// file, checks whether that file's path ends with `suffix`.
  ///
  /// - Parameter suffix: Suffix to match (e.g., `".safetensors"`).
  /// - Returns: The first matching filesystem URL.
  /// - Throws: `AcervoError.localPathNotFound` if no match is found.
  public func url(matching suffix: String) throws -> URL {
    let matches = try urls(matching: suffix)
    guard let first = matches.first else {
      throw AcervoError.localPathNotFound(url: rootURL.appendingPathComponent("*\(suffix)"))
    }
    return first
  }

  /// Lists all files under `rootURL` (non-recursive) whose paths end with `suffix`.
  ///
  /// If `rootURL` is a single file, returns that file if its path ends with `suffix`.
  ///
  /// - Parameter suffix: Suffix to match (e.g., `".safetensors"`).
  /// - Returns: All matching filesystem URLs (may be empty).
  /// - Throws: `AcervoError.localPathNotFound` if `rootURL` itself no longer exists.
  public func urls(matching suffix: String) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: rootURL.path) else {
      throw AcervoError.localPathNotFound(url: rootURL)
    }

    if !isDirectory {
      return rootURL.path.hasSuffix(suffix) ? [rootURL] : []
    }

    let contents = (try? FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: nil,
      options: .skipsHiddenFiles
    )) ?? []

    return contents.filter { $0.path.hasSuffix(suffix) }.sorted { $0.path < $1.path }
  }
}
