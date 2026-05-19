// AvailabilityAggregator.swift
// SwiftAcervo
//
// Sortie 2 of OPERATION QUARTERMASTER TORRENT (slug-registry/S2).
//
// Pure aggregation helper that collapses per-component `ModelAvailability`
// values into a single slug-level result. Sortie 3 (`ensureAvailable`)
// reuses this exact helper so the two code paths cannot drift in how they
// summarize a multi-component download.
//
// Aggregation rules (per REQUIREMENTS §1 and EXECUTION_PLAN slug-registry/S2):
//
//   * Every component `.available`        → `.available`
//   * Any component `.downloading(p)`     → `.downloading(weightedAverage)`
//                                            using `bytesTotal` weights
//   * Otherwise (any `.notAvailable`)     → `.notAvailable`
//
// Per-component contribution to the weighted average:
//
//   * `.notAvailable`              → 0.0
//   * `.available`                 → 1.0
//   * `.downloading(progress: p)`  → p
//
// Weighting:
//
//   * When every component declares a non-nil `bytesTotal`, the weight is
//     that component's `bytesTotal`.
//   * When ANY component has `bytesTotal == nil`, the aggregator falls back
//     to equal weights (1.0 each). This is the "weights unknown" case the
//     sortie spec calls out — we do NOT mix known and unknown weights,
//     because that would produce a result that depends on which subset of
//     components happens to declare bytes.

import Foundation

/// Single per-component input to the aggregator.
///
/// `bytesTotal == nil` means the component's declared size is unknown to
/// the caller; if any component carries `nil`, the aggregator falls back
/// to equal weighting.
struct ComponentAvailabilityInput: Sendable, Equatable {
  let availability: ModelAvailability
  let bytesTotal: Int64?

  init(availability: ModelAvailability, bytesTotal: Int64?) {
    self.availability = availability
    self.bytesTotal = bytesTotal
  }
}

/// Pure aggregation helper for slug-keyed availability + ensureAvailable.
///
/// The implementation is a free-function-equivalent enum so it cannot hold
/// state and cannot accidentally diverge between call sites.
enum AvailabilityAggregator {

  /// Collapses per-component states into a single slug-level
  /// `ModelAvailability` per the rules documented at the top of this file.
  ///
  /// Empty input is treated as `.notAvailable` — a slug with zero declared
  /// components is degenerate, and "no components ready" is the safest
  /// answer to give a UI.
  static func aggregate(_ components: [ComponentAvailabilityInput]) -> ModelAvailability {
    guard !components.isEmpty else {
      return .notAvailable
    }

    // All available → available. Cheap pre-check that avoids the weighted
    // math when no download is in flight.
    if components.allSatisfy({ $0.availability == .available }) {
      return .available
    }

    // Any downloading → downloading(weightedAverage). We compute the
    // weighted average over EVERY component, treating .available as 1.0
    // and .notAvailable as 0.0.
    let anyDownloading = components.contains { input in
      if case .downloading = input.availability { return true }
      return false
    }
    guard anyDownloading else {
      // No .downloading present, and we already ruled out all-available
      // above. Therefore at least one .notAvailable is present → the
      // slug-level state is .notAvailable.
      return .notAvailable
    }

    // Decide the weighting regime. We fall back to equal weights as soon
    // as any component reports bytesTotal == nil to avoid mixing known
    // and unknown weights.
    let useEqualWeights = components.contains { $0.bytesTotal == nil }

    var numerator: Double = 0.0
    var denominator: Double = 0.0
    for input in components {
      let weight: Double
      if useEqualWeights {
        weight = 1.0
      } else {
        // bytesTotal cannot be nil here (we just checked), but treat a
        // zero-byte component as weight 0 to avoid divide-by-zero pathologies.
        weight = Double(input.bytesTotal ?? 0)
      }
      let value: Double
      switch input.availability {
      case .notAvailable:
        value = 0.0
      case .available:
        value = 1.0
      case .downloading(let p):
        value = p
      }
      numerator += value * weight
      denominator += weight
    }
    // If every component had bytesTotal == 0 in the bytes-known regime,
    // denominator could still be 0. Defensively fall back to equal weights
    // in that case so we always produce a finite result.
    if denominator == 0 {
      let count = Double(components.count)
      var fallback: Double = 0.0
      for input in components {
        switch input.availability {
        case .notAvailable: fallback += 0.0
        case .available: fallback += 1.0
        case .downloading(let p): fallback += p
        }
      }
      return .downloading(progress: clamped(fallback / count))
    }
    return .downloading(progress: clamped(numerator / denominator))
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, 0.0), 1.0)
  }
}
