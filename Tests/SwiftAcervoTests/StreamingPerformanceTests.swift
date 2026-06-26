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
      + " cache=cold"
      + " chunked=on"
      + " verified=yes"
      + " net=\(net)"
      + " date=\(date)"
      + " machine=\(machine)"
      + " os=\(osVersion)"
  )
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
    modelId: modelId, tier: tier, container: containerLabel,
    samples: samples, singleRun: false
  )
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
      modelId: largeModelId, tier: "large", container: containerLabel,
      samples: [sample], singleRun: true
    )
  }
}
