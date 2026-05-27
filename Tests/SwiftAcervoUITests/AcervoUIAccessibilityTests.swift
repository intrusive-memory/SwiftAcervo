// AcervoUIAccessibilityTests.swift
// SwiftAcervoUITests
//
// These prefixes form a public XCUITest contract — host apps' UI tests
// reference them by value. A silent string change here would break
// every consumer's UI test suite. Pin the strings so any rename has to
// also update the tests on purpose.

import Foundation
import Testing

@testable import SwiftAcervoUI

struct AcervoUIAccessibilityTests {

  @Test("row + state prefixes match the documented contract")
  func rowStatePrefixes() {
    #expect(AcervoUIAccessibility.modelRowPrefix == "model.row")
    #expect(AcervoUIAccessibility.modelDownloadedPrefix == "model.downloaded")
    #expect(AcervoUIAccessibility.modelDownloadingPrefix == "model.downloading")
    #expect(AcervoUIAccessibility.modelDownloadButtonPrefix == "model.downloadButton")
    #expect(AcervoUIAccessibility.modelDeleteButtonPrefix == "model.deleteButton")
    #expect(AcervoUIAccessibility.modelErrorPrefix == "model.error")
  }

  @Test("engine group header prefix is namespaced under settings")
  func engineGroupHeaderPrefix() {
    #expect(AcervoUIAccessibility.engineGroupHeaderPrefix == "settings.engineGroup")
  }

  @Test("onboarding identifiers match the documented contract")
  func onboardingIdentifiers() {
    #expect(AcervoUIAccessibility.onboardingWelcome == "onboarding.welcome")
    #expect(AcervoUIAccessibility.onboardingModelInfo == "onboarding.modelInfo")
    #expect(AcervoUIAccessibility.onboardingDownloadButton == "onboarding.downloadButton")
    #expect(AcervoUIAccessibility.onboardingDownloadProgress == "onboarding.downloadProgress")
    #expect(AcervoUIAccessibility.onboardingRetryButton == "onboarding.retryButton")
    #expect(AcervoUIAccessibility.onboardingSkipButton == "onboarding.skipButton")
  }

  @Test("every public identifier is non-empty and contains no whitespace")
  func identifiersAreWellFormed() {
    let ids: [String] = [
      AcervoUIAccessibility.modelRowPrefix,
      AcervoUIAccessibility.modelDownloadedPrefix,
      AcervoUIAccessibility.modelDownloadingPrefix,
      AcervoUIAccessibility.modelDownloadButtonPrefix,
      AcervoUIAccessibility.modelDeleteButtonPrefix,
      AcervoUIAccessibility.modelErrorPrefix,
      AcervoUIAccessibility.engineGroupHeaderPrefix,
      AcervoUIAccessibility.onboardingWelcome,
      AcervoUIAccessibility.onboardingModelInfo,
      AcervoUIAccessibility.onboardingDownloadButton,
      AcervoUIAccessibility.onboardingDownloadProgress,
      AcervoUIAccessibility.onboardingRetryButton,
      AcervoUIAccessibility.onboardingSkipButton,
    ]
    for id in ids {
      #expect(!id.isEmpty)
      #expect(!id.contains(" "))
    }
  }
}
