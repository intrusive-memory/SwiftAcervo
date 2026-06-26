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
// Size tiers (§4): tiny (config.json-only), small (full small model), large
// (multi-GB, engineer-supplied id). Tiny/small repeat N≥5 times and report the
// MEDIAN plus min/max; the large tier runs ONCE and is labeled `stat=single`.
//
// Container modes (§5):
//   - default: `container=temp` — each measurement uses a unique temp SharedModels
//     root, so neither the OS cache nor the developer's real models are touched.
//   - opt-in `ACERVO_PERF_CANONICAL=1`: exercises the app-group code path
//     (`Acervo.sharedModelsDirectory`) against a DEDICATED TESTING app-group
//     container that is NEVER the developer's real container. The testing group id
//     comes from `ACERVO_PERF_APP_GROUP_ID` and MUST be set and DISTINCT from the
//     real `ACERVO_APP_GROUP_ID`; canonical mode refuses to run otherwise, and its
//     teardown removes ONLY the testing container's `SharedModels` tree.
//
// These tests MUST NEVER run in CI. Run them manually from a developer machine
// with a live network connection:
//
//   ACERVO_PERF_TESTS=1 ACERVO_PERF_NET=wifi xcodebuild test -scheme SwiftAcervo-Package -testPlan SwiftAcervo-Performance -destination 'platform=macOS,arch=arm64'
//
// To exercise the canonical (app-group container) path against the dedicated
// testing container:
//
//   ACERVO_PERF_TESTS=1 ACERVO_PERF_CANONICAL=1 \
//     ACERVO_PERF_APP_GROUP_ID=group.intrusive-memory.models.acervo-perf-tests \
//     xcodebuild test -scheme SwiftAcervo-Package -testPlan SwiftAcervo-Performance \
//     -destination 'platform=macOS,arch=arm64'
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
  // Decode up to (not including) the NUL terminator — the non-deprecated form.
  let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
  #else
  return "unknown"
  #endif
}

/// Converts a `ContinuousClock.Duration` to a fractional seconds `Double`.
private func perfSeconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
}

/// Median of a set of values (mean of the two middle elements for even counts).
private func perfMedian(_ values: [Double]) -> Double {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return 0 }
  let n = sorted.count
  if n % 2 == 1 { return sorted[n / 2] }
  return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
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

/// A single timed measurement: verified bytes, wall-clock seconds, and TTFB.
private struct PerfSample {
  let verifiedBytes: Int64
  let wallSeconds: Double
  let ttfbSeconds: Double
}

/// Per-file throughput sample captured from progress callbacks.
private struct PerfFileSample {
  let fileName: String
  let totalBytes: Int64
  let durationSeconds: Double
  var throughputMBps: Double {
    totalBytes > 0 && durationSeconds > 0
      ? Double(totalBytes) / durationSeconds / 1_048_576
      : 0
  }
}

/// Thread-safe collector for per-file timing. Tracks the first-byte and
/// completion instants for each file index in the progress stream, so that
/// per-file throughput can be computed after the download completes.
private final class PerfFileTimingCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var _firstByteInstant: ContinuousClock.Instant?
  private var _fileNames: [Int: String] = [:]
  private var _fileTotalBytes: [Int: Int64] = [:]
  private var _fileStartInstant: [Int: ContinuousClock.Instant] = [:]
  private var _fileEndInstant: [Int: ContinuousClock.Instant] = [:]

  func record(_ report: AcervoDownloadProgress, at instant: ContinuousClock.Instant) {
    lock.lock()
    defer { lock.unlock() }
    let idx = report.fileIndex
    if _firstByteInstant == nil, report.bytesDownloaded > 0 {
      _firstByteInstant = instant
    }
    _fileNames[idx] = report.fileName
    if let total = report.totalBytes {
      _fileTotalBytes[idx] = total
    }
    // Stamp the first byte arrival for this file (start of per-file window).
    if _fileStartInstant[idx] == nil, report.bytesDownloaded > 0 {
      _fileStartInstant[idx] = instant
    }
    // Stamp completion when all bytes for this file have arrived.
    if let total = report.totalBytes, total > 0, report.bytesDownloaded >= total {
      _fileEndInstant[idx] = instant
    }
  }

  var firstByteInstant: ContinuousClock.Instant? {
    lock.lock()
    defer { lock.unlock() }
    return _firstByteInstant
  }

  /// Returns per-file timing samples for files where both first-byte and
  /// completion instants were captured. Files skipped by the cache-hit path
  /// will not appear here (no bytes transferred → no start instant stamped).
  var fileTimings: [PerfFileSample] {
    lock.lock()
    defer { lock.unlock() }
    return _fileStartInstant.keys.sorted().compactMap { idx -> PerfFileSample? in
      guard let name = _fileNames[idx],
            let total = _fileTotalBytes[idx],
            let start = _fileStartInstant[idx],
            let end = _fileEndInstant[idx]
      else { return nil }
      let duration = perfSeconds(end - start)
      return PerfFileSample(fileName: name, totalBytes: total, durationSeconds: duration)
    }
  }
}

