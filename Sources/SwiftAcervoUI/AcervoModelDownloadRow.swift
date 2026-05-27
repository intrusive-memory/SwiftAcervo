// AcervoModelDownloadRow.swift
// SwiftAcervoUI
//
// The per-model row rendered by AcervoModelsSection. Three visual states
// driven by the controller's ModelAvailability:
//
//   .notAvailable / .partial  → inline error (if any) + Download button
//   .downloading(progress)    → linear ProgressView
//   .available                → green checkmark + Delete button

import SwiftAcervo
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// A list row showing a single model's name, optional subtitle metadata,
/// and a state-appropriate control: Download, in-progress bar, or
/// checkmark + Delete. State is driven entirely by the injected
/// `AcervoModelRowController`.
///
/// Apps embed this row directly, or — more commonly — let
/// `AcervoModelsSection` render rows for them given an array of items.
public struct AcervoModelDownloadRow: View {

  @State private var controller: AcervoModelRowController

  /// Creates a row bound to the given controller.
  public init(controller: AcervoModelRowController) {
    _controller = State(initialValue: controller)
  }

  /// Convenience initializer that constructs the controller inline from
  /// an item plus the three behavior closures. Use this when the row's
  /// state does not need to outlive the view.
  public init(
    item: AcervoModelRowItem,
    availability: @escaping @Sendable (AcervoModelRowItem) async -> ModelAvailability,
    download:
      @escaping @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws ->
      Void,
    deleteModel: @escaping @Sendable (AcervoModelRowItem) async throws -> Void
  ) {
    _controller = State(
      initialValue: AcervoModelRowController(
        item: item,
        availability: availability,
        download: download,
        deleteModel: deleteModel
      )
    )
  }

  public var body: some View {
    HStack(spacing: 12) {
      modelInfo
      Spacer()
      downloadState
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier("\(AcervoUIAccessibility.modelRowPrefix).\(controller.item.id)")
    .accessibilityElement(children: .contain)
    .task(id: controller.item.id) {
      await controller.refresh()
    }
  }

  // MARK: - Model Info

  private var modelInfo: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(controller.item.displayName)
        .font(.body)

      if !controller.item.subtitleLines.isEmpty {
        HStack(spacing: 8) {
          ForEach(Array(controller.item.subtitleLines.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let path = modelDirectoryPath {
        modelPathRow(path)
      }
    }
  }

  /// Resolved on-disk location for this row's model, or `nil` if the
  /// item's `id` isn't a valid `org/repo` model id (host may use synthetic ids).
  private var modelDirectoryPath: URL? {
    try? Acervo.modelDirectory(for: controller.item.id)
  }

  private func modelPathRow(_ path: URL) -> some View {
    HStack(spacing: 4) {
      Button {
        revealInFinder(path)
      } label: {
        Image(systemName: "folder")
          .font(.caption2)
      }
      .buttonStyle(.borderless)
      #if !os(macOS)
        .disabled(true)
      #endif
      .accessibilityIdentifier(
        "\(AcervoUIAccessibility.modelRowPrefix).\(controller.item.id).revealButton"
      )
      .accessibilityLabel("Reveal \(controller.item.displayName) in Finder")

      Text(path.path)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }

  private func revealInFinder(_ path: URL) {
    #if os(macOS)
      NSWorkspace.shared.activateFileViewerSelecting([path])
    #endif
  }

  // MARK: - State-Specific Trailing Controls

  @ViewBuilder
  private var downloadState: some View {
    switch controller.state {
    case .notAvailable, .partial:
      VStack(alignment: .trailing, spacing: 4) {
        if let error = controller.lastError {
          Text("Download failed: \(error.localizedDescription). Tap Download to retry.")
            .font(.caption)
            .foregroundStyle(.red)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 200)
            .accessibilityIdentifier(
              "\(AcervoUIAccessibility.modelErrorPrefix).\(controller.item.id)")
        }
        Button {
          Task { await controller.startDownload() }
        } label: {
          Label("Download", systemImage: "arrow.down.circle")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
          "\(AcervoUIAccessibility.modelDownloadButtonPrefix).\(controller.item.id)"
        )
        .accessibilityLabel("Download \(controller.item.displayName)")
      }

    case .downloading(let progress):
      ProgressView(value: progress)
        .frame(width: 120)
        .progressViewStyle(.linear)
        .accessibilityIdentifier(
          "\(AcervoUIAccessibility.modelDownloadingPrefix).\(controller.item.id)"
        )
        .accessibilityLabel("Download progress for \(controller.item.displayName)")
        .accessibilityValue("\(Int(progress * 100)) percent complete")

    case .available:
      HStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityLabel("\(controller.item.displayName) downloaded")

        Button(role: .destructive) {
          Task { await controller.deleteModel() }
        } label: {
          Label("Delete", systemImage: "trash")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(
          "\(AcervoUIAccessibility.modelDeleteButtonPrefix).\(controller.item.id)"
        )
        .accessibilityLabel("Delete \(controller.item.displayName)")
      }
      .accessibilityIdentifier(
        "\(AcervoUIAccessibility.modelDownloadedPrefix).\(controller.item.id)")
    }
  }
}
