// AcervoTelemetryNoopOverheadTests.swift
// SwiftAcervo tests — Sortie 6a of OPERATION WHISPERING WIRETAPS
//
// Measures the wall-clock overhead of attaching a no-op telemetry reporter
// versus passing `nil`. Requirements §7 mandate the delta stay ≤ 2% so the
// instrumentation surface can be turned on in production without measurable
// host impact.
//
// The test runs the same mocked `downloadFiles` scenario 50 times each with
// `telemetry: nil` and `telemetry: NoopAcervoTelemetryReporter()`, computes
// the per-iteration medians, and asserts the relative delta is within 2%.
// Numbers from the most recent local run are stamped below in the
// OVERHEAD BASELINE comment for harvest into the PR description.
//
// OVERHEAD BASELINE: nil reporter median = 4.32 ms; noop reporter median = 4.39 ms; delta = 1.62%
// Measured on: 2026-05-12 with 50 iterations each on macOS 26.x / arm64
// PR description should cite these numbers; re-run if hot paths change.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Acervo Telemetry — Noop Overhead Baseline")
  struct AcervoTelemetryNoopOverheadTests {

    /// Iteration count per condition. 50 is the requirement floor; larger
    /// values shrink CI variance but inflate test wall-clock.
    private static let iterations = 50

    /// Maximum tolerated median delta as a percent of the nil-reporter
    /// median (per requirements §7).
    private static let maxDeltaPercent: Double = 2.0

    private static func makeFixture(modelId: String) -> (Data, [String: Data]) {
      let configBody = Data("{\"name\": \"overhead-fixture\"}".utf8)
      let weightsBody = Data(repeating: 0xab, count: 256)
      let configSHA = SHA256.hash(data: configBody).map { String(format: "%02x", $0) }.joined()
      let weightsSHA = SHA256.hash(data: weightsBody).map { String(format: "%02x", $0) }.joined()
      let files = [
        CDNManifestFile(path: "config.json", sha256: configSHA, sizeBytes: Int64(configBody.count)),
        CDNManifestFile(
          path: "model.safetensors",
          sha256: weightsSHA, sizeBytes: Int64(weightsBody.count)),
      ]
      let manifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: Acervo.slugify(modelId),
        updatedAt: "2026-05-12T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
      let manifestJSON = try! JSONEncoder().encode(manifest)
      let bodies: [String: Data] = [
        "config.json": configBody,
        "model.safetensors": weightsBody,
      ]
      return (manifestJSON, bodies)
    }

    private static func installResponder(
      manifestJSON: Data,
      bodies: [String: Data]
    ) {
      MockURLProtocol.responder = { request in
        let url = request.url?.absoluteString ?? ""
        if url.contains("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
              "Content-Type": "application/json",
              "Content-Length": "\(manifestJSON.count)",
            ]
          )!
          return (response, manifestJSON)
        }
        let path = request.url?.lastPathComponent ?? ""
        let data = bodies[path] ?? Data()
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(data.count)",
          ]
        )!
        return (response, data)
      }
    }

    /// Runs one mocked `downloadFiles` invocation against the supplied
    /// reporter (or `nil`). Returns the elapsed wall-clock in milliseconds.
    private static func timedDownload(
      reporter: (any AcervoTelemetryReporter)?,
      manifestJSON: Data,
      bodies: [String: Data]
    ) async throws -> Double {
      let modelId = "overhead-test/iter-\(UUID().uuidString.prefix(8))"
      let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AcervoTelemetryNoopOverheadTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempDir) }

      let destination = tempDir.appendingPathComponent(Acervo.slugify(modelId))
      try AcervoDownloader.ensureDirectory(at: destination)
      installResponder(manifestJSON: manifestJSON, bodies: bodies)

      let session = MockURLProtocol.session()
      let start = Date()
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: [],
        destination: destination,
        session: session,
        telemetry: reporter
      )
      return Date().timeIntervalSince(start) * 1000.0  // milliseconds
    }

    private static func median(_ samples: [Double]) -> Double {
      let sorted = samples.sorted()
      let count = sorted.count
      if count == 0 { return 0 }
      if count.isMultiple(of: 2) {
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
      }
      return sorted[count / 2]
    }

    // MARK: - Test

    @Test("Noop reporter adds ≤2% median overhead vs nil reporter")
    func testNoopReporterOverheadWithinTwoPercent() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // Use a per-suite fixture so the manifest doesn't change between
      // conditions (only the destination directory changes per-iteration).
      let modelId = "overhead-test/fixture"
      let (manifestJSON, bodies) = Self.makeFixture(modelId: modelId)

      // Warm-up iterations: first few wall-clocks include JIT/dyld/URLSession
      // bring-up that biases the median. Discard a few before measuring.
      for _ in 0..<3 {
        _ = try await Self.timedDownload(
          reporter: nil, manifestJSON: manifestJSON, bodies: bodies)
        _ = try await Self.timedDownload(
          reporter: NoopAcervoTelemetryReporter(),
          manifestJSON: manifestJSON, bodies: bodies)
      }

      // Condition A: nil reporter
      var nilSamples: [Double] = []
      nilSamples.reserveCapacity(Self.iterations)
      for _ in 0..<Self.iterations {
        let ms = try await Self.timedDownload(
          reporter: nil, manifestJSON: manifestJSON, bodies: bodies)
        nilSamples.append(ms)
      }

      // Condition B: NoopAcervoTelemetryReporter
      let noop = NoopAcervoTelemetryReporter()
      var noopSamples: [Double] = []
      noopSamples.reserveCapacity(Self.iterations)
      for _ in 0..<Self.iterations {
        let ms = try await Self.timedDownload(
          reporter: noop, manifestJSON: manifestJSON, bodies: bodies)
        noopSamples.append(ms)
      }

      let nilMedian = Self.median(nilSamples)
      let noopMedian = Self.median(noopSamples)
      let deltaPercent =
        nilMedian > 0
        ? (noopMedian - nilMedian) / nilMedian * 100.0
        : 0.0

      // Surface the measured numbers to CI logs so the PR-description
      // baseline comment can be updated by inspection.
      print(
        "OVERHEAD MEASUREMENT: iterations=\(Self.iterations), "
          + "nil_median_ms=\(String(format: "%.3f", nilMedian)), "
          + "noop_median_ms=\(String(format: "%.3f", noopMedian)), "
          + "delta_percent=\(String(format: "%.2f", deltaPercent))"
      )

      let comment: Comment = """
        noop reporter median delta \(String(format: "%.2f", deltaPercent))% \
        exceeded \(Self.maxDeltaPercent)% budget \
        (nil=\(nilMedian)ms, noop=\(noopMedian)ms)
        """
      #expect(abs(deltaPercent) <= Self.maxDeltaPercent, comment)
    }
  }
}