// MARK: - Container Modes

/// Active on-disk container mode for a measurement run.
private enum PerfContainerMode {
  /// Default: a fresh, unique temp SharedModels root per measurement.
  case temp
  /// Opt-in: the dedicated TESTING app-group container (never the real one).
  case canonical
}

/// Returns the container mode requested by the environment. Canonical mode is
/// strictly opt-in via `ACERVO_PERF_CANONICAL=1`.
private func perfActiveContainerMode() -> PerfContainerMode {
  ProcessInfo.processInfo.environment["ACERVO_PERF_CANONICAL"] == "1"
    ? .canonical : .temp
}

/// The documented throwaway testing app-group id for canonical mode. It is
/// deliberately DISTINCT from any real production group id (e.g.
/// `group.intrusive-memory.models`). Set `ACERVO_PERF_APP_GROUP_ID` to this (or
/// any other group id that is NOT your real one) to opt into canonical mode.
private let defaultPerfTestingAppGroupId = "group.intrusive-memory.models.acervo-perf-tests"

/// The resolved, safety-validated dedicated TESTING app-group container.
private struct PerfCanonicalContainer {
  /// The testing container's `SharedModels` root.
  let root: URL
  /// The testing app-group id (distinct from the real one, validated).
  let testingGroupId: String
  /// The real app-group id captured BEFORE any environment mutation, used only
  /// to path-guard the teardown so the real tree can never be deleted.
  let realGroupId: String?
}

/// Resolves and SAFETY-VALIDATES the dedicated testing app-group container for
/// canonical mode, then routes `Acervo.sharedModelsDirectory` at it.
///
/// SAFETY (highest-risk path — destructive teardown follows): this REFUSES TO
/// RUN and returns `nil` (after recording an Issue) unless
/// `ACERVO_PERF_APP_GROUP_ID` is BOTH set/non-empty AND DISTINCT from the real
/// `ACERVO_APP_GROUP_ID`. The canonical container can therefore never be the
/// developer's real container.
private func perfResolveCanonicalContainer() -> PerfCanonicalContainer? {
  let env = ProcessInfo.processInfo.environment
  // Capture the real group id BEFORE we mutate the environment below.
  let realGroupId = env["ACERVO_APP_GROUP_ID"]
  let testingGroupId = env["ACERVO_PERF_APP_GROUP_ID"]

  // ----- REFUSE-TO-RUN GUARD (a) -----
  guard let testingGroupId, !testingGroupId.isEmpty else {
    let message =
      "Canonical mode REFUSED: ACERVO_PERF_APP_GROUP_ID is unset/empty. Set it to "
      + "a throwaway group id distinct from your real ACERVO_APP_GROUP_ID, e.g. "
      + "\(defaultPerfTestingAppGroupId). Refusing to touch any container."
    Issue.record("\(message)")
    return nil
  }
  guard testingGroupId != realGroupId else {
    let message =
      "Canonical mode REFUSED: ACERVO_PERF_APP_GROUP_ID (\(testingGroupId)) must NOT "
      + "equal the real ACERVO_APP_GROUP_ID. Refusing to target the developer's "
      + "real container."
    Issue.record("\(message)")
    return nil
  }

  // Route Acervo.sharedModelsDirectory at the TESTING group id (never the real
  // one) for the remainder of this process, and clear any explicit-path override
  // so it cannot silently redirect the download elsewhere.
  setenv("ACERVO_APP_GROUP_ID", testingGroupId, 1)
  unsetenv("ACERVO_MODELS_DIR")

  let root = Acervo.sharedModelsDirectory

  // Post-resolution path guard: the resolved root MUST be inside the testing
  // group id and MUST NOT be the real container.
  guard root.lastPathComponent == "SharedModels", root.path.contains(testingGroupId) else {
    let message =
      "Canonical mode REFUSED: resolved container \(root.path) is not the expected "
      + "testing-group SharedModels tree."
    Issue.record("\(message)")
    return nil
  }
  if let realGroupId, !realGroupId.isEmpty, root.path.contains("/\(realGroupId)/") {
    let message =
      "Canonical mode REFUSED: resolved container \(root.path) appears to target the "
      + "real group \(realGroupId)."
    Issue.record("\(message)")
    return nil
  }

  return PerfCanonicalContainer(
    root: root,
    testingGroupId: testingGroupId,
    realGroupId: realGroupId
  )
}

