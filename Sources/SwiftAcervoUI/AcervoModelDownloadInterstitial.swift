// AcervoModelDownloadInterstitial.swift
// SwiftAcervoUI
//
// The reusable first-launch / no-model-present interstitial. Hosts show
// this in place of their main UI when every required model is in the
// .notAvailable state — driving the user through downloading the single
// model the host has nominated as the default.

import SwiftAcervo
import SwiftUI

/// A single-model download prompt for first-launch / no-model-present
/// states. Reuses `AcervoModelRowController` under the hood so its state
/// machine matches the row widget.
///
/// Host apps typically present this when their model manager reports
/// that every known model is `.notAvailable`. The widget renders three
/// states:
///
/// - **prompt** — header, model summary, and a primary "Download" CTA.
///   When `onSkip` is non-nil a secondary "Download Later" button shows
///   below the CTA.
/// - **downloading** — `ProgressView` with percent label.
/// - **complete** — green checkmark + completion copy. If
///   `onComplete` is non-nil it fires exactly once when the state
///   transitions to `.available`; the host typically uses it to dismiss
///   the interstitial.
///
/// Failures during download show an inline error with a "Try Again"
/// button that re-enters the prompt → downloading flow.
///
/// All copy is configurable via the initializer; defaults are
/// English-only on purpose — host apps should pass localized
/// `LocalizedStringKey` values that resolve against their own
/// `Localizable.xcstrings`.
public struct AcervoModelDownloadInterstitial: View {

  // MARK: - Inputs

  private let item: AcervoModelRowItem
  private let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability
  private let download:
    @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void

  private let title: LocalizedStringKey
  private let welcomeMessage: LocalizedStringKey
  private let promptSubtitle: LocalizedStringKey
  private let downloadButtonLabel: LocalizedStringKey
  private let downloadingTitle: LocalizedStringKey
  private let downloadingFootnote: LocalizedStringKey
  private let completionTitle: LocalizedStringKey
  private let completionMessage: LocalizedStringKey
  private let retryButtonLabel: LocalizedStringKey
  private let skipButtonLabel: LocalizedStringKey
  private let systemImage: String

  private let onComplete: (@MainActor () -> Void)?
  private let onSkip: (@MainActor () -> Void)?

  // MARK: - State

  @State private var controller: AcervoModelRowController
  @State private var hasFiredOnComplete: Bool = false

  // MARK: - Init

  /// Creates a download interstitial for one model.
  ///
  /// All copy parameters have sensible English defaults; pass
  /// `LocalizedStringKey` values resolved against the host app's
  /// catalog for full localization.
  ///
  /// - Parameters:
  ///   - item: The model to download.
  ///   - availability: Reads current `ModelAvailability`. Called on
  ///     appear and after every action.
  ///   - download: Performs the download. Receives a progress sink the
  ///     host calls with values in `0.0...1.0`.
  ///   - title: Headline shown in the prompt state. Default `"Welcome"`.
  ///   - welcomeMessage: Body copy shown beneath the title. Default
  ///     describes a local-first generation tool.
  ///   - promptSubtitle: Short call-to-action shown above the Download
  ///     button.
  ///   - downloadButtonLabel: Label for the primary CTA. Default
  ///     `"Download Model"`.
  ///   - downloadingTitle: Headline shown above the progress bar.
  ///   - downloadingFootnote: Caption shown under the percent label.
  ///   - completionTitle: Headline shown when download succeeds.
  ///   - completionMessage: Body copy shown on completion.
  ///   - retryButtonLabel: Label for the retry button in the error
  ///     state.
  ///   - skipButtonLabel: Label for the optional "Download Later"
  ///     button. Only rendered when `onSkip` is non-nil.
  ///   - systemImage: SF Symbol name for the header icon.
  ///   - onComplete: Called once when the state first reaches
  ///     `.available`. Hosts typically use this to dismiss the
  ///     interstitial.
  ///   - onSkip: Optional skip handler. When non-nil, the prompt state
  ///     also shows a secondary "Download Later" button.
  public init(
    item: AcervoModelRowItem,
    availability: @escaping @Sendable (AcervoModelRowItem) async -> ModelAvailability,
    download:
      @escaping @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws ->
      Void,
    title: LocalizedStringKey = "Welcome",
    welcomeMessage: LocalizedStringKey =
      "Get started by downloading a model. Everything runs locally on this device after setup — no internet required.",
    promptSubtitle: LocalizedStringKey = "Tap below to download the default model.",
    downloadButtonLabel: LocalizedStringKey = "Download Model",
    downloadingTitle: LocalizedStringKey = "Downloading…",
    downloadingFootnote: LocalizedStringKey =
      "This may take several minutes depending on your connection speed.",
    completionTitle: LocalizedStringKey = "Model Ready",
    completionMessage: LocalizedStringKey = "Setup complete. You're ready to go.",
    retryButtonLabel: LocalizedStringKey = "Try Again",
    skipButtonLabel: LocalizedStringKey = "Download Later",
    systemImage: String = "arrow.down.circle",
    onComplete: (@MainActor () -> Void)? = nil,
    onSkip: (@MainActor () -> Void)? = nil
  ) {
    self.item = item
    self.availability = availability
    self.download = download
    self.title = title
    self.welcomeMessage = welcomeMessage
    self.promptSubtitle = promptSubtitle
    self.downloadButtonLabel = downloadButtonLabel
    self.downloadingTitle = downloadingTitle
    self.downloadingFootnote = downloadingFootnote
    self.completionTitle = completionTitle
    self.completionMessage = completionMessage
    self.retryButtonLabel = retryButtonLabel
    self.skipButtonLabel = skipButtonLabel
    self.systemImage = systemImage
    self.onComplete = onComplete
    self.onSkip = onSkip
    _controller = State(
      initialValue: AcervoModelRowController(
        item: item,
        availability: availability,
        download: download,
        deleteModel: { _ in }
      )
    )
  }

