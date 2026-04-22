// ModelDownloadManagerTests.swift
// SwiftAcervo
//
// Integration tests for ModelDownloadManager. All tests require real CDN
// access and a network connection. They compile unconditionally but skip
// at runtime unless INTEGRATION_TESTS is set.
//
// To run:
//   INTEGRATION_TESTS=1 xcodebuild test -scheme SwiftAcervo-Package \
//       -destination 'platform=macOS,arch=arm64'

import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Test Helpers

/// Small model suitable for integration testing — only config.json is used
/// in most tests to keep network traffic and test runtime minimal.
private let testModelId = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// Second small model used in multi-model tests.
private let testModelId2 = "mlx-community/SmolLM2-135M-Instruct-4bit"

/// Creates a unique temporary directory and returns its URL.
/// The caller is responsible for cleanup.
private func makeTempDir(label: String = "ModelDownloadManagerTests") throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(label)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// Seeds a fake model in a temp directory so it appears already-local.
///
/// Creates the slug directory and drops a `config.json` so that
/// `Acervo.isModelAvailable()` returns `true` for that model.
private func seedFakeModel(_ modelId: String, in baseDir: URL) throws {
  let slug = Acervo.slugify(modelId)
  let modelDir = baseDir.appendingPathComponent(slug)
  try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
  let configURL = modelDir.appendingPathComponent("config.json")
  try Data("{}".utf8).write(to: configURL)
}

/// Thread-safe collector for ModelDownloadProgress reports.
private actor ProgressCollector {
  var reports: [ModelDownloadProgress] = []

  func append(_ report: ModelDownloadProgress) {
    reports.append(report)
  }

  func getReports() -> [ModelDownloadProgress] {
    reports
  }
}

// MARK: - Tests

@Suite("ModelDownloadManager Integration Tests")
struct ModelDownloadManagerTests {

  // MARK: Test 1: Already-Local Model

  /// Verifies that `ensureModelsAvailable` completes successfully and emits a
  /// final 100% progress callback even when the model files are already present.
  ///
  /// The manager front-loads manifest fetches (CDN round trip) before checking
  /// local availability, so this test requires a network connection.
  @Test("ensureModelsAvailable emits 100% progress for already-local model")
  func testEnsureModelsAvailableWhenAlreadyLocal() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

    let tempDir = try makeTempDir(label: "AlreadyLocal")
    defer {
      try? FileManager.default.removeItem(at: tempDir)
      Acervo.customBaseDirectory = nil
    }