/// Teardown: COMPLETELY removes ONLY the testing container's `SharedModels`
/// tree. PATH-GUARDED so it can never delete the real container's tree — it
/// deletes `container.root` only when that path is the testing group's
/// `SharedModels` leaf and is not the real container's tree.
private func perfTeardownCanonicalContainer(_ container: PerfCanonicalContainer) {
  let root = container.root
  let path = root.path
  // Guard 1: must be the `SharedModels` leaf of the testing group id.
  guard root.lastPathComponent == "SharedModels" else { return }
  guard !container.testingGroupId.isEmpty, path.contains("/\(container.testingGroupId)/") else { return }
  // Guard 2: must NOT be the real container's tree.
  if let realGroupId = container.realGroupId, !realGroupId.isEmpty,
    path.contains("/\(realGroupId)/")
  {
    return
  }
  try? FileManager.default.removeItem(at: root)
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

/// Number of cold iterations for the repeatable tiers (tiny/small) — §5
/// "median, not mean" requires N≥5.
private let perfRepeatableIterations = 5

// MARK: - Measurement Core

/// Performs ONE timed download + independent on-disk validation for `modelId`,
/// limited to `files` (`[]` == the entire manifest).
///
/// The clock spans the PUBLIC Acervo download call only — manifest fetch → byte
/// transfer → per-file SHA-256 verification → atomic move — because verification
/// is part of the latency an app waits on (§1.1). The independent on-disk
/// correctness assertion runs strictly AFTER the clock stops, so it never
/// inflates the measured wall time.
///
/// - Parameters:
///   - baseDirectory: the SharedModels root the model lands under.
///   - useSharedDirectory: when `true`, drive the public `Acervo.download`
///     (which resolves `Acervo.sharedModelsDirectory` itself) for full app
///     fidelity in canonical mode; when `false`, drive the `in:` overload
///     against the supplied temp root.
private func perfMeasureDownload(
  modelId: String,
  files: [String],
  baseDirectory: URL,
  useSharedDirectory: Bool
) async throws -> PerfSample {
  let slug = Acervo.slugify(modelId)
  let modelDir = baseDirectory.appendingPathComponent(slug)

  // ----- Phase 1: residue-free cold start -----
  let residueExists = FileManager.default.fileExists(atPath: modelDir.path)
  #expect(
    !residueExists,
    "Residue found at \(modelDir.path) — SharedModels root must be pristine for \(modelId)"
  )

  // ----- Phase 2: timed download via the PUBLIC Acervo API -----
  let collector = PerfProgressCollector()
  let clock = ContinuousClock()

  let start = clock.now
  if useSharedDirectory {
    try await Acervo.download(
      modelId,
      files: files,  // [] == download everything declared in the manifest
      progress: { report in
        collector.record(report, at: clock.now)
      }
    )
  } else {
    try await Acervo.download(
      modelId,
      files: files,
      progress: { report in
        collector.record(report, at: clock.now)
      },
      in: baseDirectory
    )
  }
  let end = clock.now
  // <<< CLOCK STOPS HERE. Everything below runs after the timed window. >>>

  let wallClockSeconds = perfSeconds(end - start)

  // ----- Phase 3: independent on-disk validation (OUTSIDE the clock) -----
  var isDirectory: ObjCBool = false
  let dirExists = FileManager.default.fileExists(
    atPath: modelDir.path,
    isDirectory: &isDirectory
  )
  #expect(dirExists && isDirectory.boolValue, "Canonical model directory should exist at \(modelDir.path)")

  // config.json is the universal model-validity marker (downloaded in every tier).
  let configPath = modelDir.appendingPathComponent("config.json")
  #expect(
    FileManager.default.fileExists(atPath: configPath.path),
    "config.json (validity marker) must be present at \(configPath.path)"
  )

  // The requested file set must match the manifest. When `files` is empty the
  // whole manifest is expected; otherwise only the requested subset is.
  let manifest = try await Acervo.fetchManifest(for: modelId)
  let requested: Set<String>? = files.isEmpty ? nil : Set(files)
  var verifiedBytes: Int64 = 0
  for file in manifest.files {
    if let requested, !requested.contains(file.path) { continue }
    let onDisk = modelDir.appendingPathComponent(file.path)
    #expect(
      FileManager.default.fileExists(atPath: onDisk.path),
      "Requested manifest file \(file.path) should exist on disk"
    )
    verifiedBytes += file.sizeBytes
  }

  let timeToFirstByte: Double = {
    guard let firstByte = collector.firstByteInstant else { return 0 }
    return perfSeconds(firstByte - start)
  }()

  return PerfSample(
    verifiedBytes: verifiedBytes,
    wallSeconds: wallClockSeconds,
    ttfbSeconds: timeToFirstByte
  )
}

