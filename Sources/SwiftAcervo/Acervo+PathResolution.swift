// Acervo+PathResolution.swift
// SwiftAcervo
//
// App Group resolution, shared-models directory, slugify, and model-directory helpers.
// All path concerns are consolidated here: callers always reach these via `Acervo.<symbol>`.
// `AcervoManager` and every `Acervo+*.swift` sibling depend on this file as a leaf.

import Foundation
import Security

extension Acervo {

  /// Environment variable that supplies the App Group identifier to consumers
  /// without an entitlements file (CLI tools, scripts, test runners).
  ///
  /// Set in `~/.zprofile` for interactive shells:
  /// ```sh
  /// export ACERVO_APP_GROUP_ID=group.intrusive-memory.models
  /// ```
  ///
  /// macOS UI apps may instead declare the App Group in
  /// `com.apple.security.application-groups` inside their `.entitlements`
  /// file; SwiftAcervo reads it at runtime via `SecTaskCopyValueForEntitlement`.
  /// On iOS, `SecTaskCopyValueForEntitlement` is not part of the public SDK,
  /// so iOS consumers must supply the identifier via this environment
  /// variable (e.g. set in `main` before any SwiftAcervo call).
  ///
  /// Resolution order in ``sharedModelsDirectory``:
  /// 1. `ACERVO_APP_GROUP_ID` environment variable
  /// 2. First entry of `com.apple.security.application-groups` entitlement
  ///    (macOS only)
  /// 3. `fatalError` — no silent fallback
  public static let appGroupEnvironmentVariable = "ACERVO_APP_GROUP_ID"

  /// The subdirectory name within the App Group container for model storage.
  private static let modelsSubdirectory = "SharedModels"

  /// Resolves the App Group identifier for the current process.
  ///
  /// Reads ``appGroupEnvironmentVariable`` first, then on macOS falls back to
  /// the running binary's `com.apple.security.application-groups` entitlement.
  /// Returns `nil` if neither source supplies a value — callers that need a
  /// path treat this as a configuration error.
  static var resolvedAppGroupIdentifier: String? {
    if let envValue = ProcessInfo.processInfo.environment[appGroupEnvironmentVariable],
      !envValue.isEmpty
    {
      return envValue
    }
    #if os(macOS)
      return readApplicationGroupFromEntitlements()
    #else
      return nil
    #endif
  }

  #if os(macOS)
    /// Reads the first entry of `com.apple.security.application-groups` from
    /// the running binary's entitlements via the Security framework.
    ///
    /// Returns `nil` for binaries without entitlements (unsigned CLI tools,
    /// test runners) or whose entitlements lack the application-groups key.
    ///
    /// macOS only: `SecTaskCreateFromSelf` and `SecTaskCopyValueForEntitlement`
    /// are not part of the public iOS SDK. iOS consumers must supply the
    /// group identifier through ``appGroupEnvironmentVariable``.
    private static func readApplicationGroupFromEntitlements() -> String? {
      guard let task = SecTaskCreateFromSelf(nil) else { return nil }
      let key = "com.apple.security.application-groups" as CFString
      guard let value = SecTaskCopyValueForEntitlement(task, key, nil) else {
        return nil
      }
      if let array = value as? [String], let first = array.first, !first.isEmpty {
        return first
      }
      return nil
    }
  #endif

  /// Marks a URL as excluded from iCloud backup.
  ///
  /// Apple requires that large re-downloadable content (such as ML model
  /// weights) must not be backed up to iCloud. This method sets the
  /// `isExcludedFromBackup` resource value on the given URL.
  ///
  /// - Parameter url: A file or directory URL to exclude from backup.
  static func excludeFromBackup(_ url: URL) {
    var mutableURL = url
    try? mutableURL.setResourceValues(
      {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        return values
      }())
  }

