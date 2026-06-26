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

#if canImport(Darwin)
import Darwin
#endif

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

/// Resolves a human-readable machine model identifier for the run environment
/// line. On macOS this is the `hw.model` board id (e.g. `Mac15,3`); on other
/// platforms it is the device model identifier.
private func perfMachineModel() -> String {
  #if canImport(Darwin)
  var size = 0
  guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
    return "unknown"
  }
  var buffer = [CChar](repeating: 0, count: size)
  guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
    return "unknown"
  }
  return String(cString: buffer)
  #else
  return "unknown"
  #endif
}

/// Converts a `ContinuousClock.Duration` to a fractional seconds `Double`.
private func perfSeconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
}

/// Thread-safe collector for download progress reports. Records are captured
/// synchronously (with the observing clock instant) so that time-to-first-byte
/// is measured at the moment the callback fires, free of async-hop skew.
private final class PerfProgressCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var _reports: [AcervoDownloadProgress] = []
  private var _firstByteInstant: ContinuousClock.Instant?

  /// Records a progress report and, on the first report carrying bytes,
  /// stamps the time-to-first-byte instant.
  func record(_ report: AcervoDownloadProgress, at instant: ContinuousClock.Instant) {
    lock.lock()
    defer { lock.unlock() }
    _reports.append(report)
    if _firstByteInstant == nil, report.bytesDownloaded > 0 {
      _firstByteInstant = instant
    }
  }

  var firstByteInstant: ContinuousClock.Instant? {
    lock.lock()
    defer { lock.unlock() }
    return _firstByteInstant
  }

  var reportCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _reports.count
  }
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

  @Test("Small-tier cold download throughput (gated)")
  func smallTierThroughput() async throws {
    // Gate: when ACERVO_PERF_TESTS is unset, no network call happens and no
    // [PERF] line is printed.
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }

    let modelId = smallModelId
    let slug = Acervo.slugify(modelId)

    // ----- Phase 1: fresh, residue-free temp SharedModels root -----
    let tempBase = try makeTempSharedModels()
    // Phase 4: teardown of the model dir and temp root.
    defer { cleanupTempDirectory(tempBase) }

    let modelDir = tempBase.appendingPathComponent(slug)
    // Fail if any residue exists for the target model — the measurement is
    // only meaningful from a cold, pristine container.
    let residueExists = FileManager.default.fileExists(atPath: modelDir.path)
    #expect(
      !residueExists,
      "Residue found at \(modelDir.path) — temp SharedModels root must be pristine for \(modelId)"
    )
    guard !residueExists else { return }

    // ----- Phase 2: timed download via the PUBLIC Acervo API -----
    // The clock spans the entire Acervo.download call — manifest fetch, byte
    // transfer, AND SHA-256 integrity verification — because verification is
    // part of the download per the suite charter (§1.1). The independent
    // on-disk correctness assertion (Phase 3) runs strictly AFTER the clock
    // stops, so it never inflates the measured wall time.
    let collector = PerfProgressCollector()
    let clock = ContinuousClock()

    let start = clock.now
    try await Acervo.download(
      modelId,
      files: [],  // [] == download everything declared in the manifest
      progress: { report in
        collector.record(report, at: clock.now)
      },
      in: tempBase
    )
    let end = clock.now
    // <<< CLOCK STOPS HERE. Everything below runs after the timed window. >>>

    let wallClockSeconds = perfSeconds(end - start)

    // ----- Phase 3: independent on-disk validation (OUTSIDE the clock) -----
    // Canonical {org}_{repo}/ layout must exist as a directory.
    var isDirectory: ObjCBool = false
    let dirExists = FileManager.default.fileExists(
      atPath: modelDir.path,
      isDirectory: &isDirectory
    )
    #expect(dirExists && isDirectory.boolValue, "Canonical model directory should exist at \(modelDir.path)")

    // config.json is the universal model-validity marker.
    let configPath = modelDir.appendingPathComponent("config.json")
    #expect(
      FileManager.default.fileExists(atPath: configPath.path),
      "config.json (validity marker) must be present at \(configPath.path)"
    )

    // The on-disk file set must match the manifest exactly. The manifest is the
    // sole authoritative source of what the model contains.
    let manifest = try await Acervo.fetchManifest(for: modelId)
    for file in manifest.files {
      let onDisk = modelDir.appendingPathComponent(file.path)
      #expect(
        FileManager.default.fileExists(atPath: onDisk.path),
        "Manifest file \(file.path) should exist on disk"
      )
    }

    // verifiedBytes is the authoritative total declared by the manifest — every
    // one of these bytes was SHA-256-verified inside the timed window.
    let verifiedBytes = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }

    // ----- Metrics -----
    let throughputMBps =
      wallClockSeconds > 0
      ? Double(verifiedBytes) / wallClockSeconds / 1_048_576
      : 0

    let timeToFirstByte: Double = {
      guard let firstByte = collector.firstByteInstant else { return 0 }
      return perfSeconds(firstByte - start)
    }()

    // ----- Run environment -----
    let net = ProcessInfo.processInfo.environment["ACERVO_PERF_NET"] ?? "unknown"
    let date = ISO8601DateFormatter().string(from: Date())
    let machine = perfMachineModel()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

    // ----- One compact, greppable summary line per measurement -----
    print(
      "[PERF] model=\(modelId)"
        + " bytes=\(verifiedBytes)"
        + " wall=\(String(format: "%.3f", wallClockSeconds))s"
        + " thru=\(String(format: "%.2f", throughputMBps))MB/s"
        + " ttfb=\(String(format: "%.3f", timeToFirstByte))s"
        + " cache=cold"
        + " chunked=on"
        + " container=temp"
        + " verified=yes"
        + " net=\(net)"
        + " date=\(date)"
        + " machine=\(machine)"
        + " os=\(osVersion)"
    )
  }
}