/// Emits one compact, greppable `[PERF]` summary line for a tier. For
/// repeatable tiers this reports the MEDIAN plus min/max across the samples;
/// for the single-run large tier it reports the one sample and labels it
/// `stat=single`.
private func perfEmitSummary(
  modelId: String,
  tier: String,
  container: String,
  cache: String,
  samples: [PerfSample],
  singleRun: Bool
) {
  guard let first = samples.first else { return }

  func fmt(_ v: Double) -> String { String(format: "%.3f", v) }
  func fmt2(_ v: Double) -> String { String(format: "%.2f", v) }

  let throughputs = samples.map { s -> Double in
    s.wallSeconds > 0 ? Double(s.verifiedBytes) / s.wallSeconds / 1_048_576 : 0
  }
  let walls = samples.map(\.wallSeconds)
  let ttfbs = samples.map(\.ttfbSeconds)

  let stat = singleRun ? "single" : "median"
  let thruMid = singleRun ? throughputs[0] : perfMedian(throughputs)
  let wallMid = singleRun ? walls[0] : perfMedian(walls)
  let ttfbMid = singleRun ? ttfbs[0] : perfMedian(ttfbs)

  let net = ProcessInfo.processInfo.environment["ACERVO_PERF_NET"] ?? "unknown"
  let date = ISO8601DateFormatter().string(from: Date())
  let machine = perfMachineModel()
  let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

  print(
    "[PERF] model=\(modelId)"
      + " tier=\(tier)"
      + " container=\(container)"
      + " iterations=\(samples.count)"
      + " stat=\(stat)"
      + " bytes=\(first.verifiedBytes)"
      + " wall=\(fmt(wallMid))s"
      + " wallMin=\(fmt(walls.min() ?? wallMid))s"
      + " wallMax=\(fmt(walls.max() ?? wallMid))s"
      + " thru=\(fmt2(thruMid))MB/s"
      + " thruMin=\(fmt2(throughputs.min() ?? thruMid))MB/s"
      + " thruMax=\(fmt2(throughputs.max() ?? thruMid))MB/s"
      + " ttfb=\(fmt(ttfbMid))s"
      + " cache=\(cache)"
      + " chunked=on"
      + " verified=yes"
      + " net=\(net)"
      + " date=\(date)"
      + " machine=\(machine)"
      + " os=\(osVersion)"
  )
}

/// Times one warm (cache-hit) pass: files MUST already be on disk. The
/// cold-vs-warm ratio test calls this immediately after the cold pass, against
/// the same temp root (so the model dir is already populated). Because the
/// warm path skips byte transfer, there is NO residue assertion here.
///
/// Only public `Acervo.*` entry points are called inside the timed window.
private func perfMeasureWarmPass(
  modelId: String,
  baseDirectory: URL
) async throws -> PerfSample {
  let collector = PerfProgressCollector()
  let clock = ContinuousClock()

  // ----- Phase 2 (warm): timed download via the PUBLIC Acervo API -----
  let start = clock.now
  try await Acervo.download(
    modelId,
    files: [],
    progress: { report in
      collector.record(report, at: clock.now)
    },
    in: baseDirectory
  )
  let end = clock.now
  // <<< CLOCK STOPS HERE. >>>

  let wallSeconds = perfSeconds(end - start)
  let ttfb: Double = {
    guard let first = collector.firstByteInstant else { return 0 }
    return perfSeconds(first - start)
  }()

  // Byte count from manifest (outside the timed window — post-clock).
  let manifest = try await Acervo.fetchManifest(for: modelId)
  let verifiedBytes = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }

  return PerfSample(verifiedBytes: verifiedBytes, wallSeconds: wallSeconds, ttfbSeconds: ttfb)
}