  /// The canonical base directory for all shared AI models.
  ///
  /// Same path for every consumer — UI app, CLI, test runner — once the App
  /// Group identifier is configured (see ``appGroupEnvironmentVariable``).
  ///
  /// - **iOS**: resolves via `containerURL(forSecurityApplicationGroupIdentifier:)`.
  ///   The entitlement must be granted; the group ID itself must be supplied
  ///   via ``appGroupEnvironmentVariable`` because iOS does not expose
  ///   `SecTaskCopyValueForEntitlement` publicly.
  /// - **macOS (sandboxed UI app)**: resolves via
  ///   `containerURL(forSecurityApplicationGroupIdentifier:)`. The App Sandbox
  ///   grants write access only to the team-prefixed directory
  ///   (`<TeamID>.<group-id>`), and that's exactly the URL this API returns.
  /// - **macOS (unsandboxed CLI / test runner)**: `containerURL(...)` returns
  ///   `nil` for unsandboxed processes, so we fall back to
  ///   `~/Library/Group Containers/<group-id>/SharedModels/`. CLI tools can
  ///   read/write this directory by virtue of file-system permissions.
  ///
  /// All model directories are stored as direct children of this path, named
  /// using the slugified model ID.
  ///
  /// - Important: Calls `fatalError` when no App Group identifier is
  ///   configured. CLIs must export ``appGroupEnvironmentVariable`` (typically
  ///   in `~/.zprofile`); UI apps must declare the group in their
  ///   `.entitlements` file. Acervo refuses to invent a per-process fallback
  ///   path because that is exactly the divergence the App Group container
  ///   exists to prevent.
  public static var sharedModelsDirectory: URL {
    guard let groupID = resolvedAppGroupIdentifier else {
      fatalError(
        """
        SwiftAcervo: no App Group identifier configured.

        UI apps (macOS / iOS): declare `com.apple.security.application-groups` \
        in your .entitlements file.

        CLI tools / scripts / test runners: export ACERVO_APP_GROUP_ID in \
        your shell environment (typically ~/.zprofile):

            export ACERVO_APP_GROUP_ID=group.intrusive-memory.models

        See SwiftAcervo's README and AGENTS.md for details.
        """
      )
    }
    #if os(iOS)
      guard
        let groupURL = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: groupID
        )
      else {
        fatalError(
          "SwiftAcervo: App Group '\(groupID)' is not granted to this iOS process. "
            + "Add it to com.apple.security.application-groups in the app's entitlements."
        )
      }
      return groupURL.appendingPathComponent(modelsSubdirectory)
    #else
      if let groupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: groupID
      ) {
        return groupURL.appendingPathComponent(modelsSubdirectory)
      }
      return
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers")
        .appendingPathComponent(groupID)
        .appendingPathComponent(modelsSubdirectory)
    #endif
  }

  /// Converts a model ID to a filesystem-safe directory name.
  ///
  /// Replaces all "/" characters with "_". This is the canonical transformation
  /// used to derive directory names from model identifiers.
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  /// - Returns: The slugified form (e.g., "mlx-community_Qwen2.5-7B-Instruct-4bit").
  ///   Returns an empty string if the input is empty.
  ///
  /// ```swift
  /// let slug = Acervo.slugify("mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// // "mlx-community_Qwen2.5-7B-Instruct-4bit"
  /// ```
  public static func slugify(_ modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }

  /// Returns the local filesystem directory for a given model ID.
  ///
  /// The model ID must contain exactly one "/" separating the organization
  /// from the repository name (e.g., "mlx-community/Qwen2.5-7B-Instruct-4bit").
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format.
  /// - Returns: The URL of the model directory within `sharedModelsDirectory`.
  /// - Throws: `AcervoError.invalidModelId` if the model ID does not contain
  ///   exactly one "/".
  ///
  /// ```swift
  /// let dir = try Acervo.modelDirectory(for: "mlx-community/Qwen2.5-7B-Instruct-4bit")
  /// // <sharedModelsDirectory>/mlx-community_Qwen2.5-7B-Instruct-4bit/
  /// ```
  public static func modelDirectory(for modelId: String) throws -> URL {
    let slashCount = modelId.filter { $0 == "/" }.count
    guard slashCount == 1 else {
      throw AcervoError.invalidModelId(modelId)
    }
    return sharedModelsDirectory.appendingPathComponent(slugify(modelId))
  }

  /// Returns the model directory for a given model ID, creating it (and any
  /// intermediate directories) on disk if it does not already exist.
  ///
  /// This is a path-only operation — it never contacts the CDN and never
  /// downloads files. Use it when a caller (typically a CLI tool or a
  /// side-loading flow) needs to write into the canonical shared-models
  /// location without committing to a CDN fetch. To ensure a model's *files*
  /// are present, use ``ensureAvailable(_:files:progress:)`` instead.
  ///
  /// In contexts where the App Group entitlement
  /// (`group.intrusive-memory.models`) is unavailable — typically CLI tools
  /// or non-sandboxed processes — this resolves through the same
  /// ``sharedModelsDirectory`` fallback chain, so the path matches what a
  /// consuming library would see when running with the entitlement absent.
  ///
  /// - Parameter modelId: A model identifier in "org/repo" format.
  /// - Returns: The URL of the (now-existing) model directory within
  ///   ``sharedModelsDirectory``.
  /// - Throws: ``AcervoError/invalidModelId`` if the model ID does not contain
  ///   exactly one "/", or any error thrown by `FileManager.createDirectory`.
  ///
  /// ```swift
  /// let dir = try Acervo.ensureModelDirectory(
  ///     for: "mlx-community/Qwen2.5-7B-Instruct-4bit"
  /// )
  /// // Directory now exists; safe to write files into it.
  /// ```
  @discardableResult
  public static func ensureModelDirectory(for modelId: String) throws -> URL {
    let dir = try modelDirectory(for: modelId)
    try FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true
    )
    return dir
  }
}
