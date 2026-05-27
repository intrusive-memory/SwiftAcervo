// AcervoUIAccessibility.swift
// SwiftAcervoUI
//
// Canonical accessibility identifier namespaces used by the model-management
// widgets. Exposed publicly so host apps' UI tests can locate elements
// without duplicating the strings.

import Foundation

/// Stable accessibility identifier prefixes used by `AcervoModelsSection`
/// and `AcervoModelDownloadRow`. Identifiers are constructed at runtime by
/// appending the row item's `id` to the relevant prefix:
///
/// ```text
/// model.row.<id>
/// model.downloadButton.<id>
/// model.deleteButton.<id>
/// model.downloading.<id>
/// model.downloaded.<id>
/// model.error.<id>
/// settings.engineGroup.<groupID>
/// ```
///
/// Host apps can reference these constants in their XCUITests rather than
/// hardcoding the strings.
public enum AcervoUIAccessibility {

  /// Row container identifier prefix. Full id: `"model.row.<item.id>"`.
  /// Present on every model row regardless of state.
  public static let modelRowPrefix = "model.row"

  /// Downloaded-state container identifier prefix. Full id:
  /// `"model.downloaded.<item.id>"`. Present only when the row is in
  /// the `.available` availability state.
  public static let modelDownloadedPrefix = "model.downloaded"

  /// In-progress download container identifier prefix. Full id:
  /// `"model.downloading.<item.id>"`. Present only while the row is in
  /// the `.downloading` availability state.
  public static let modelDownloadingPrefix = "model.downloading"

  /// Per-row Download button identifier prefix. Full id:
  /// `"model.downloadButton.<item.id>"`. Present in the `.notAvailable`
  /// and `.partial` availability states.
  public static let modelDownloadButtonPrefix = "model.downloadButton"

  /// Per-row Delete button identifier prefix. Full id:
  /// `"model.deleteButton.<item.id>"`. Present only in the `.available`
  /// availability state.
  public static let modelDeleteButtonPrefix = "model.deleteButton"

  /// Per-row inline error label identifier prefix. Full id:
  /// `"model.error.<item.id>"`. Present only when the row's last
  /// download/delete attempt threw an error.
  public static let modelErrorPrefix = "model.error"

  /// Engine group header identifier prefix. Full id:
  /// `"settings.engineGroup.<item.groupID>"`. Present on the small
  /// uppercased caption rendered above each group of rows.
  public static let engineGroupHeaderPrefix = "settings.engineGroup"

  // MARK: - Onboarding / Download Interstitial

  /// Welcome headline identifier on the interstitial's prompt state.
  public static let onboardingWelcome = "onboarding.welcome"

  /// Model display-name identifier on the interstitial's prompt state.
  public static let onboardingModelInfo = "onboarding.modelInfo"

  /// Primary Download button identifier on the interstitial's prompt
  /// state.
  public static let onboardingDownloadButton = "onboarding.downloadButton"

  /// Progress bar identifier on the interstitial's downloading state.
  public static let onboardingDownloadProgress = "onboarding.downloadProgress"

  /// Retry button identifier on the interstitial's error state.
  public static let onboardingRetryButton = "onboarding.retryButton"

  /// Optional "Download Later" / skip button identifier on the
  /// interstitial's prompt state. Present only when the host wires a
  /// `onSkip` handler.
  public static let onboardingSkipButton = "onboarding.skipButton"
}