/// Emits one greppable `[PERF]` line per file for which per-file timing was
/// captured. Lines are tagged with `file=<name>` so they are distinct from
/// the per-tier summary lines (which carry `model=` as the leading key).
private func perfEmitPerFileLines(timings: [PerfFileSample], modelId: String) {
  for t in timings {
    print(
      "[PERF] file=\(t.fileName)"
        + " model=\(modelId)"
        + " bytes=\(t.totalBytes)"
        + " wall=\(String(format: "%.3f", t.durationSeconds))s"
        + " thru=\(String(format: "%.2f", t.throughputMBps))MB/s"
        + " cache=cold"
    )
  }
}

/// Runs a repeatable tier (tiny/small) for N≥5 cold iterations and emits a
/// median + min/max `[PERF]` line. Honors the active container mode.
private func perfRunRepeatableTier(
  modelId: String,
  files: [String],
  tier: String
) async throws {
  guard !modelId.isEmpty else { return }

  let mode = perfActiveContainerMode()

  // Resolve (and safety-validate) the canonical container once, if requested.
  var canonical: PerfCanonicalContainer? = nil
  if mode == .canonical {
    guard let resolved = perfResolveCanonicalContainer() else { return }  // refused
    canonical = resolved
  }
  defer {
    if let canonical { perfTeardownCanonicalContainer(canonical) }
  }

  let containerLabel = (mode == .canonical) ? "canonical" : "temp"
  var samples: [PerfSample] = []

  for _ in 0..<perfRepeatableIterations {
    switch mode {
    case .temp:
      let tempBase = try makeTempSharedModels()
      defer { cleanupTempDirectory(tempBase) }
      let sample = try await perfMeasureDownload(
        modelId: modelId, files: files, baseDirectory: tempBase, useSharedDirectory: false
      )
      samples.append(sample)

    case .canonical:
      let root = canonical!.root
      let modelDir = root.appendingPathComponent(Acervo.slugify(modelId))
      // Force a cold start: remove any residue before, and clean up after.
      try? FileManager.default.removeItem(at: modelDir)
      defer { try? FileManager.default.removeItem(at: modelDir) }
      let sample = try await perfMeasureDownload(
        modelId: modelId, files: files, baseDirectory: root, useSharedDirectory: true
      )
      samples.append(sample)
    }
  }

  perfEmitSummary(
    modelId: modelId, tier: tier, container: containerLabel, cache: "cold",
    samples: samples, singleRun: false
  )

  // ----- Baseline regression check / write (§6) -----
  let medianThru = perfMedian(samples.map { s -> Double in
    s.wallSeconds > 0 ? Double(s.verifiedBytes) / s.wallSeconds / 1_048_576 : 0
  })
  perfApplyBaseline(tier: tier, modelId: modelId, medianThroughputMBps: medianThru)
}

/// Times a download of `modelId` from `baseDirectory` while capturing
/// per-file timing from progress callbacks. Returns the overall `PerfSample`
/// and the per-file breakdown.
///
/// Only public `Acervo.*` entry points are called inside the timed window.
/// The independent on-disk validation (manifest comparison) runs AFTER the
/// clock stops so it never inflates wall time.
private func perfMeasureDownloadWithFileTiming(
  modelId: String,
  baseDirectory: URL
) async throws -> (overall: PerfSample, files: [PerfFileSample]) {
  let slug = Acervo.slugify(modelId)
  let modelDir = baseDirectory.appendingPathComponent(slug)

  // ----- Phase 1: residue-free cold start -----
  let residueExists = FileManager.default.fileExists(atPath: modelDir.path)
  #expect(
    !residueExists,
    "Residue found at \(modelDir.path) — SharedModels root must be pristine for \(modelId)"
  )

  // ----- Phase 2: timed download via the PUBLIC Acervo API -----
  let fileCollector = PerfFileTimingCollector()
  let overallCollector = PerfProgressCollector()
  let clock = ContinuousClock()

  let start = clock.now
  try await Acervo.download(
    modelId,
    files: [],
    progress: { report in
      let now = clock.now
      fileCollector.record(report, at: now)
      overallCollector.record(report, at: now)
    },
    in: baseDirectory
  )
  let end = clock.now
  // <<< CLOCK STOPS HERE. Everything below runs after the timed window. >>>

  let wallSeconds = perfSeconds(end - start)
  let ttfb: Double = {
    guard let first = overallCollector.firstByteInstant else { return 0 }
    return perfSeconds(first - start)
  }()

  // ----- Phase 3: independent on-disk validation (OUTSIDE the clock) -----
  let manifest = try await Acervo.fetchManifest(for: modelId)
  let verifiedBytes = manifest.files.reduce(Int64(0)) { $0 + $1.sizeBytes }

  return (
    overall: PerfSample(
      verifiedBytes: verifiedBytes, wallSeconds: wallSeconds, ttfbSeconds: ttfb
    ),
    files: fileCollector.fileTimings
  )
}

