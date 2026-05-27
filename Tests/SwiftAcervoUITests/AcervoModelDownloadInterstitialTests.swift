// AcervoModelDownloadInterstitialTests.swift
// SwiftAcervoUITests
//
// Pure-logic tests for the interstitial's fire-once onComplete contract.
// The interstitial's view body is exercised indirectly via
// AcervoModelRowControllerTests (the row state machine is shared); this
// file covers only the bit unique to the interstitial.

import Foundation
import SwiftAcervo
import Testing

@testable import SwiftAcervoUI

@MainActor
struct AcervoModelDownloadInterstitialTests {

  @Test("shouldFireOnComplete returns true exactly when state is .available and not already fired")
  func fireOnceContract() {
    // Available + not fired → fire.
    #expect(
      AcervoModelDownloadInterstitial.shouldFireOnComplete(
        state: .available,
        alreadyFired: false
      )
    )

    // Available + already fired → do not fire again.
    #expect(
      !AcervoModelDownloadInterstitial.shouldFireOnComplete(
        state: .available,
        alreadyFired: true
      )
    )

    // Non-available states never fire, regardless of `alreadyFired`.
    let nonAvailable: [ModelAvailability] = [
      .notAvailable,
      .downloading(progress: 0),
      .downloading(progress: 0.5),
      .partial(missing: ["a.bin"]),
    ]
    for state in nonAvailable {
      #expect(
        !AcervoModelDownloadInterstitial.shouldFireOnComplete(
          state: state,
          alreadyFired: false
        ),
        "Expected non-available state \(state) to not fire onComplete"
      )
      #expect(
        !AcervoModelDownloadInterstitial.shouldFireOnComplete(
          state: state,
          alreadyFired: true
        )
      )
    }
  }
}