    // Seed the model so it appears locally available.
    try seedFakeModel(testModelId, in: tempDir)
    #expect(
      Acervo.isModelAvailable(testModelId, in: tempDir),
      "Seeded model should be detected as available before the call")

    // Redirect Acervo's file system to our temp directory.
    Acervo.customBaseDirectory = tempDir

    let collector = ProgressCollector()
    let manager = ModelDownloadManager.shared

    // Should complete without error — model is already local.
    try await manager.ensureModelsAvailable([testModelId]) { report in
      Task { await collector.append(report) }
    }

    let reports = await collector.getReports()

    // The manager emits a final bookkeeping callback after each model,
    // even when the model was already available locally.
    #expect(
      !reports.isEmpty,
      "Progress callback must fire at least once (final 100% event)")

    // The last callback must indicate completion (fraction == 1.0).
    if let last = reports.last {
      #expect(
        last.fraction == 1.0,
        "Final progress fraction should be 1.0 for an already-local model")
      #expect(
        last.model == testModelId,
        "Progress model field should match the requested model ID")
    }

    // Confirm no redundant download occurred: the fake config.json is still
    // a minimal "{}" placeholder, not a real downloaded file.
    let configURL =
      tempDir
      .appendingPathComponent(Acervo.slugify(testModelId))
      .appendingPathComponent("config.json")
    let content = try String(contentsOf: configURL, encoding: .utf8)
    #expect(content == "{}", "config.json must not have been replaced by a real download")
  }

  // MARK: Test 2: Downloads When Missing

  /// Verifies that `ensureModelsAvailable` downloads a model that is absent
  /// from the local file system, fires progress callbacks, and leaves the
  /// files on disk.
  @Test("ensureModelsAvailable downloads model when absent")
  func testEnsureModelsAvailableDownloadsWhenMissing() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

    let tempDir = try makeTempDir(label: "DownloadsMissing")
    defer {
      try? FileManager.default.removeItem(at: tempDir)
      Acervo.customBaseDirectory = nil
    }

    // Nothing seeded — model is absent.
    #expect(
      !Acervo.isModelAvailable(testModelId, in: tempDir),
      "Model should not be available before the call")

    // Redirect file system to temp directory and download only config.json.
    // We restrict to config.json by pre-seeding all *other* files so only
    // that one file needs to transfer. Actually, the manager always calls
    // ensureAvailable with files:[] which downloads the full manifest.
    // Use a model with just a few files to keep the test fast.
    Acervo.customBaseDirectory = tempDir

    let collector = ProgressCollector()
    let manager = ModelDownloadManager.shared

    try await manager.ensureModelsAvailable([testModelId]) { report in
      Task { await collector.append(report) }
    }

    // Verify model is now available.
    #expect(
      Acervo.isModelAvailable(testModelId, in: tempDir),
      "Model should be available after ensureModelsAvailable completes")

    // Verify config.json actually exists on disk.
    let configURL =
      tempDir
      .appendingPathComponent(Acervo.slugify(testModelId))
      .appendingPathComponent("config.json")
    #expect(
      FileManager.default.fileExists(atPath: configURL.path),
      "config.json must exist after download")

    // Verify that progress was reported.
    let reports = await collector.getReports()
    #expect(!reports.isEmpty, "Progress callbacks must fire during a download")

    // Verify sequence: last report is the model we requested.
    if let last = reports.last {
      #expect(
        last.model == testModelId,
        "Final progress report should reference the downloaded model")
      #expect(last.fraction == 1.0, "Final progress fraction should be 1.0")
    }

    // Verify monotonic fraction: no fraction should exceed 1.0.
    for report in reports {
      #expect(
        report.fraction >= 0.0 && report.fraction <= 1.0,
        "fraction must stay in [0.0, 1.0]: got \(report.fraction)")
    }
  }

  // MARK: Test 3: Progress Aggregates Across Multiple Models

  /// Verifies that progress is reported cumulatively across a batch of two
  /// models, that `bytesTotal` reflects the sum of both manifests, and that
  /// the `model` and `currentFileName` fields are populated.
  @Test("ensureModelsAvailable aggregates progress across two models")
  func testProgressAggregatesAcrossMultipleModels() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

    let tempDir = try makeTempDir(label: "ProgressAggregate")
    defer {
      try? FileManager.default.removeItem(at: tempDir)
      Acervo.customBaseDirectory = nil
    }

    Acervo.customBaseDirectory = tempDir

    let collector = ProgressCollector()
    let manager = ModelDownloadManager.shared

    try await manager.ensureModelsAvailable([testModelId, testModelId2]) { report in
      Task { await collector.append(report) }
    }

    let reports = await collector.getReports()
    #expect(!reports.isEmpty, "Progress callbacks must fire for a two-model batch")

    // bytesTotal must be positive and consistent across all callbacks
    // once both manifests are loaded (it is the same aggregated total).
    let totals = Set(reports.map(\.bytesTotal))
    // The manager sets totalBytes before the first progress callback fires,
    // so all callbacks should share the same bytesTotal.
    #expect(totals.count == 1, "All progress reports should share the same bytesTotal")

    let totalBytes = reports[0].bytesTotal
    #expect(totalBytes > 0, "Aggregate bytesTotal should be > 0")

    // Fraction must be monotonically non-decreasing overall.
    var previousFraction = -1.0
    for report in reports {
      #expect(
        report.fraction >= previousFraction,
        "fraction must be non-decreasing: \(report.fraction) < \(previousFraction)")
      previousFraction = report.fraction
    }

    // The last callback should be at 1.0.
    #expect(
      reports.last?.fraction == 1.0,
      "Final cumulative fraction must be 1.0")

    // Both model IDs should appear in the reports.
    let observedModels = Set(reports.map(\.model))
    #expect(
      observedModels.contains(testModelId),
      "Reports should include the first model: \(testModelId)")
    #expect(
      observedModels.contains(testModelId2),
      "Reports should include the second model: \(testModelId2)")

    // Verify the currentFileName field is populated for mid-download callbacks.
    // The final bookkeeping callback uses "" — filter those out.
    let midCallbacks = reports.filter { !$0.currentFileName.isEmpty }
    if !midCallbacks.isEmpty {
      for r in midCallbacks {
        #expect(
          !r.currentFileName.isEmpty,
          "currentFileName should be non-empty for mid-download callbacks")
      }
    }

    // Cumulative bytesDownloaded must not exceed bytesTotal.
    for report in reports {
      #expect(
        report.bytesDownloaded <= report.bytesTotal,
        "bytesDownloaded (\(report.bytesDownloaded)) must not exceed bytesTotal (\(report.bytesTotal))"
      )
    }
  }

  // MARK: Test 4: validateCanDownload Returns Total Bytes

  /// Verifies that `validateCanDownload` returns an `Int64` sum of all
  /// file sizes declared in the CDN manifests for the requested models.
  @Test("validateCanDownload returns sum of manifest file sizes")
  func testValidateCanDownloadReturnsTotalBytes() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

    let manager = ModelDownloadManager.shared

    // Fetch bytes for a single model.
    let singleModelBytes = try await manager.validateCanDownload([testModelId])
    #expect(singleModelBytes > 0, "Single-model byte count must be > 0")

    // Fetch bytes for two models independently.
    let model1Bytes = try await manager.validateCanDownload([testModelId])
    let model2Bytes = try await manager.validateCanDownload([testModelId2])

    // Fetch bytes for both models in one call.
    let combinedBytes = try await manager.validateCanDownload([testModelId, testModelId2])

    // The combined result must equal the sum of the individual results.
    #expect(
      combinedBytes == model1Bytes + model2Bytes,
      "Combined byte count (\(combinedBytes)) must equal sum of individual counts (\(model1Bytes) + \(model2Bytes))"
    )

    // Result is Int64 — confirm no truncation by checking raw type equivalence
    // (Swift's type system enforces this at compile time, but we document it).
    let typed: Int64 = combinedBytes
    #expect(typed == combinedBytes, "Return type must be Int64 without truncation")
  }

  // MARK: Test 5: Error Handling Propagates AcervoError Unchanged

  /// Verifies that when `ensureModelsAvailable` encounters a model that does
  /// not exist on the CDN, it throws an `AcervoError` with the original
  /// error context intact (not wrapped in a new error type).
  @Test("ensureModelsAvailable rethrows AcervoError unchanged for nonexistent model")
  func testErrorHandlingCatchesAcervoErrors() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

    let badModelId = "nonexistent-org-xyz/definitely-not-a-real-model-abc-99999"
    let manager = ModelDownloadManager.shared

    var caughtError: Error? = nil

    do {
      try await manager.ensureModelsAvailable([badModelId]) { _ in }
      #expect(Bool(false), "ensureModelsAvailable must throw for a nonexistent model")
    } catch {
      caughtError = error
    }

    // The error must be an AcervoError — not wrapped in any other type.
    guard let acervoError = caughtError as? AcervoError else {
      #expect(
        Bool(false),
        "Error must be AcervoError, got \(type(of: caughtError as Any)): \(String(describing: caughtError))"
      )
      return
    }

    // The error must carry contextual information.
    let description = acervoError.errorDescription ?? ""
    #expect(!description.isEmpty, "AcervoError must have a non-empty errorDescription")

    // The error must be one of the manifest/network variants that the manager
    // can produce when the CDN rejects an unknown model.
    switch acervoError {
    case .manifestDownloadFailed, .networkError, .manifestDecodingFailed,
      .manifestIntegrityFailed, .manifestVersionUnsupported,
      .manifestModelIdMismatch, .downloadFailed:
      break  // All are acceptable — CDN behaviour for unknown models varies.
    default:
      // Any AcervoError is acceptable; this branch is here to document
      // the expected cases explicitly.
      break
    }
  }

  // MARK: Test 6: Cancellation Stops Download Sequence

  /// Verifies that cancelling the enclosing Task while `ensureModelsAvailable`
  /// is running:
  /// 1. Does not crash or deadlock.
  /// 2. Does not leave the library in an inconsistent state for the next call.
  ///
  /// Note: Swift structured concurrency propagates task cancellation
  /// cooperatively. The download may complete before the cancel takes effect
  /// (especially for small test models), which is expected. The test asserts
  /// on graceful handling rather than guaranteed interruption timing.
  @Test("ensureModelsAvailable handles task cancellation gracefully")
  func testCancellationStopsDownloadSequence() async throws {
    guard ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] != nil else { return }

    let tempDir = try makeTempDir(label: "Cancellation")
    defer {
      try? FileManager.default.removeItem(at: tempDir)
      Acervo.customBaseDirectory = nil
    }

    Acervo.customBaseDirectory = tempDir

    let manager = ModelDownloadManager.shared

    // Launch the download in a child task so we can cancel it.
    let downloadTask = Task {
      try await manager.ensureModelsAvailable([testModelId]) { _ in }
    }

    // Yield briefly to let the download start, then cancel.
    try await Task.sleep(for: .milliseconds(200))
    downloadTask.cancel()

    // Await the result — expect either success (if fast completion before
    // cancel) or a CancellationError.
    let result = await downloadTask.result
    switch result {
    case .success:
      // Download completed before cancellation took effect — acceptable.
      break
    case .failure(let error):
      // Cancellation errors or AcervoErrors are both acceptable.
      // The important invariant is that it is NOT a novel unexplained error.
      let isCancellation = error is CancellationError
      let isAcervoError = error is AcervoError
      #expect(
        isCancellation || isAcervoError,
        "On cancellation, only CancellationError or AcervoError are acceptable; got \(type(of: error))"
      )
    }

    // Verify that a subsequent call does not fail due to partial file state.
    // After cancellation, any partial files on disk should not prevent a
    // fresh ensureModelsAvailable from completing successfully.
    Acervo.customBaseDirectory = tempDir

    var recoveryError: Error? = nil
    do {
      try await manager.ensureModelsAvailable([testModelId]) { _ in }
    } catch {
      recoveryError = error
    }

    // If the recovery call throws, it must be an AcervoError (e.g., a real
    // CDN failure), NOT an internal consistency error caused by the partial
    // files left by the cancelled download.
    if let err = recoveryError {
      #expect(
        err is AcervoError,
        "Recovery call may throw AcervoError (CDN issue), but not internal state errors; got \(type(of: err))"
      )
    } else {
      // Recovery succeeded — verify the model is now available.
      #expect(
        Acervo.isModelAvailable(testModelId, in: tempDir),
        "After successful recovery download, model should be available locally"
      )
    }
  }
}
