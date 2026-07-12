// BackgroundDownloadCoordinator.swift
// SwiftAcervo
//
// The platform-agnostic core of iOS background downloads (#81, Phase 2b/3).
//
// This type owns the correctness-critical logic that must be reliable across an
// app relaunch, and — deliberately — has NO `URLSession` dependency, so it is
// fully unit-testable on macOS CI. The iOS-only `BackgroundDownloadSession`
// (which owns the actual background `URLSession`) is a thin delegate that hands
// its callbacks to this coordinator.
//
// Responsibilities:
//   - Route a completed download task to the right `(repoId, file)` via the
//     ledger, verify + install it (`DownloadFinalizer`), and record the result.
//   - Emit an `AsyncStream` of observation events (Phase 3 observation API) that
//     is authoritative across backgrounding/relaunch — independent of any live
//     `async` continuation.
//   - Re-derive per-repo availability from the durable ledger.

import Foundation

/// An observation event emitted by the background download subsystem.
public enum BackgroundDownloadEvent: Sendable, Equatable {
  /// Byte progress for the file currently downloading under `repoId`.
  case progress(repoId: String, file: String, fraction: Double)
  /// A file was delivered, integrity-verified, and installed.
  case fileVerified(repoId: String, file: String)
  /// A file failed terminally (integrity mismatch or transport error).
  case fileFailed(repoId: String, file: String, reason: String)
  /// Every tracked file for `repoId` is now verified.
  case repoCompleted(repoId: String)
}

/// The re-derivable availability of a repo's background download, computed from
/// the durable ledger (survives relaunch).
public enum RepoDownloadAvailability: Sendable, Equatable {
  /// Nothing tracked for this repo.
  case notTracked
  /// In progress; `fraction` is verified-file-count / total (0...1).
  case downloading(fraction: Double)
  /// At least one file failed terminally.
  case failed(files: [String])
  /// All tracked files verified.
  case complete
}

/// Drives the ledger + finalizer from transport callbacks and publishes events.
public actor BackgroundDownloadCoordinator {

  private let ledger: DownloadLedger
  /// The models base directory files are installed under
  /// (`<base>/<slug(repoId)>/<file>`). Injectable for tests.
  private let modelsBaseDirectory: URL

  /// The observation stream. Immutable and `Sendable`, so callers read it
  /// without `await`.
  public nonisolated let events: AsyncStream<BackgroundDownloadEvent>
  private let continuation: AsyncStream<BackgroundDownloadEvent>.Continuation

  /// Creates a coordinator.
  /// - Parameters:
  ///   - ledger: The durable download ledger.
  ///   - modelsBaseDirectory: Root the installed files live under. Production
  ///     passes ``Acervo/sharedModelsDirectory``; tests inject a temp dir.
  public init(ledger: DownloadLedger, modelsBaseDirectory: URL) {
    self.ledger = ledger
    self.modelsBaseDirectory = modelsBaseDirectory
    var captured: AsyncStream<BackgroundDownloadEvent>.Continuation!
    self.events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
    self.continuation = captured
  }

  // MARK: - Enqueue bookkeeping (called by the transport before/at task start)

  /// Records a file as queued with the metadata needed to finalize it later.
  public func enqueue(repoId: String, file: String, remoteURL: URL, expectedSHA256: String?) async {
    await ledger.enqueue(
      repoId: repoId, file: file, remoteURL: remoteURL, expectedSHA256: expectedSHA256)
  }

  /// Marks a file in-flight under the OS task identifier that will carry it.
  public func markInflight(repoId: String, file: String, taskIdentifier: Int) async {
    await ledger.markInflight(repoId: repoId, file: file, taskIdentifier: taskIdentifier)
  }

  // MARK: - Transport callbacks (testable without URLSession)

  /// Resolves a completed download task: map the task id back to its
  /// `(repoId, file)`, verify + install the delivered file, and record the
  /// outcome (emitting `fileVerified`/`fileFailed`, and `repoCompleted` when the
  /// repo's last file lands).
  ///
  /// `deliveredFile` is consumed (moved on success, deleted on failure/unknown).
  /// Safe to call in a relaunched process: it reads everything it needs from the
  /// ledger.
  public func resolveCompletedTask(taskIdentifier: Int, deliveredFile: URL) async {
    guard let location = await ledger.location(forTaskIdentifier: taskIdentifier) else {
      // No ledger record for this task (already resolved, or stale) — drop the
      // delivered file so it does not leak.
      try? FileManager.default.removeItem(at: deliveredFile)
      return
    }
    let (repoId, file) = location
    let expected = await ledger.expectedSHA256(repoId: repoId, file: file)
    let destination = destinationURL(repoId: repoId, file: file)

    do {
      try DownloadFinalizer.finalize(
        deliveredFile: deliveredFile, destination: destination, expectedSHA256: expected)
      await ledger.markVerified(repoId: repoId, file: file)
      continuation.yield(.fileVerified(repoId: repoId, file: file))
      if await ledger.isRepoComplete(repoId: repoId) {
        continuation.yield(.repoCompleted(repoId: repoId))
      }
    } catch {
      let reason = String(describing: error)
      await ledger.markFailed(repoId: repoId, file: file, reason: reason)
      continuation.yield(.fileFailed(repoId: repoId, file: file, reason: reason))
    }
  }

  /// Emits byte progress for the file behind `taskIdentifier`. No-op if the task
  /// is unknown or total size is unknown.
  public func recordProgress(taskIdentifier: Int, totalWritten: Int64, totalExpected: Int64) async {
    guard totalExpected > 0, let location = await ledger.location(forTaskIdentifier: taskIdentifier)
    else { return }
    let fraction = min(1.0, max(0.0, Double(totalWritten) / Double(totalExpected)))
    continuation.yield(.progress(repoId: location.repoId, file: location.file, fraction: fraction))
  }

  /// Records a transport failure for the file behind `taskIdentifier`.
  public func recordFailure(taskIdentifier: Int, reason: String) async {
    guard let location = await ledger.location(forTaskIdentifier: taskIdentifier) else { return }
    await ledger.markFailed(repoId: location.repoId, file: location.file, reason: reason)
    continuation.yield(.fileFailed(repoId: location.repoId, file: location.file, reason: reason))
  }

  // MARK: - Availability (re-derived from the durable ledger)

  /// Computes a repo's download availability from ledger state alone, so it is
  /// correct after a cold relaunch.
  public func availability(repoId: String) async -> RepoDownloadAvailability {
    let states = await ledger.fileStates(repoId: repoId)
    guard !states.isEmpty else { return .notTracked }

    let failed = states.compactMap { key, value -> String? in
      if case .failed = value { return key }
      return nil
    }
    if !failed.isEmpty { return .failed(files: failed.sorted()) }

    let verified = states.values.filter { $0 == .verified }.count
    if verified == states.count { return .complete }
    return .downloading(fraction: Double(verified) / Double(states.count))
  }

  // MARK: - Path resolution

  /// The install destination for `(repoId, file)`:
  /// `<modelsBaseDirectory>/<slug(repoId)>/<file>`, mirroring the layout the
  /// rest of Acervo reads from (`Acervo.modelDirectory(for:)`).
  nonisolated func destinationURL(repoId: String, file: String) -> URL {
    var url = modelsBaseDirectory.appendingPathComponent(
      Acervo.slugify(repoId), isDirectory: true)
    for component in file.split(separator: "/") {
      url = url.appendingPathComponent(String(component))
    }
    return url
  }
}
