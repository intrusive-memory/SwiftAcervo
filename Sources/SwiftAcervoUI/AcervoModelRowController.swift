// AcervoModelRowController.swift
// SwiftAcervoUI
//
// The state machine behind AcervoModelDownloadRow. Lives separately from
// the SwiftUI view so tests can exercise the transitions (idle →
// downloading → available, error path, partial → downloading) without a
// simulator host.

import Foundation
import SwiftAcervo

/// Drives a single model row's state transitions in response to user
/// actions. Observable so SwiftUI views can bind directly; usable in unit
/// tests by constructing one with stub closures and calling `refresh()`,
/// `startDownload()`, or `deleteModel()`.
///
/// The controller is the boundary between the row's UI and the host app's
/// concrete download stack. Hosts inject three closures:
///
/// - `availability` — read the current `ModelAvailability` for the item.
///   Called once on appear and again after every successful or failed
///   action, so the displayed state always reconciles with reality.
/// - `download` — kick off a download. The controller passes a progress
///   sink that the host calls with fractional `0.0...1.0` values; the
///   controller mirrors those into `state = .downloading(progress:)`
///   for the view to render. No polling.
/// - `deleteModel` — remove the model on disk.
///
/// Errors thrown from `download` or `deleteModel` are captured in
/// `lastError` and rendered inline by the row view. Errors are cleared
/// implicitly on the next download attempt.
@MainActor
@Observable
public final class AcervoModelRowController {

  // MARK: - Stored State

  /// The row item identifying this controller's model.
  public let item: AcervoModelRowItem

  /// Current availability — drives which controls the row renders.
  public private(set) var state: ModelAvailability = .notAvailable

  /// The last error thrown by `startDownload()` or `deleteModel()`, if
  /// any. Cleared when the user retries.
  public private(set) var lastError: Error?

  /// Estimated seconds remaining for the in-flight download, or `nil` when
  /// not downloading or when too little progress has been observed to make
  /// an estimate.
  ///
  /// Derived from the fractional progress stream over time — the host only
  /// supplies a `0.0...1.0` value, so the controller timestamps each update
  /// and tracks an exponentially-smoothed rate (fraction per second). The
  /// estimate is `(1 - progress) / rate`. Smoothing keeps it from whipsawing
  /// on bursty downloads (large `.safetensors` shards arriving in spurts
  /// between brief idle gaps). It is intentionally an approximation; render
  /// it with a leading "~".
  public private(set) var estimatedSecondsRemaining: Double?

  // MARK: - ETA Tracking

  /// Monotonic-ish time source, injectable so tests can drive the rate
  /// calculation deterministically. Defaults to wall-clock `Date()`.
  private let now: @Sendable () -> Date

  /// Timestamp and value of the last progress sample that advanced the
  /// rate estimate. `nil` until the first non-zero sample arrives.
  private var lastSampleDate: Date?
  private var lastSampleProgress: Double = 0

  /// Exponentially-smoothed download rate in fraction-per-second.
  private var smoothedRate: Double?

  /// Minimum spacing between rate samples. Sub-interval ticks accumulate
  /// into the next qualifying sample rather than producing noisy, tiny-`dt`
  /// rate spikes.
  private let minSampleInterval: TimeInterval = 0.5

  /// EMA weight for the newest rate sample. Lower = smoother / laggier.
  private let rateSmoothingAlpha: Double = 0.25

  // MARK: - Injected Behavior

  private let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability
  private let download:
    @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void
  private let deleteFn: @Sendable (AcervoModelRowItem) async throws -> Void

  // MARK: - Init

