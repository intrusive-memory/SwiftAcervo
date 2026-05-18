// ModelAvailability.swift
// SwiftAcervo
//
// The three-state availability type returned by Acervo.availability(_:)
// and AcervoManager.availability(_:).

import Foundation

/// The three states a model can be in from a consumer's point of view.
///
/// Returned by `Acervo.availability(_:)` and `AcervoManager.availability(_:)`.
/// This is the canonical "is the model usable right now?" surface; prefer
/// it over `Acervo.isModelAvailable(_:)` (which returns the strict-on-disk
/// `Bool` view and does not distinguish "downloading" from "absent").
public enum ModelAvailability: Sendable, Equatable {
  /// The model is not on disk, or its on-disk file set does not match the
  /// cached manifest (size-only check; SHA-verifying variants are out of
  /// scope and tracked separately).
  case notAvailable
  /// A download is currently in flight in this process. The associated
  /// `progress` value is in `0.0...1.0`, clamped at construction.
  case downloading(progress: Double)
  /// All manifest files are on disk at their recorded sizes.
  case available
}
