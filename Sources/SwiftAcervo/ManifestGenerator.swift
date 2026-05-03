// ManifestGenerator.swift
// SwiftAcervo
//
// Lifted from `Sources/acervo/ManifestGenerator.swift` per requirements §6.7
// (and reaffirmed in EXECUTION_PLAN WU2 Sortie 2 task 5). The library now
// owns CDN-mutation orchestration end-to-end via `Acervo.publishModel`, and
// the manifest generator is a precondition step the orchestrator drives
// directly. Lifting also keeps the `acervo` CLI thin: its `ManifestCommand`
// becomes a passthrough wrapper around this public type.
//
// Behavioural parity with the original:
//   - CHECK 2: refuse to write a manifest if any scanned file is zero bytes.
//   - CHECK 3: re-read the just-written manifest and run `verifyChecksum()`;
//     on mismatch, delete the file before throwing.
//   - Same scanning rules: skip `manifest.json` / `.DS_Store`, skip the
//     `.huggingface/` prefix, skip non-regular files and symlinks.
//
// What changed during the lift:
//   - The CLI-only `AcervoToolError` → library-level `AcervoError` cases
//     (`manifestZeroByteFile`, `manifestPostWriteCorrupted`,
//     `manifestRelativePathOutsideBase`).
//   - The CLI-only `ProgressReporter` (Progress.swift dependency) → an
//     optional `progress: (@Sendable (Int, Int) -> Void)?` closure called
//     once per file with `(completed, total)`. The CLI wires its own
//     `ProgressReporter.advance()` into that closure so the user-visible
//     progress bar is unchanged.

import CryptoKit
import Foundation

/// Produces a `manifest.json` for a locally-staged model directory.
///
/// `ManifestGenerator` scans a directory, hashes every non-manifest file
/// with `IntegrityVerification.sha256(of:)`, and constructs a `CDNManifest`
/// that captures the path, size, and SHA-256 of every file in the tree.
///
/// The generator enforces two of the integrity checks that gate any
/// CDN publish:
///
/// - **CHECK 2** — Refuses to write a manifest if any scanned file is
///   zero bytes. The check runs over every candidate file *before* any
///   bytes are written to disk.
/// - **CHECK 3** — Immediately re-reads the written manifest from disk
///   and calls `CDNManifest.verifyChecksum()`. On mismatch the manifest
///   file is deleted and `AcervoError.manifestPostWriteCorrupted` is
///   thrown so the caller never proceeds with a corrupted manifest.
public actor ManifestGenerator {

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
  /// (mirrors the `--exclude` patterns historically used for HuggingFace
  /// staging trees).
  private static let excludedPathPrefixes: [String] = [
    ".huggingface/"
  ]

  public init(modelId: String? = nil, manifestVersion: Int = CDNManifest.supportedVersion) {
    self.modelId = modelId
    self.manifestVersion = manifestVersion
  }

  /// Scans `directory`, verifies every file is non-empty (CHECK 2), writes
  /// `manifest.json`, then re-reads and verifies it (CHECK 3).
  ///
  /// - Parameters:
  ///   - directory: Local staging directory. Must exist and be readable.
  ///   - progress: Optional progress hook invoked once per file as the
  ///     per-file SHA-256 is computed. The closure receives
  ///     `(completed, total)` counts. The default is `nil` (no progress).
  /// - Returns: Absolute `URL` of the written `manifest.json`.
  /// - Throws:
  ///   - `AcervoError.manifestZeroByteFile` when any scanned file is 0 bytes.
  ///   - `AcervoError.manifestPostWriteCorrupted` when the just-written
  ///     manifest fails `verifyChecksum()` on re-read.
  ///   - Errors from `FileManager` / `FileHandle` / `JSONEncoder`.
  public func generate(
    directory: URL,
    progress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> URL {
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    let discovered = try scan(directory: resolvedDirectory)

    // CHECK 2: bail BEFORE writing anything if any file is zero bytes.
    for entry in discovered where entry.size == 0 {
      throw AcervoError.manifestZeroByteFile(path: entry.relativePath)
    }

    let total = discovered.count

    // Announce the total up front so progress consumers can size their
    // UI before the first hash completes.
    progress?(0, total)

    // Hash every surviving file and build manifest entries.
    var manifestFiles: [CDNManifestFile] = []
    manifestFiles.reserveCapacity(discovered.count)
    var completed = 0
    for entry in discovered {
      let sha = try IntegrityVerification.sha256(of: entry.url)
      manifestFiles.append(
        CDNManifestFile(
          path: entry.relativePath,
          sha256: sha,
          sizeBytes: entry.size
        )
      )
      completed += 1
      progress?(completed, total)
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
        throw AcervoError.manifestPostWriteCorrupted(path: manifestURL.path)
      }
    } catch let error as AcervoError {
      throw error
    } catch {
      try? FileManager.default.removeItem(at: manifestURL)
      throw AcervoError.manifestPostWriteCorrupted(path: manifestURL.path)
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
      let relative = try Self.relativePath(of: fileURL, under: directory)

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

  /// Computes `fileURL`'s path relative to `baseURL` using URL path
  /// components, which survives `/tmp` ↔ `/private/tmp` symlink
  /// divergence and trailing-slash inconsistencies that can fool a
  /// naïve `String.hasPrefix` comparison on `URL.path`.
  ///
  /// Throws `AcervoError.manifestRelativePathOutsideBase` rather than
  /// falling back to `lastPathComponent`. A silent basename fallback
  /// produced ambiguous manifest entries for nested HuggingFace layouts
  /// (multiple `config.json` files collapsed to a single path with
  /// distinct SHA-256s).
  public static func relativePath(of fileURL: URL, under baseURL: URL) throws -> String {
    let baseComponents = baseURL.resolvingSymlinksInPath().pathComponents
    let fileComponents = fileURL.resolvingSymlinksInPath().pathComponents

    guard fileComponents.count > baseComponents.count,
      Array(fileComponents.prefix(baseComponents.count)) == baseComponents
    else {
      throw AcervoError.manifestRelativePathOutsideBase(
        file: fileURL.path,
        base: baseURL.path
      )
    }

    return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
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
