// AcervoViewRenderTests.swift
// SwiftAcervoUITests
//
// macOS-only deterministic render tests for the SwiftUI view bodies in
// AcervoModelDownloadRow, AcervoModelsSection, and
// AcervoModelDownloadInterstitial. NSHostingController forces a
// synchronous layout pass, which evaluates the view body once without
// any async work or timing. The closures we hand in don't fire during
// layout (the .task only runs after the view appears in a real window),
// so these are non-flaky on CI.

#if canImport(AppKit)
  import Foundation
  import SwiftUI
  import AppKit
  import Testing
  @testable import SwiftAcervoUI
  import SwiftAcervo

  @MainActor
  struct AcervoViewRenderTests {

    // MARK: - Fixtures

    private static let item = AcervoModelRowItem(
      id: "test/model-1",
      displayName: "Test Model 1",
      subtitleLines: ["~4 GB", "Requires 8 GB RAM"]
    )

    private static let availability: @Sendable (AcervoModelRowItem) async -> ModelAvailability = {
      _ in .notAvailable
    }
    private static let download:
      @Sendable (AcervoModelRowItem, @escaping @Sendable (Double) -> Void) async throws -> Void = {
        _, _ in
      }
    private static let deleteModel: @Sendable (AcervoModelRowItem) async throws -> Void = { _ in }

    private func render<V: View>(_ view: V) -> NSHostingController<V> {
      let host = NSHostingController(rootView: view)
      host.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
      host.view.layoutSubtreeIfNeeded()
      return host
    }

    // MARK: - AcervoModelDownloadRow

    @Test("row renders via item-based initializer")
    func rowRendersFromItem() {
      let view = AcervoModelDownloadRow(
        item: Self.item,
        availability: Self.availability,
        download: Self.download,
        deleteModel: Self.deleteModel
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders via controller-based initializer")
    func rowRendersFromController() {
      let controller = AcervoModelRowController(
        item: Self.item,
        availability: Self.availability,
        download: Self.download,
        deleteModel: Self.deleteModel
      )
      let view = AcervoModelDownloadRow(controller: controller)
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders without subtitle lines")
    func rowRendersWithoutSubtitle() {
      let bare = AcervoModelRowItem(id: "test/bare", displayName: "Bare")
      let view = AcervoModelDownloadRow(
        item: bare,
        availability: Self.availability,
        download: Self.download,
        deleteModel: Self.deleteModel
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders the .available state (checkmark + Delete button)")
    func rowRendersAvailable() async {
      let controller = AcervoModelRowController(
        item: Self.item,
        availability: { _ in .available },
        download: { _, _ in },
        deleteModel: { _ in }
      )
      await controller.refresh()
      let view = AcervoModelDownloadRow(controller: controller)
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders the .downloading state (progress bar)")
    func rowRendersDownloading() async {
      let controller = AcervoModelRowController(
        item: Self.item,
        availability: { _ in .downloading(progress: 0.5) },
        download: { _, _ in },
        deleteModel: { _ in }
      )
      await controller.refresh()
      let view = AcervoModelDownloadRow(controller: controller)
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders the .partial state (download button)")
    func rowRendersPartial() async {
      let controller = AcervoModelRowController(
        item: Self.item,
        availability: { _ in .partial(missing: ["weights.bin"]) },
        download: { _, _ in },
        deleteModel: { _ in }
      )
      await controller.refresh()
      let view = AcervoModelDownloadRow(controller: controller)
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders an inline error after a failed download attempt")
    func rowRendersWithError() async {
      struct StubError: LocalizedError { var errorDescription: String? { "stub" } }
      let controller = AcervoModelRowController(
        item: Self.item,
        availability: { _ in .notAvailable },
        download: { _, _ in throw StubError() },
        deleteModel: { _ in }
      )
      await controller.startDownload()
      #expect(controller.lastError != nil)
      let view = AcervoModelDownloadRow(controller: controller)
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("row renders with a synthetic id (no on-disk path)")
    func rowRendersWithSyntheticId() {
      let synthetic = AcervoModelRowItem(id: "synthetic-id", displayName: "Synthetic")
      let view = AcervoModelDownloadRow(
        item: synthetic,
        availability: Self.availability,
        download: Self.download,
        deleteModel: Self.deleteModel
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    // MARK: - AcervoModelsSection

    @Test("section renders an empty list inside a Form")
    func sectionRendersEmpty() {
      let view = Form {
        AcervoModelsSection(
          items: [],
          availability: Self.availability,
          download: Self.download,
          deleteModel: Self.deleteModel
        )
      }
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("section renders mixed grouped + ungrouped items")
    func sectionRendersMixedItems() {
      let items = [
        AcervoModelRowItem(id: "u1", displayName: "Ungrouped 1"),
        AcervoModelRowItem(
          id: "g1", displayName: "Grouped 1",
          groupID: "flux", groupDisplayName: "FLUX"
        ),
        AcervoModelRowItem(
          id: "g2", displayName: "Grouped 2",
          groupID: "flux", groupDisplayName: "FLUX"
        ),
      ]
      let view = Form {
        AcervoModelsSection(
          items: items,
          availability: Self.availability,
          download: Self.download,
          deleteModel: Self.deleteModel
        )
      }
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("section renders with a custom header accessibility id")
    func sectionRendersWithAccessibilityID() {
      let view = Form {
        AcervoModelsSection(
          items: [Self.item],
          header: "Custom",
          headerAccessibilityIdentifier: "test.customHeader",
          availability: Self.availability,
          download: Self.download,
          deleteModel: Self.deleteModel
        )
      }
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    // MARK: - AcervoModelDownloadInterstitial

    @Test("interstitial renders the prompt state")
    func interstitialRendersPrompt() {
      let view = AcervoModelDownloadInterstitial(
        item: Self.item,
        availability: { _ in .notAvailable },
        download: Self.download
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("interstitial renders with an onSkip handler")
    func interstitialRendersWithSkip() {
      let view = AcervoModelDownloadInterstitial(
        item: Self.item,
        availability: { _ in .notAvailable },
        download: Self.download,
        onComplete: {},
        onSkip: {}
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("interstitial renders with localized copy overrides")
    func interstitialRendersWithCustomCopy() {
      let view = AcervoModelDownloadInterstitial(
        item: Self.item,
        availability: { _ in .notAvailable },
        download: Self.download,
        title: "Get Started",
        welcomeMessage: "Welcome body",
        promptSubtitle: "Subtitle",
        downloadButtonLabel: "Go",
        downloadingTitle: "In Progress",
        downloadingFootnote: "Hang tight",
        completionTitle: "Done",
        completionMessage: "Done body",
        retryButtonLabel: "Retry",
        skipButtonLabel: "Later",
        systemImage: "arrow.down.circle.fill"
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }

    @Test("interstitial renders without a subtitle line")
    func interstitialRendersWithoutSubtitle() {
      let bare = AcervoModelRowItem(id: "test/bare", displayName: "Bare")
      let view = AcervoModelDownloadInterstitial(
        item: bare,
        availability: { _ in .notAvailable },
        download: Self.download
      )
      let host = render(view)
      #expect(host.view.bounds.width > 0)
    }
  }

#endif
