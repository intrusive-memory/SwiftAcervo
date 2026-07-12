// DownloadLedger.swift
// SwiftAcervo
//
// Durable per-file state for background model downloads (iOS #81).
//
// A background `URLSession` download can finish while the app is suspended or
// terminated; iOS then relaunches the app to deliver the completion. There is
// no live `async` continuation at that point, so completion state — and the
// metadata needed to verify and finalize the delivered file — must be
// reconstructed from disk. `DownloadLedger` is that on-disk record.
//
// Storage is a single Codable JSON file in the App Group container at
// `.acervo-downloads/ledger.json`, written atomically on every mutation and
// serialized through an `actor`. See REQUIREMENTS.md R3.
//
// This type is intentionally transport-agnostic and platform-agnostic: it has
// no `URLSession` dependency and is fully unit-testable against a temp
// directory on macOS CI. The iOS background transport writes to it from its
// `URLSessionDownloadDelegate`; the app reads from it on relaunch to re-derive
// availability.

import Foundation

/// The lifecycle state of a single file within a background download.
public enum DownloadFileState: Sendable, Equatable, Codable {
  /// Enqueued with the background session but not yet started (or not yet
  /// reported as started by the OS).
  case queued
  /// Handed to a background `URLSessionDownloadTask` with this task identifier.
  /// The identifier lets a relaunched delegate map an OS callback back to the
  /// `(repoId, file)` it belongs to.
  case inflight(taskIdentifier: Int)
  /// Delivered by the OS, SHA-256 verified, and moved into the model directory.
  case verified
  /// Terminally failed (integrity mismatch after retries, or an unrecoverable
  /// transport error). `reason` is a human-readable diagnostic.
  case failed(reason: String)
}

/// The persisted record for one file: its lifecycle ``state`` plus the metadata
/// a relaunched delegate needs to verify and finalize it without a live
/// continuation.
public struct DownloadFileEntry: Sendable, Equatable, Codable {
  /// Current lifecycle state.
  public var state: DownloadFileState
  /// Expected SHA-256 (lowercase hex) from the CDN manifest, or `nil` when the
  /// manifest does not provide one (verification is then skipped).
  public var expectedSHA256: String?
  /// The CDN URL the file is fetched from, retained so a relaunched process can
  /// re-issue or resume the transfer without re-deriving it.
  public var remoteURLString: String?

  public init(
    state: DownloadFileState,
    expectedSHA256: String? = nil,
    remoteURLString: String? = nil
  ) {
    self.state = state
    self.expectedSHA256 = expectedSHA256
    self.remoteURLString = remoteURLString
  }
}

