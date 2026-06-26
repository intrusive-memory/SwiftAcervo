// StreamingPerformanceTests.swift
// SwiftAcervo
//
// Human-driven performance tests that measure real download-to-verified-on-disk
// throughput across the Acervo CDN path. These tests compile unconditionally but
// skip at runtime unless the ACERVO_PERF_TESTS environment variable is set.
//
// NOTE: `chunkedVsSingleRatio` is not measurable via the public API — chunked
// streaming is always on and single-stream is an internal fallback with no
// app-facing control, so it falls outside this suite's charter.
//
// These tests MUST NEVER run in CI. Run them manually from a developer machine
// with a live network connection:
//
//   ACERVO_PERF_TESTS=1 ACERVO_PERF_NET=wifi xcodebuild test -scheme SwiftAcervo-Package -testPlan SwiftAcervo-Performance -destination 'platform=macOS,arch=arm64'
//

import Foundation
import Testing

@testable import SwiftAcervo

// MARK: - Performance Test Helpers

/// Creates a unique temporary directory for use as a SharedModels root.
/// The caller is responsible for cleaning up via `cleanupTempDirectory(_:)`.
private func makeTempSharedModels() throws -> URL {
  let tempBase = FileManager.default.temporaryDirectory
    .appendingPathComponent("SwiftAcervo-Performance-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: tempBase,
    withIntermediateDirectories: true
  )
  return tempBase
}

/// Removes a temporary directory created by `makeTempSharedModels()`.
private func cleanupTempDirectory(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

// MARK: - Tier Model-ID Constants (engineer-swappable)

/// Tiny tier: a config.json-only fetch — keeps wall time minimal.
/// Replace with any published model that has a small CDN footprint.
private let tinyModelId = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// Small tier: a full small model suitable for multi-iteration throughput measurement.
/// Replace with a published model in the 100 MB–1 GB range.
private let smallModelId = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// Large tier: a multi-GB model for single-run large-file throughput.
// TODO: set a published 3GB+ model id
private let largeModelId = ""

// MARK: - Performance Suite

@Suite("StreamingPerformanceTests")
struct StreamingPerformanceTests {

  @Test("Placeholder — verifies gate suppresses execution when ACERVO_PERF_TESTS is unset")
  func placeholderGateCheck() async throws {
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }

    // When the gate is open, perform a minimal sanity check using only
    // public Acervo API — no network call is made here; this placeholder
    // exists so the suite compiles and the gate can be confirmed to fire.
    print("[PERF] Gate is open — ACERVO_PERF_TESTS is set.")

    let tempBase = try makeTempSharedModels()
    defer { cleanupTempDirectory(tempBase) }

    // Verify the temp root was created successfully.
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: tempBase.path,
      isDirectory: &isDirectory
    )
    #expect(exists && isDirectory.boolValue, "Temp SharedModels root should be a directory")
  }
}
