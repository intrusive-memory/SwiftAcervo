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

  // MARK: - Injected Behavior

  private let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability
  private let download: @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void
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
  public init(
    item: AcervoModelRowItem,
    availability: @escaping @Sendable (AcervoModelRowItem) async -> ModelAvailability,
    download: @escaping @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void,
    deleteModel: @escaping @Sendable (AcervoModelRowItem) async throws -> Void
  ) {
    self.item = item
    self.availability = availability
    self.download = download
    self.deleteFn = deleteModel
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
    state = .downloading(progress: 0)
    do {
      try await download(item) { [weak self] fraction in
        Task { @MainActor [weak self] in
          self?.state = .downloading(progress: fraction)
        }
      }
    } catch {
      lastError = error
    }
    state = await availability(item)
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