/// A durable, actor-serialized ledger of per-file background-download state,
/// persisted as JSON in the App Group container.
///
/// The ledger is keyed by **repo id** (a SwiftAcervo download unit — one
/// HuggingFace-style `org/repo`) then by **relative file path** within that
/// repo. Grouping multiple repos into a single logical "model" is a caller
/// concern (SwiftVinetas); the ledger only knows about repos and files.
///
/// All mutations persist immediately and atomically, so a process kill between
/// any two operations leaves a consistent file on disk.
public actor DownloadLedger {

  /// The on-disk shape. Nested dictionaries keep the JSON human-inspectable:
  /// `{ "org/repo": { "model.safetensors": { "state": {"verified": {}} } } }`.
  private struct Persisted: Codable, Sendable {
    var repos: [String: [String: DownloadFileEntry]]

    static let empty = Persisted(repos: [:])
  }

  /// Directory holding the ledger file (the `.acervo-downloads` subfolder).
  private let directoryURL: URL
  /// The ledger JSON file itself.
  private let fileURL: URL
  /// In-memory mirror of the on-disk state.
  private var state: Persisted

  private static let subdirectoryName = ".acervo-downloads"
  private static let fileName = "ledger.json"

  /// Creates a ledger rooted at an explicit base directory.
  ///
  /// The ledger file lives at `<baseDirectory>/.acervo-downloads/ledger.json`.
  /// Any existing file is loaded; a missing or unreadable file starts empty
  /// (the ledger never throws on construction — a corrupt file is treated as
  /// "no prior state" so a relaunch can always make forward progress).
  ///
  /// - Parameter baseDirectory: The container the `.acervo-downloads` folder is
  ///   created under. Inject a temp directory in tests; production uses
  ///   ``sharedModelsDirectory`` via ``shared()``.
  public init(baseDirectory: URL) {
    let dir = baseDirectory.appendingPathComponent(Self.subdirectoryName, isDirectory: true)
    self.directoryURL = dir
    self.fileURL = dir.appendingPathComponent(Self.fileName, isDirectory: false)
    self.state = Self.loadFromDisk(at: fileURL) ?? .empty
  }

  /// Convenience factory rooted at the App Group models directory.
  ///
  /// Uses ``Acervo/sharedModelsDirectory`` so the ledger sits alongside the
  /// downloaded models in `group.intrusive-memory.models`.
  public static func shared() -> DownloadLedger {
    DownloadLedger(baseDirectory: Acervo.sharedModelsDirectory)
  }

  // MARK: - Registration

  /// Registers `files` for `repoId`, inserting any not already present as
  /// ``DownloadFileState/queued`` with no metadata. Files already tracked keep
  /// their current entry (idempotent — safe to call again on relaunch).
  public func register(repoId: String, files: [String]) {
    var repo = state.repos[repoId] ?? [:]
    for file in files where repo[file] == nil {
      repo[file] = DownloadFileEntry(state: .queued)
    }
    state.repos[repoId] = repo
    persist()
  }

  /// Enqueues a file for background download, recording the CDN URL and expected
  /// SHA-256 needed to verify and finalize it after a relaunch. Sets the state
  /// to ``DownloadFileState/queued``; overwrites any existing entry for the file
  /// (an enqueue is an authoritative restart of that file's metadata).
  public func enqueue(
    repoId: String,
    file: String,
    remoteURL: URL,
    expectedSHA256: String?
  ) {
    var repo = state.repos[repoId] ?? [:]
    repo[file] = DownloadFileEntry(
      state: .queued,
      expectedSHA256: expectedSHA256,
      remoteURLString: remoteURL.absoluteString
    )
    state.repos[repoId] = repo
    persist()
  }

  // MARK: - Mutation

  /// Sets the lifecycle state of a single `(repoId, file)`, preserving any
  /// recorded metadata. Creates the entry (with no metadata) if absent.
  public func setState(_ newState: DownloadFileState, repoId: String, file: String) {
    var repo = state.repos[repoId] ?? [:]
    if var entry = repo[file] {
      entry.state = newState
      repo[file] = entry
    } else {
      repo[file] = DownloadFileEntry(state: newState)
    }
    state.repos[repoId] = repo
    persist()
  }

  /// Marks a file in-flight under a background task identifier.
  public func markInflight(repoId: String, file: String, taskIdentifier: Int) {
    setState(.inflight(taskIdentifier: taskIdentifier), repoId: repoId, file: file)
  }

  /// Marks a file verified (delivered, integrity-checked, moved into place).
  public func markVerified(repoId: String, file: String) {
    setState(.verified, repoId: repoId, file: file)
  }

  /// Marks a file terminally failed with a diagnostic reason.
  public func markFailed(repoId: String, file: String, reason: String) {
    setState(.failed(reason: reason), repoId: repoId, file: file)
  }

  // MARK: - Queries

  /// The full entry for a single `(repoId, file)`, or `nil` if untracked.
  public func entry(repoId: String, file: String) -> DownloadFileEntry? {
    state.repos[repoId]?[file]
  }

  /// The state of a single `(repoId, file)`, or `nil` if untracked.
  public func state(repoId: String, file: String) -> DownloadFileState? {
    state.repos[repoId]?[file]?.state
  }

  /// The expected SHA-256 recorded for a file, if any.
  public func expectedSHA256(repoId: String, file: String) -> String? {
    state.repos[repoId]?[file]?.expectedSHA256
  }

  /// The CDN URL recorded for a file, if any.
  public func remoteURL(repoId: String, file: String) -> URL? {
    guard let s = state.repos[repoId]?[file]?.remoteURLString else { return nil }
    return URL(string: s)
  }

  /// Files for `repoId` that are not yet ``DownloadFileState/verified``
  /// (queued, in-flight, or failed). Empty if the repo is complete or unknown.
  public func pendingFiles(repoId: String) -> [String] {
    guard let repo = state.repos[repoId] else { return [] }
    return repo.compactMap { $0.value.state == .verified ? nil : $0.key }.sorted()
  }

  /// `true` when `repoId` has at least one tracked file and every tracked file
  /// is ``DownloadFileState/verified``.
  public func isRepoComplete(repoId: String) -> Bool {
    guard let repo = state.repos[repoId], !repo.isEmpty else { return false }
    return repo.values.allSatisfy { $0.state == .verified }
  }

  /// Reverse lookup: the `(repoId, file)` currently in-flight under
  /// `taskIdentifier`, or `nil`. Lets a relaunched delegate route an OS
  /// completion callback back to the file it downloaded.
  public func location(forTaskIdentifier taskIdentifier: Int) -> (repoId: String, file: String)? {
    for (repoId, files) in state.repos {
      for (file, entry) in files where entry.state == .inflight(taskIdentifier: taskIdentifier) {
        return (repoId, file)
      }
    }
    return nil
  }

  // MARK: - Cleanup

  /// Drops all tracked state for `repoId` (e.g. after the caller has consumed a
  /// completed repo, or to restart a failed one from scratch).
  public func clear(repoId: String) {
    state.repos[repoId] = nil
    persist()
  }

  /// Removes every fully-verified repo from the ledger, keeping in-progress and
  /// failed ones. Keeps the file small over time.
  public func pruneCompletedRepos() {
    for repoId in state.repos.keys where isRepoComplete(repoId: repoId) {
      state.repos[repoId] = nil
    }
    persist()
  }

  // MARK: - Persistence

  private func persist() {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(state)
      // `.atomic` writes to a sibling temp file and renames into place, so a
      // crash mid-write can never leave a half-written ledger.
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // A persistence failure must not crash a download delegate. The in-memory
      // state remains authoritative for this process; the next successful
      // persist re-syncs disk. (Diagnostics are intentionally omitted here to
      // avoid importing a logger into this leaf type.)
    }
  }

  private static func loadFromDisk(at url: URL) -> Persisted? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Persisted.self, from: data)
  }
}
