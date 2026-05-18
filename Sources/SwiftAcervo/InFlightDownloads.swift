// InFlightDownloads.swift
// SwiftAcervo
//
// Process-wide registry of in-flight model downloads keyed by `modelId`.
//
// When multiple callers ask `Acervo.ensureAvailable(_:files:...)` for the
// same `modelId` concurrently, the registry causes them to converge on a
// single underlying download Task. The originator (the caller whose
// `task(for:start:)` invocation actually registered the Task) drives the
// real work; joiners receive a reference to the same Task and `await` its
// outcome.
//
// The actor is module-internal: only `Acervo.ensureAvailable` writes to it,
// and only `Acervo.availability(_:)` reads from it.

import Foundation

/// Process-wide registry of in-flight model downloads, keyed by `modelId`.
///
/// All access is mediated by Swift's actor isolation, so concurrent callers
/// observe a consistent view of the registry. The single shared instance
/// (`InFlightDownloads.shared`) is the source of truth for both:
///
///   - Download deduplication in `Acervo.ensureAvailable(_:files:...)`.
///   - The `.downloading(progress:)` arm of `Acervo.availability(_:)`.
actor InFlightDownloads {

  /// The singleton registry instance.
  static let shared = InFlightDownloads()

  /// A registered in-flight download.
  private struct Entry {
    /// The Task driving the download. Joiners await this same Task.
    let task: Task<Void, Error>
    /// The most recent overall progress fraction in `[0.0, 1.0]`.
    var progress: Double
  }

  /// `modelId -> Entry` map. Cleared by `finish(_:)` after the download Task
  /// completes (success or failure). Empty when no downloads are in flight.
  private var entries: [String: Entry] = [:]

  /// Returns the existing in-flight Task for `modelId`, or invokes `start()`
  /// to create one. Concurrent callers with the same `modelId` converge on
  /// a single Task.
  ///
  /// The `start` closure is invoked at most once per registry lifetime per
  /// `modelId`: only the caller who finds no existing entry runs it. Joiners
  /// receive the originator's Task and never invoke their own `start`.
  ///
  /// - Parameters:
  ///   - modelId: The deduplication key.
  ///   - start: A synchronous closure that constructs the download Task.
  ///     Runs while the actor is isolated; `Task { ... }` construction is
  ///     non-blocking so this is safe.
  /// - Returns: The Task to `await`. Will be the originator's Task whether
  ///   the caller is the originator or a joiner.
  func task(
    for modelId: String,
    start: @Sendable () -> Task<Void, Error>
  ) -> Task<Void, Error> {
    if let existing = entries[modelId]?.task { return existing }
    let new = start()
    entries[modelId] = Entry(task: new, progress: 0.0)
    return new
  }

  /// Publishes a progress update for `modelId`. No-op if no entry exists
  /// (e.g., the download already finished and the entry was removed).
  ///
  /// The value is clamped into `[0.0, 1.0]`.
  func publishProgress(_ p: Double, for modelId: String) {
    guard entries[modelId] != nil else { return }
    entries[modelId]?.progress = min(max(p, 0.0), 1.0)
  }

  /// Returns the most recent progress fraction for `modelId`, or `nil` if
  /// the model is not currently being downloaded.
  func progress(for modelId: String) -> Double? {
    entries[modelId]?.progress
  }

  /// Removes the registry entry for `modelId`. Called from the defer block
  /// inside the originator's Task so the registry is cleared on both the
  /// success and failure paths.
  func finish(_ modelId: String) {
    entries.removeValue(forKey: modelId)
  }

  /// Returns `true` iff there is a registered in-flight Task for `modelId`.
  func contains(_ modelId: String) -> Bool {
    entries[modelId] != nil
  }

  /// Test-only seam: empties the registry. NOT for production use.
  func reset() {
    entries.removeAll()
  }
}
