// AvailabilityAggregatorTests.swift
// SwiftAcervo
//
// Sortie 2 of OPERATION QUARTERMASTER TORRENT (slug-registry/S2).
//
// Direct unit tests for the pure aggregation helper. These tests don't
// touch the cache, the network, or any actor state — they verify the
// helper as a pure function of fixture input. Sortie 3 will reuse the
// helper via these same inputs.

import Foundation
import Testing

@testable import SwiftAcervo

@Suite("Availability Aggregator")
struct AvailabilityAggregatorTests {

  // MARK: - All-available short-circuit

  @Test("aggregate: all available components collapse to .available")
  func aggregateAllAvailable() {
    let inputs = [
      ComponentAvailabilityInput(availability: .available, bytesTotal: 1_000),
      ComponentAvailabilityInput(availability: .available, bytesTotal: 2_000),
      ComponentAvailabilityInput(availability: .available, bytesTotal: 3_000),
    ]
    #expect(AvailabilityAggregator.aggregate(inputs) == .available)
  }

  @Test("aggregate: single available component collapses to .available")
  func aggregateSingleAvailable() {
    let inputs = [
      ComponentAvailabilityInput(availability: .available, bytesTotal: 42),
    ]
    #expect(AvailabilityAggregator.aggregate(inputs) == .available)
  }

  // MARK: - Empty input

  @Test("aggregate: empty input collapses to .notAvailable")
  func aggregateEmpty() {
    #expect(AvailabilityAggregator.aggregate([]) == .notAvailable)
  }

  // MARK: - All notAvailable

  @Test("aggregate: all .notAvailable collapses to .notAvailable")
  func aggregateAllNotAvailable() {
    let inputs = [
      ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: 1),
      ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: 1),
    ]
    #expect(AvailabilityAggregator.aggregate(inputs) == .notAvailable)
  }

  // MARK: - Mixed: some available, some notAvailable, no downloading

  @Test("aggregate: available + notAvailable (no downloading) collapses to .notAvailable")
  func aggregateMixedNoDownloading() {
    let inputs = [
      ComponentAvailabilityInput(availability: .available, bytesTotal: 1),
      ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: 1),
    ]
    #expect(AvailabilityAggregator.aggregate(inputs) == .notAvailable)
  }

  // MARK: - Weighted average — the canonical sortie example

  @Test(
    "aggregate: transformer .downloading(0.5) 4GB, VAE .available 1GB, t5 .notAvailable 1GB → 0.5")
  func aggregateCanonicalSortieExample() {
    // EXACT numeric assertion per the EXECUTION_PLAN spec:
    //   0.5 * (4/6) + 1.0 * (1/6) + 0.0 * (1/6) = 4/12 + 2/12 + 0/12
    //                                          = 6/12 = 0.5
    let fourGB: Int64 = 4 * 1_073_741_824
    let oneGB: Int64 = 1_073_741_824
    let inputs = [
      ComponentAvailabilityInput(availability: .downloading(progress: 0.5), bytesTotal: fourGB),
      ComponentAvailabilityInput(availability: .available, bytesTotal: oneGB),
      ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: oneGB),
    ]
    let result = AvailabilityAggregator.aggregate(inputs)
    guard case .downloading(let p) = result else {
      Issue.record("expected .downloading, got \(result)")
      return
    }
    #expect(p == 0.5, "expected exactly 0.5, got \(p)")
  }

  // MARK: - Weighted: all-downloading

  @Test("aggregate: two downloading components with equal weights → arithmetic mean")
  func aggregateAllDownloadingEqualWeights() {
    let inputs = [
      ComponentAvailabilityInput(availability: .downloading(progress: 0.25), bytesTotal: 100),
      ComponentAvailabilityInput(availability: .downloading(progress: 0.75), bytesTotal: 100),
    ]
    let result = AvailabilityAggregator.aggregate(inputs)
    guard case .downloading(let p) = result else {
      Issue.record("expected .downloading, got \(result)")
      return
    }
    // 0.25 * 100/200 + 0.75 * 100/200 = 0.125 + 0.375 = 0.5
    #expect(p == 0.5)
  }

  // MARK: - Weighted: unequal weights

  @Test("aggregate: weighted average reflects byte-sized contribution")
  func aggregateWeightedUnequal() {
    let inputs = [
      ComponentAvailabilityInput(availability: .downloading(progress: 0.0), bytesTotal: 1_000),
      ComponentAvailabilityInput(availability: .downloading(progress: 1.0), bytesTotal: 3_000),
    ]
    let result = AvailabilityAggregator.aggregate(inputs)
    guard case .downloading(let p) = result else {
      Issue.record("expected .downloading, got \(result)")
      return
    }
    // 0.0 * 1000/4000 + 1.0 * 3000/4000 = 0.75
    #expect(p == 0.75)
  }

  // MARK: - Equal-weight fallback when bytes unknown

  @Test("aggregate: any nil bytes triggers equal-weight averaging")
  func aggregateEqualWeightWhenBytesUnknown() {
    // If any component has nil bytes, ALL components fall back to equal
    // weight — we don't mix known and unknown weights.
    let inputs = [
      ComponentAvailabilityInput(availability: .downloading(progress: 0.4), bytesTotal: nil),
      ComponentAvailabilityInput(availability: .available, bytesTotal: 999_999_999),
      ComponentAvailabilityInput(availability: .notAvailable, bytesTotal: nil),
    ]
    let result = AvailabilityAggregator.aggregate(inputs)
    guard case .downloading(let p) = result else {
      Issue.record("expected .downloading, got \(result)")
      return
    }
    // (0.4 + 1.0 + 0.0) / 3 = 1.4 / 3
    let expected = (0.4 + 1.0 + 0.0) / 3.0
    #expect(p == expected, "expected \(expected), got \(p)")
  }

  // MARK: - Zero-byte fallback regime

  @Test("aggregate: all-zero bytes does not divide by zero; equal-weight fallback applies")
  func aggregateAllZeroBytes() {
    let inputs = [
      ComponentAvailabilityInput(availability: .downloading(progress: 0.5), bytesTotal: 0),
      ComponentAvailabilityInput(availability: .available, bytesTotal: 0),
    ]
    let result = AvailabilityAggregator.aggregate(inputs)
    guard case .downloading(let p) = result else {
      Issue.record("expected .downloading, got \(result)")
      return
    }
    // Both fall to fallback equal-weight: (0.5 + 1.0) / 2 = 0.75
    #expect(p == 0.75)
  }

  // MARK: - Single component downloading

  @Test("aggregate: single downloading component returns its own progress")
  func aggregateSingleDownloading() {
    let inputs = [
      ComponentAvailabilityInput(availability: .downloading(progress: 0.37), bytesTotal: 1_000),
    ]
    let result = AvailabilityAggregator.aggregate(inputs)
    #expect(result == .downloading(progress: 0.37))
  }
}
