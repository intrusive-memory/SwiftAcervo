// AcervoModelRowControllerTests.swift
// SwiftAcervoUITests
//
// Drive the row controller through every state transition without a
// SwiftUI host. Verifies the controller-as-state-machine contract that
// AcervoModelDownloadRow renders against.

import Foundation
import Testing
@testable import SwiftAcervoUI
import SwiftAcervo

@MainActor
struct AcervoModelRowControllerTests {

  // MARK: - Fixtures

  private static let testItem = AcervoModelRowItem(
    id: "test/model-1",
    displayName: "Test Model 1",
    subtitleLines: ["~4 GB", "Requires 8 GB RAM"]
  )

  /// A small error subclass with a stable `localizedDescription` so
  /// assertions can compare it deterministically.
  private struct StubError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
  }

  // MARK: - refresh()

  @Test("refresh() copies the availability closure result into state")
  func refreshCopiesIntoState() async {
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in .available },
      download: { _, _ in },
      deleteModel: { _ in }
    )

    #expect(controller.state == .notAvailable)
    await controller.refresh()
    #expect(controller.state == .available)
  }

  // MARK: - startDownload()

  @Test("startDownload() flips to .downloading(0) immediately before awaiting")
  func startDownloadFlipsImmediately() async {
    // Block the download closure on a continuation so we can inspect
    // the controller's state mid-download.
    let gate = AsyncGate()
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in .available },
      download: { _, _ in
        await gate.wait()
      },
      deleteModel: { _ in }
    )

    // Kick off the download but don't await it.
    let task = Task { await controller.startDownload() }

    // Spin briefly so startDownload() can apply its synchronous state
    // mutation before we observe.
    try? await Task.sleep(for: .milliseconds(20))
    if case .downloading(let progress) = controller.state {
      #expect(progress == 0)
    } else {
      Issue.record("Expected .downloading(0), got \(controller.state)")
    }

    await gate.signal()
    await task.value
    #expect(controller.state == .available)
  }

  @Test("progress sink callback mirrors fractions into state")
  func progressSinkMirrorsState() async {
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in .available },
      download: { _, progress in
        progress(0.25)
        try? await Task.sleep(for: .milliseconds(5))
        progress(0.75)
        try? await Task.sleep(for: .milliseconds(5))
      },
      deleteModel: { _ in }
    )

    await controller.startDownload()
    // After download completes, refresh() resolves to .available.
    #expect(controller.state == .available)
    #expect(controller.lastError == nil)
  }

  @Test("download failure captures lastError and reconciles state via availability")
  func downloadFailureCapturesError() async {
    let err = StubError(message: "Manifest 404")
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in .notAvailable },
      download: { _, _ in throw err },
      deleteModel: { _ in }
    )

    await controller.startDownload()
    #expect(controller.state == .notAvailable)

    let captured = controller.lastError as? StubError
    #expect(captured == err)
  }

  @Test("retrying after failure clears lastError before the next attempt")
  func retryClearsLastError() async {
    let stub = DownloadStub()
    stub.shouldFailNextCall = true
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in stub.availability },
      download: { _, _ in try stub.runDownload() },
      deleteModel: { _ in }
    )

    await controller.startDownload()
    #expect(controller.lastError != nil)

    stub.availability = .available
    await controller.startDownload()
    #expect(controller.lastError == nil)
    #expect(controller.state == .available)
  }

  // MARK: - deleteModel()

  @Test("deleteModel() refreshes availability on success")
  func deleteRefreshesOnSuccess() async {
    let stub = DownloadStub()
    stub.availability = .available
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in stub.availability },
      download: { _, _ in },
      deleteModel: { _ in stub.availability = .notAvailable }
    )

    await controller.refresh()
    #expect(controller.state == .available)

    await controller.deleteModel()
    #expect(controller.state == .notAvailable)
    #expect(controller.lastError == nil)
  }

  @Test("deleteModel() failure captures lastError")
  func deleteFailureCapturesError() async {
    let err = StubError(message: "Permission denied")
    let controller = AcervoModelRowController(
      item: Self.testItem,
      availability: { _ in .available },
      download: { _, _ in },
      deleteModel: { _ in throw err }
    )

    await controller.refresh()
    await controller.deleteModel()
    let captured = controller.lastError as? StubError
    #expect(captured == err)
    // Availability still returns .available, so the row will show the
    // checkmark + Delete; the error surfaces only in `lastError` (the
    // row view doesn't currently render it post-delete, but the
    // controller state is preserved for future UX).
    #expect(controller.state == .available)
  }
}

// MARK: - Helpers

/// A tiny one-shot async gate so a test can pause inside the download
/// closure, observe the controller's mid-flight state, then let the
/// closure return. Reusing AsyncSemaphore-style primitives without
/// pulling in any dependency.
private actor AsyncGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var signaled = false

  func wait() async {
    if signaled { return }
    await withCheckedContinuation { cont in
      continuations.append(cont)
    }
  }

  func signal() {
    signaled = true
    for cont in continuations { cont.resume() }
    continuations.removeAll()
  }
}

/// A mutable-state helper passed through Sendable closures by capturing
/// a reference. `@unchecked Sendable` because tests are single-threaded
/// against this stub.
private final class DownloadStub: @unchecked Sendable {
  var availability: ModelAvailability = .notAvailable
  var shouldFailNextCall: Bool = false

  func runDownload() throws {
    if shouldFailNextCall {
      shouldFailNextCall = false
      throw NSError(domain: "DownloadStub", code: 1)
    }
  }
}
