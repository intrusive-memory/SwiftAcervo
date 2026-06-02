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
    #expect(AcervoUIAccessibility.onboardingComplete == "onboarding.complete")
    #expect(AcervoUIAccessibility.onboardingError == "onboarding.error")
    #expect(AcervoUIAccessibility.onboardingRetryButton == "onboarding.retryButton")
    #expect(AcervoUIAccessibility.onboardingSkipButton == "onboarding.skipButton")
  }

  @Test("models-list toolbar + context-menu identifiers match the contract")
  func modelsListIdentifiers() {
    #expect(AcervoUIAccessibility.modelsFolderRevealButton == "model.revealModelsFolder")
    #expect(AcervoUIAccessibility.listAddButton == "model.list.addButton")
    #expect(AcervoUIAccessibility.listRemoveButton == "model.list.removeButton")
    #expect(AcervoUIAccessibility.listEditButton == "model.list.editButton")
    #expect(AcervoUIAccessibility.listEditMenuItemPrefix == "model.editMenuItem")
    #expect(AcervoUIAccessibility.listRemoveMenuItemPrefix == "model.removeMenuItem")
  }

  @Test("edit-sheet identifiers match the documented contract")
  func editSheetIdentifiers() {
    #expect(AcervoUIAccessibility.editSheetIDField == "editSheet.idField")
    #expect(AcervoUIAccessibility.editSheetDisplayNameField == "editSheet.displayNameField")
    #expect(AcervoUIAccessibility.editSheetSubtitleEditor == "editSheet.subtitleEditor")
    #expect(AcervoUIAccessibility.editSheetGroupIDField == "editSheet.groupIDField")
    #expect(
      AcervoUIAccessibility.editSheetGroupDisplayNameField == "editSheet.groupDisplayNameField")
    #expect(AcervoUIAccessibility.editSheetOriginField == "editSheet.originField")
    #expect(AcervoUIAccessibility.editSheetCancelButton == "editSheet.cancelButton")
    #expect(AcervoUIAccessibility.editSheetSaveButton == "editSheet.saveButton")
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
      AcervoUIAccessibility.onboardingComplete,
      AcervoUIAccessibility.onboardingError,
      AcervoUIAccessibility.onboardingRetryButton,
      AcervoUIAccessibility.onboardingSkipButton,
      AcervoUIAccessibility.modelsFolderRevealButton,
      AcervoUIAccessibility.listAddButton,
      AcervoUIAccessibility.listRemoveButton,
      AcervoUIAccessibility.listEditButton,
      AcervoUIAccessibility.listEditMenuItemPrefix,
      AcervoUIAccessibility.listRemoveMenuItemPrefix,
      AcervoUIAccessibility.editSheetIDField,
      AcervoUIAccessibility.editSheetDisplayNameField,
      AcervoUIAccessibility.editSheetSubtitleEditor,
      AcervoUIAccessibility.editSheetGroupIDField,
      AcervoUIAccessibility.editSheetGroupDisplayNameField,
      AcervoUIAccessibility.editSheetOriginField,
      AcervoUIAccessibility.editSheetCancelButton,
      AcervoUIAccessibility.editSheetSaveButton,
    ]
    for id in ids {
      #expect(!id.isEmpty)
      #expect(!id.contains(" "))
    }
  }
}