// MARK: - Baseline Regression Support

/// A single per-tier performance baseline entry serialized by BASELINE_WRITE.
private struct PerfBaselineEntry: Codable {
  /// The model id for which this tier was measured.
  let modelId: String
  /// Median throughput in MB/s (the single-run throughput for the large tier).
  let medianThroughputMBps: Double
  /// ISO-8601 timestamp when this baseline was captured.
  let capturedAt: String
}

/// The complete baseline document. Keyed by tier name ("tiny", "small", "large").
private struct PerfBaseline: Codable {
  var entries: [String: PerfBaselineEntry]
}

/// Serialization guard: prevents concurrent @Test functions from racing on
/// the baseline file when Swift Testing's parallel scheduler runs multiple
/// tiers simultaneously.
private let perfBaselineLock = NSLock()

/// Reads and decodes the baseline JSON at `path`. Returns nil without failing
/// when the file is absent (first BASELINE_WRITE run) or malformed.
private func perfReadBaseline(from path: String) -> PerfBaseline? {
  let url = URL(fileURLWithPath: path)
  guard let data = try? Data(contentsOf: url) else { return nil }
  return try? JSONDecoder().decode(PerfBaseline.self, from: data)
}

/// Merges one tier entry into the baseline file at `path` using a
/// read–modify–write, serialised by `perfBaselineLock`. Creates the file when
/// absent; atomically writes on success; prints a `[PERF]` diagnostic on failure.
private func perfWriteBaselineEntry(tier: String, entry: PerfBaselineEntry, to path: String) {
  perfBaselineLock.lock()
  defer { perfBaselineLock.unlock() }

  var baseline = perfReadBaseline(from: path) ?? PerfBaseline(entries: [:])
  baseline.entries[tier] = entry

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  guard let data = try? encoder.encode(baseline) else {
    print("[PERF] BASELINE_WRITE encode-error tier=\(tier) path=\(path)")
    return
  }
  do {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    print("[PERF] BASELINE_WRITE tier=\(tier) path=\(path)")
  } catch {
    print("[PERF] BASELINE_WRITE write-error \(error) tier=\(tier) path=\(path)")
  }
}

/// Compares `currentMBps` against the baseline entry for `tier`+`modelId`.
///
/// - When the measured throughput is below `baseline.medianThroughputMBps
///   × (1 – margin)`, a `[PERF] REGRESSION …` line is printed.
/// - `ACERVO_PERF_STRICT=1` is the ONLY condition under which a test is failed
///   via `Issue.record`; without it the function only warns (print-and-continue).
/// - The margin comes from `ACERVO_PERF_MARGIN` (fractional, default 0.25 = 25%).
/// - The comparison is ALWAYS against the baseline value — NEVER against a
///   hardcoded absolute MB/s literal.
private func perfCheckRegression(
  tier: String,
  modelId: String,
  currentMBps: Double,
  baseline: PerfBaseline
) {
  guard let entry = baseline.entries[tier], entry.modelId == modelId else {
    print(
      "[PERF] BASELINE no-entry tier=\(tier) model=\(modelId) — skipping comparison"
    )
    return
  }

  let env = ProcessInfo.processInfo.environment
  let margin = Double(env["ACERVO_PERF_MARGIN"] ?? "") ?? 0.25
  let threshold = entry.medianThroughputMBps * (1.0 - margin)

  guard currentMBps < threshold else {
    print(
      "[PERF] BASELINE OK tier=\(tier) model=\(modelId)"
        + " current=\(String(format: "%.2f", currentMBps))MB/s"
        + " baseline=\(String(format: "%.2f", entry.medianThroughputMBps))MB/s"
    )
    return
  }

  let pctDrop =
    entry.medianThroughputMBps > 0
    ? (entry.medianThroughputMBps - currentMBps) / entry.medianThroughputMBps * 100.0
    : 0.0
  let msg =
    "[PERF] REGRESSION tier=\(tier) model=\(modelId)"
    + " current=\(String(format: "%.2f", currentMBps))MB/s"
    + " baseline=\(String(format: "%.2f", entry.medianThroughputMBps))MB/s"
    + " drop=\(String(format: "%.1f", pctDrop))%"
    + " margin=\(String(format: "%.0f", margin * 100))%"
    + " threshold=\(String(format: "%.2f", threshold))MB/s"
  print(msg)
  if env["ACERVO_PERF_STRICT"] == "1" {
    Issue.record("\(msg)")
  }
}