  /// Creates a controller for one row.
  ///
  /// - Parameters:
  ///   - item: The model row data.
  ///   - availability: Reads the current `ModelAvailability` for `item`.
  ///   - download: Performs the download. Receives a `@Sendable`
  ///     progress callback the host should call with values in
  ///     `0.0...1.0` to drive the row's progress bar. Throws on failure.
  ///   - deleteModel: Removes the model. Throws on failure.
  ///   - now: Time source for the ETA rate calculation. Defaults to
  ///     wall-clock `Date()`; tests inject a controllable clock.
  public init(
    item: AcervoModelRowItem,
    availability: @escaping @Sendable (AcervoModelRowItem) async -> ModelAvailability,
    download:
      @escaping @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws ->
      Void,
    deleteModel: @escaping @Sendable (AcervoModelRowItem) async throws -> Void,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.item = item
    self.availability = availability
    self.download = download
    self.deleteFn = deleteModel
    self.now = now
  }

  // MARK: - Actions

  /// Reads availability once and stores it in `state`. Called by the row
  /// view on appear and after every action; safe to call from tests.
  public func refresh() async {
    state = await availability(item)
  }

  /// Starts a download. Flips `state` to `.downloading(progress: 0)`
  /// immediately so the row renders a progress bar without waiting for
  /// the first tick, then awaits the host's download closure and
  /// reconciles with `availability` on completion or failure.
  public func startDownload() async {
    lastError = nil
    resetETA()
    state = .downloading(progress: 0)
    do {
      try await download(item) { [weak self] fraction in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.state = .downloading(progress: fraction)
          self.recordProgressSample(fraction)
        }
      }
    } catch {
      lastError = error
    }
    resetETA()
    state = await availability(item)
  }

  // MARK: - ETA Estimation

  /// Clears all rate-tracking state. Called when a download starts and when
  /// it ends (success or failure) so a stale estimate never lingers on the
  /// row after the bar goes away.
  private func resetETA() {
    estimatedSecondsRemaining = nil
    lastSampleDate = nil
    lastSampleProgress = 0
    smoothedRate = nil
  }

  /// Folds one fractional-progress sample into the smoothed rate and
  /// republishes `estimatedSecondsRemaining`. Ignores out-of-range values,
  /// non-advancing samples, and samples closer together than
  /// `minSampleInterval` (those accumulate into the next qualifying one).
  ///
  /// Exposed at internal visibility so unit tests can drive the estimator
  /// directly alongside an injected clock.
  func recordProgressSample(_ fraction: Double) {
    guard fraction > 0, fraction < 1 else {
      // 1.0 (or a bogus >1) means "done" — no point estimating.
      if fraction >= 1 { estimatedSecondsRemaining = 0 }
      return
    }

    let timestamp = now()
    guard let previousDate = lastSampleDate else {
      // First real sample: anchor, but we need two points for a rate.
      lastSampleDate = timestamp
      lastSampleProgress = fraction
      return
    }

    let dt = timestamp.timeIntervalSince(previousDate)
    guard dt >= minSampleInterval else { return }

    let deltaFraction = fraction - lastSampleProgress
    lastSampleDate = timestamp
    lastSampleProgress = fraction
    guard deltaFraction > 0 else { return }

    let instantRate = deltaFraction / dt
    if let current = smoothedRate {
      smoothedRate = rateSmoothingAlpha * instantRate + (1 - rateSmoothingAlpha) * current
    } else {
      smoothedRate = instantRate
    }

    if let rate = smoothedRate, rate > 0 {
      estimatedSecondsRemaining = (1 - fraction) / rate
    }
  }

  /// Formats a remaining-seconds estimate as a compact `"2m 5s"` / `"45s"`
  /// string. Returns `nil` for non-finite or non-positive input so callers
  /// can omit the label entirely. Shared by the row and the interstitial.
  static func formatRemaining(_ seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
    let total = Int(seconds.rounded())
    if total >= 60 {
      return "\(total / 60)m \(total % 60)s"
    }
    return "\(total)s"
  }

  /// Deletes the model and re-reads availability on completion (or
  /// failure, so a partial delete still surfaces accurately).
  public func deleteModel() async {
    do {
      try await deleteFn(item)
    } catch {
      lastError = error
    }
    state = await availability(item)
  }
}
