import Foundation
import SwiftAcervo

/// Produces a `manifest.json` for a locally-staged model directory.
///
/// `ManifestGenerator` scans a directory, hashes every non-manifest file
/// with `IntegrityVerification.sha256(of:)`, and constructs a `CDNManifest`
/// that captures the path, size, and SHA-256 of every file in the tree.
///
/// The generator enforces two of the acervo integrity checks defined in
/// `REQUIREMENTS-acervo-tool.md`:
///
/// - **CHECK 2** — Refuses to write a manifest if any scanned file is
///   zero bytes. The check runs over every candidate file *before* any
///   bytes are written to disk.
/// - **CHECK 3** — Immediately re-reads the written manifest from disk
///   and calls `CDNManifest.verifyChecksum()`. On mismatch the manifest
///   file is deleted and `AcervoToolError.manifestChecksumMismatch` is
///   thrown so the caller never proceeds with a corrupted manifest.
actor ManifestGenerator {

  /// Schema version written into `manifest.json`. Matches
  /// `CDNManifest.supportedVersion` to keep producer and consumer in sync.
  private let manifestVersion: Int

  /// The `org/repo` model identifier written into the manifest. When `nil`
  /// the generator falls back to the directory name with `_` substituted
  /// for `/` so the file stays valid even for ad-hoc directories.
  private let modelId: String?

  /// File names that must never appear inside the generated manifest
  /// (the manifest itself, and hidden macOS cruft).
  private static let excludedFileNames: Set<String> = [
    "manifest.json",
    ".DS_Store",
  ]

  /// Path component prefixes that cause a file to be skipped entirely
  /// (mirrors the `--exclude` patterns used by `CDNUploader`).
  private static let excludedPathPrefixes: [String] = [
    ".huggingface/",
  ]

  init(modelId: String? = nil, manifestVersion: Int = CDNManifest.supportedVersion) {
    self.modelId = modelId
    self.manifestVersion = manifestVersion
  }

  /// Scans `directory`, verifies every file is non-empty (CHECK 2), writes
  /// `manifest.json`, then re-reads and verifies it (CHECK 3).
  ///
  /// - Parameters:
  ///   - directory: Local staging directory. Must exist and be readable.
  ///   - quiet: When `false` and stdout is a TTY, renders a TUI progress
  ///     bar advanced once per file as the per-file SHA-256 is computed.
  ///     The default preserves the original silent behaviour used by
  ///     unit tests and other library callers.
  /// - Returns: Absolute `URL` of the written `manifest.json`.
  /// - Throws:
  ///   - `AcervoToolError.zeroByteFile` when any scanned file is 0 bytes.
  ///   - `AcervoToolError.manifestChecksumMismatch` when the just-written
  ///     manifest fails `verifyChecksum()` on re-read.
  ///   - Errors from `FileManager` / `FileHandle` / `JSONEncoder`.
  func generate(directory: URL, quiet: Bool = true) async throws -> URL {
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    let discovered = try scan(directory: resolvedDirectory)

    // CHECK 2: bail BEFORE writing anything if any file is zero bytes.
    for entry in discovered where entry.size == 0 {
      throw AcervoToolError.zeroByteFile(entry.relativePath)
    }

    let reporter = ProgressReporter(
      label: "Hashing manifest: ",
      total: discovered.count,
      quiet: quiet
    )

    // Hash every surviving file and build manifest entries.
    var manifestFiles: [CDNManifestFile] = []
    manifestFiles.reserveCapacity(discovered.count)
    for entry in discovered {
      defer { reporter.advance() }
      let sha = try IntegrityVerification.sha256(of: entry.url)
      manifestFiles.append(
        CDNManifestFile(
          path: entry.relativePath,
          sha256: sha,
          sizeBytes: entry.size
        )
      )
    }
    // Deterministic ordering keeps diffs stable and matches how consumers
    // enumerate manifest files.
    manifestFiles.sort { $0.path < $1.path }

    let resolvedModelId = modelId ?? Self.derivedModelId(from: resolvedDirectory)
    let slug = Self.slug(from: resolvedModelId)
    let manifest = CDNManifest(
      manifestVersion: manifestVersion,
      modelId: resolvedModelId,
      slug: slug,
      updatedAt: Self.iso8601Now(),
      files: manifestFiles,
      manifestChecksum: CDNManifest.computeChecksum(from: manifestFiles.map(\.sha256))
    )

    let manifestURL = resolvedDirectory.appendingPathComponent("manifest.json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: manifestURL, options: [.atomic])

    // CHECK 3: re-read from disk and verify. On any failure, delete the
    // just-written manifest so callers cannot accidentally ship it.
    do {
      let roundTripData = try Data(contentsOf: manifestURL)
      let roundTripManifest = try JSONDecoder().decode(CDNManifest.self, from: roundTripData)
      guard roundTripManifest.verifyChecksum() else {
        try? FileManager.default.removeItem(at: manifestURL)
        throw AcervoToolError.manifestChecksumMismatch(path: manifestURL.path)
      }
    } catch let error as AcervoToolError {
      throw error
    } catch {
      try? FileManager.default.removeItem(at: manifestURL)
      throw AcervoToolError.manifestChecksumMismatch(path: manifestURL.path)
    }

    return manifestURL
  }

  // MARK: - Scanning

  /// An on-disk file the generator has decided belongs in the manifest.
  private struct DiscoveredFile {
    let url: URL
    let relativePath: String
    let size: Int64
  }

  /// Walks `directory` recursively and returns every regular file the
  /// generator wants to hash. Skips hidden packages such as `.huggingface`
  /// and the manifest itself.
  private func scan(directory: URL) throws -> [DiscoveredFile] {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw CocoaError(.fileReadNoSuchFile)
    }

    let resourceKeys: [URLResourceKey] = [
      .isRegularFileKey,
      .fileSizeKey,
      .isSymbolicLinkKey,
    ]
    guard
      let enumerator = fm.enumerator(
        at: directory,
        includingPropertiesForKeys: resourceKeys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return []
    }

    var results: [DiscoveredFile] = []
    for case let fileURL as URL in enumerator {
      let relative = Self.relativePath(of: fileURL, under: directory)

      // Apply exclusion rules.
      let lastComponent = fileURL.lastPathComponent
      if Self.excludedFileNames.contains(lastComponent) { continue }
      if Self.excludedPathPrefixes.contains(where: { relative.hasPrefix($0) }) { continue }

      let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
      guard values.isRegularFile == true else { continue }
      if values.isSymbolicLink == true { continue }

      let size = Int64(values.fileSize ?? 0)
      results.append(
        DiscoveredFile(url: fileURL, relativePath: relative, size: size)
      )
    }
    return results
  }

  // MARK: - Helpers

  private static func relativePath(of fileURL: URL, under baseURL: URL) -> String {
    let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
    let filePath = fileURL.path
    if filePath.hasPrefix(basePath) {
      return String(filePath.dropFirst(basePath.count))
    }
    return fileURL.lastPathComponent
  }

  private static func derivedModelId(from directory: URL) -> String {
    let name = directory.lastPathComponent
    // `org_repo` → `org/repo` when possible; otherwise use the raw name.
    if let underscore = name.firstIndex(of: "_") {
      let org = name[..<underscore]
      let repo = name[name.index(after: underscore)...]
      return "\(org)/\(repo)"
    }
    return name
  }

  private static func slug(from modelId: String) -> String {
    modelId.replacingOccurrences(of: "/", with: "_")
  }

  private static func iso8601Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date())
  }
}
