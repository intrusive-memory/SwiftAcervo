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
  public static let version = "0.19.0-dev"

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