  // MARK: - Body

  public var body: some View {
    VStack(spacing: 32) {
      headerSection
      modelInfoSection
      stateSection
    }
    .padding(48)
    .frame(maxWidth: 560)
    .task(id: item.id) { await controller.refresh() }
    .onChange(of: controller.state) { _, newState in
      if Self.shouldFireOnComplete(state: newState, alreadyFired: hasFiredOnComplete) {
        hasFiredOnComplete = true
        onComplete?()
      }
    }
  }

  /// Returns `true` exactly when the host's `onComplete` callback should
  /// fire: the state is `.available` and the callback has not already
  /// fired this lifetime. Pure, side-effect-free — exposed at internal
  /// visibility so `SwiftAcervoUITests` can verify the fire-once
  /// contract without standing up a SwiftUI host.
  static func shouldFireOnComplete(
    state: ModelAvailability,
    alreadyFired: Bool
  ) -> Bool {
    state == .available && !alreadyFired
  }

  // MARK: - Header

  private var headerSection: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 64, weight: .light))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      Text(title)
        .font(.largeTitle)
        .fontWeight(.bold)
        .accessibilityIdentifier(AcervoUIAccessibility.onboardingWelcome)

      Text(welcomeMessage)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Model Info Card

  private var modelInfoSection: some View {
    GroupBox {
      HStack(alignment: .top, spacing: 16) {
        Image(systemName: "cpu")
          .font(.title2)
          .foregroundStyle(.tint)
          .frame(width: 32)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 6) {
          Text(item.displayName)
            .font(.headline)
            .accessibilityIdentifier(AcervoUIAccessibility.onboardingModelInfo)

          if !item.subtitleLines.isEmpty {
            Text(item.subtitleLines.joined(separator: " • "))
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .padding(8)
    }
  }

  // MARK: - State-Specific Section

  @ViewBuilder
  private var stateSection: some View {
    switch controller.state {
    case .downloading(let p):
      progressSection(progress: p)
    case .available:
      completionSection
    case .notAvailable, .partial:
      if let error = controller.lastError {
        errorSection(error: error)
      } else {
        promptSection
      }
    }
  }

  private var promptSection: some View {
    VStack(spacing: 16) {
      Text(promptSubtitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button {
        Task { await controller.startDownload() }
      } label: {
        Label(downloadButtonLabel, systemImage: "arrow.down.circle")
          .frame(minWidth: 260)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .accessibilityIdentifier(AcervoUIAccessibility.onboardingDownloadButton)

      if let onSkip {
        Button {
          onSkip()
        } label: {
          Text(skipButtonLabel)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AcervoUIAccessibility.onboardingSkipButton)
      }
    }
  }

  private func progressSection(progress: Double) -> some View {
    VStack(spacing: 16) {
      Text(downloadingTitle)
        .font(.headline)

      ProgressView(value: progress)
        .progressViewStyle(.linear)
        .frame(maxWidth: 400)
        .accessibilityIdentifier(AcervoUIAccessibility.onboardingDownloadProgress)
        .accessibilityValue("\(Int(progress * 100)) percent complete")

      Text("\(Int(progress * 100))% complete")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()

      Text(downloadingFootnote)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
  }

  private func errorSection(error: Error) -> some View {
    VStack(spacing: 16) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .accessibilityHidden(true)
        Text("Download Failed")
          .font(.headline)
          .foregroundStyle(.red)
      }

      Text(error.localizedDescription)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button {
        Task { await controller.startDownload() }
      } label: {
        Label(retryButtonLabel, systemImage: "arrow.clockwise")
          .frame(minWidth: 160)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .accessibilityIdentifier(AcervoUIAccessibility.onboardingRetryButton)
    }
  }

  private var completionSection: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 48))
        .foregroundStyle(.green)
        .accessibilityHidden(true)

      Text(completionTitle)
        .font(.title2)
        .fontWeight(.semibold)

      Text(completionMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }
}
