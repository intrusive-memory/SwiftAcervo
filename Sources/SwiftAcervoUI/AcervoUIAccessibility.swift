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

  /// Estimated-remaining-time label identifier prefix. Full id:
  /// `"model.downloadEta.<item.id>"`. Present beneath the row's progress
  /// bar only once enough progress has been observed to estimate an ETA.
  public static let modelDownloadEtaPrefix = "model.downloadEta"

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

  /// Identifier for the "Reveal Models Folder in Finder" link rendered at
  /// the top of `AcervoModelsList` (macOS only). Opens the shared models
  /// parent directory in Finder.
  public static let modelsFolderRevealButton = "model.revealModelsFolder"

  // MARK: - AcervoModelsList toolbar + context menu

  /// Toolbar "Add" button identifier on `AcervoModelsList`. Present only
  /// when the list resolves to editable.
  public static let listAddButton = "model.list.addButton"

  /// Toolbar "Remove" button identifier on `AcervoModelsList`. Present
  /// only when the list resolves to editable.
  public static let listRemoveButton = "model.list.removeButton"

  /// Toolbar "Edit" button identifier on `AcervoModelsList`. Present only
  /// when the list resolves to editable.
  public static let listEditButton = "model.list.editButton"

  /// Per-row context-menu "Edit" item identifier prefix. Full id:
  /// `"model.editMenuItem.<item.id>"`. Present only when the list
  /// resolves to editable.
  public static let listEditMenuItemPrefix = "model.editMenuItem"

  /// Per-row context-menu destructive "Remove" item identifier prefix.
  /// Full id: `"model.removeMenuItem.<item.id>"`. Present only when the
  /// list resolves to editable.
  public static let listRemoveMenuItemPrefix = "model.removeMenuItem"

  // MARK: - AcervoStoredModelEditSheet

  /// Slug / identifier text field. Editable in add mode, disabled in
  /// edit mode.
  public static let editSheetIDField = "editSheet.idField"

  /// Display-name text field.
  public static let editSheetDisplayNameField = "editSheet.displayNameField"

  /// Multi-line subtitle text editor.
  public static let editSheetSubtitleEditor = "editSheet.subtitleEditor"

  /// Group-ID text field.
  public static let editSheetGroupIDField = "editSheet.groupIDField"

  /// Group display-name text field.
  public static let editSheetGroupDisplayNameField = "editSheet.groupDisplayNameField"

  /// Origin text field.
  public static let editSheetOriginField = "editSheet.originField"

  /// Cancel toolbar button.
  public static let editSheetCancelButton = "editSheet.cancelButton"

  /// Save toolbar button. Disabled until the draft is valid.
  public static let editSheetSaveButton = "editSheet.saveButton"

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

  /// Estimated-remaining-time label identifier on the interstitial's
  /// downloading state. Present beneath the progress bar only once enough
  /// progress has been observed to estimate an ETA.
  public static let onboardingDownloadEta = "onboarding.downloadEta"

  /// Completion-state headline identifier on the interstitial. Present
  /// only when the model has finished downloading (`.available`).
  public static let onboardingComplete = "onboarding.complete"

  /// Inline error-message identifier on the interstitial's error state.
  /// Present alongside `onboardingRetryButton` when a download fails.
  public static let onboardingError = "onboarding.error"

  /// Retry button identifier on the interstitial's error state.
  public static let onboardingRetryButton = "onboarding.retryButton"

  /// Optional "Download Later" / skip button identifier on the
  /// interstitial's prompt state. Present only when the host wires a
  /// `onSkip` handler.
  public static let onboardingSkipButton = "onboarding.skipButton"
}
