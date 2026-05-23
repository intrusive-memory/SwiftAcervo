// ModelAvailability.swift
// SwiftAcervo
//
// The three-state availability type returned by Acervo.availability(_:)
// and AcervoManager.availability(_:).

import Foundation

/// The states a model can be in from a consumer's point of view.
///
/// Returned by `Acervo.availability(_:)` and `AcervoManager.availability(_:)`.
/// This is the canonical "is the model usable right now?" surface; prefer
/// it over `Acervo.isModelAvailable(_:)` (which returns the strict-on-disk
/// `Bool` view and does not distinguish "downloading" / "absent" /
/// "partial").
public enum ModelAvailability: Sendable, Equatable {
  /// The model has never been downloaded (or has been wholly deleted), and
  /// no download is currently in flight for it.
  case notAvailable
  /// A download is currently in flight in this process. The associated
  /// `progress` value is in `0.0...1.0`, clamped at construction.
  case downloading(progress: Double)
  /// The model was downloaded successfully at some point, but the on-disk
  /// file set no longer matches the manifest — at least one declared file
  /// is missing (or its size no longer matches the manifest's recorded
  /// size). `missing` is the list of manifest-relative POSIX file paths
  /// that the validity oracle expected on disk and did not find.
  ///
  /// `.partial` is distinct from `.notAvailable`: `.notAvailable` means the
  /// model has never been downloaded; `.partial` means the model was
  /// downloaded then a shard (or several) went missing afterwards.
  /// Consumers may choose to re-issue `Acervo.ensureAvailable(...)` to fill
  /// the gaps — the detection is the deliverable; remediation is the
  /// consumer's call.
  ///
  /// The associated `missing` array is sorted to match the manifest's
  /// declaration order (not lexicographically) so a UI rendering the list
  /// stays stable across calls.
  case partial(missing: [String])
  /// All manifest files are on disk at their recorded sizes.
  case available
}