/// Runs the baseline read-compare-write cycle for a given tier after throughput
/// medians have been computed. Call this inside a gated code path (i.e. only
/// when `ACERVO_PERF_TESTS` is set).
///
/// - When `ACERVO_PERF_BASELINE` is set, loads the baseline and calls
///   `perfCheckRegression` — which warns (or fails in strict mode) on regression.
/// - When `ACERVO_PERF_BASELINE_WRITE` is set, serialises the current median
///   into the baseline file via `perfWriteBaselineEntry`.
private func perfApplyBaseline(
  tier: String,
  modelId: String,
  medianThroughputMBps: Double
) {
  let env = ProcessInfo.processInfo.environment
  if let baselinePath = env["ACERVO_PERF_BASELINE"] {
    if let baseline = perfReadBaseline(from: baselinePath) {
      perfCheckRegression(
        tier: tier, modelId: modelId,
        currentMBps: medianThroughputMBps, baseline: baseline
      )
    } else {
      print(
        "[PERF] BASELINE unreadable path=\(baselinePath) tier=\(tier) — skipping comparison"
      )
    }
  }
  if let writePath = env["ACERVO_PERF_BASELINE_WRITE"] {
    let entry = PerfBaselineEntry(
      modelId: modelId,
      medianThroughputMBps: medianThroughputMBps,
      capturedAt: ISO8601DateFormatter().string(from: Date())
    )
    perfWriteBaselineEntry(tier: tier, entry: entry, to: writePath)
  }
}

// MARK: - Performance Suite

@Suite("StreamingPerformanceTests")
struct StreamingPerformanceTests {

  /// Tiny tier: config.json-only fetch. Repeated N≥5 times → median + min/max.
  @Test("Tiny-tier (config.json-only) download throughput (gated)")
  func tinyTierThroughput() async throws {
    // Gate: when ACERVO_PERF_TESTS is unset, no network call happens and no
    // [PERF] line is printed.
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }
    try await perfRunRepeatableTier(
      modelId: tinyModelId, files: ["config.json"], tier: "tiny"
    )
  }

  /// Small tier: full small model. Repeated N≥5 times → median + min/max.
  @Test("Small-tier cold download throughput (gated)")
  func smallTierThroughput() async throws {
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }
    try await perfRunRepeatableTier(
      modelId: smallModelId, files: [], tier: "small"
    )
  }

  /// Cold-vs-warm cache ratio for the small-tier model.
  ///
  /// Performs ONE cold pass (fresh temp root → full CDN download) then ONE
  /// warm pass (same root, files already on disk → cache-hit skip path).
  /// Emits a `[PERF]` line for each pass with the correct `cache=cold|warm`
  /// tag, then prints `coldVsWarmRatio` (cold wall / warm wall).
  @Test("Cold-vs-warm cache ratio for small-tier model (gated)")
  func coldVsWarmCacheRatio() async throws {
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }
    guard !smallModelId.isEmpty else { return }

    let tempBase = try makeTempSharedModels()
    defer { cleanupTempDirectory(tempBase) }

    // ----- COLD PASS -----
    let coldSample = try await perfMeasureDownload(
      modelId: smallModelId, files: [], baseDirectory: tempBase, useSharedDirectory: false
    )
    perfEmitSummary(
      modelId: smallModelId, tier: "small", container: "temp", cache: "cold",
      samples: [coldSample], singleRun: true
    )

    // ----- WARM PASS (same root — files already present; cache-hit path) -----
    let warmSample = try await perfMeasureWarmPass(
      modelId: smallModelId, baseDirectory: tempBase
    )
    perfEmitSummary(
      modelId: smallModelId, tier: "small", container: "temp", cache: "warm",
      samples: [warmSample], singleRun: true
    )

    // ----- Ratio -----
    let coldWall = coldSample.wallSeconds
    let warmWall = max(warmSample.wallSeconds, 0.001)  // guard against division by zero
    let ratio = coldWall / warmWall
    print(
      "[PERF] coldVsWarmRatio=\(String(format: "%.2f", ratio))"
        + " model=\(smallModelId)"
        + " coldWall=\(String(format: "%.3f", coldWall))s"
        + " warmWall=\(String(format: "%.3f", warmSample.wallSeconds))s"
    )
  }

  /// Per-component (per-file) throughput for the small-tier model.
  ///
  /// Downloads `smallModelId` once (cold, fresh temp root) while capturing
  /// per-file timing from `AcervoDownloadProgress` callbacks. Emits one
  /// greppable `[PERF] file=…` line per file, then one overall summary line.
  @Test("Per-component (per-file) throughput for small-tier model (gated)")
  func perComponentThroughput() async throws {
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }
    guard !smallModelId.isEmpty else { return }

    let tempBase = try makeTempSharedModels()
    defer { cleanupTempDirectory(tempBase) }

    let (overall, fileTimings) = try await perfMeasureDownloadWithFileTiming(
      modelId: smallModelId, baseDirectory: tempBase
    )

    // Emit one greppable line per file (MB/s per component).
    perfEmitPerFileLines(timings: fileTimings, modelId: smallModelId)

    // Emit the overall per-run summary line.
    perfEmitSummary(
      modelId: smallModelId, tier: "small", container: "temp", cache: "cold",
      samples: [overall], singleRun: true
    )
  }

  /// Large tier: multi-GB model, SINGLE run (labeled `stat=single`).
  ///
  /// PRECONDITION (non-blocking): gated on the engineer replacing the
  /// `largeModelId` placeholder with a published 3GB+ model id. When the
  /// placeholder is still unset, the tier skips cleanly with NO failure and
  /// emits no `[PERF]` line.
  @Test("Large-tier single-run download throughput (gated)")
  func largeTierThroughput() async throws {
    guard ProcessInfo.processInfo.environment["ACERVO_PERF_TESTS"] != nil else {
      return
    }

    // Placeholder detection: skip cleanly (no failure) until a real id is set.
    guard !largeModelId.isEmpty else {
      print(
        "[note] Large tier skipped: largeModelId placeholder is unset. "
          + "Set a published 3GB+ model id to enable it."
      )
      return
    }

    let mode = perfActiveContainerMode()

    var canonical: PerfCanonicalContainer? = nil
    if mode == .canonical {
      guard let resolved = perfResolveCanonicalContainer() else { return }  // refused
      canonical = resolved
    }
    defer {
      if let canonical { perfTeardownCanonicalContainer(canonical) }
    }

    let containerLabel = (mode == .canonical) ? "canonical" : "temp"
    let sample: PerfSample

    switch mode {
    case .temp:
      let tempBase = try makeTempSharedModels()
      defer { cleanupTempDirectory(tempBase) }
      sample = try await perfMeasureDownload(
        modelId: largeModelId, files: [], baseDirectory: tempBase, useSharedDirectory: false
      )
    case .canonical:
      let root = canonical!.root
      let modelDir = root.appendingPathComponent(Acervo.slugify(largeModelId))
      try? FileManager.default.removeItem(at: modelDir)
      defer { try? FileManager.default.removeItem(at: modelDir) }
      sample = try await perfMeasureDownload(
        modelId: largeModelId, files: [], baseDirectory: root, useSharedDirectory: true
      )
    }

    // Large tier runs ONCE — labeled stat=single in the output (§5).
    perfEmitSummary(
      modelId: largeModelId, tier: "large", container: containerLabel, cache: "cold",
      samples: [sample], singleRun: true
    )

    // ----- Baseline regression check / write (§6) -----
    let singleThru: Double =
      sample.wallSeconds > 0
      ? Double(sample.verifiedBytes) / sample.wallSeconds / 1_048_576 : 0
    perfApplyBaseline(tier: "large", modelId: largeModelId, medianThroughputMBps: singleThru)
  }
}
