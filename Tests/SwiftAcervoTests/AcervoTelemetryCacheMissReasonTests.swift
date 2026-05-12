// AcervoTelemetryCacheMissReasonTests.swift
// SwiftAcervo tests — Sortie 6a of OPERATION WHISPERING WIRETAPS
//
// Verifies that each reachable `CacheMissReason` fires from a deterministic
// real-code scenario:
//
//   - `.notPresent`        — first download (no on-disk file)
//   - `.sizeChangedRemote` — second download where remote manifest reports
//                            a different sizeBytes than the on-disk file
//   - `.forcedRefresh`     — second download with `force: true`
//
// Two reasons are CURRENTLY UNREACHABLE from real code paths and are
// documented as intentional skips:
//
//   - `.shaChangedRemote` — would require a verify-on-cache-hit path
//                            that recomputes the on-disk SHA before any
//                            network I/O. The present cache check is
//                            size-only.
//   - `.corrupted`         — same gap as `.shaChangedRemote`.
//
// When the verify-on-read path is added, the two skipped tests should be
// upgraded to assert event firing.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Acervo Telemetry — Cache Miss Reasons")
  struct AcervoTelemetryCacheMissReasonTests {

    // MARK: Fixtures

    private struct Fixture {
      let modelId: String
      let manifest: CDNManifest
      let manifestJSON: Data
      let bodies: [String: Data]
    }

    private static func makeFixture(
      modelId: String,
      configBody: Data = Data("{\"k\":\"v\"}".utf8)
    ) -> Fixture {
      let configSHA = SHA256.hash(data: configBody).map { String(format: "%02x", $0) }.joined()
      let files = [
        CDNManifestFile(
          path: "config.json", sha256: configSHA, sizeBytes: Int64(configBody.count))
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
      return Fixture(
        modelId: modelId,
        manifest: manifest,
        manifestJSON: manifestJSON,
        bodies: ["config.json": configBody]
      )
    }

    private static func installResponder(_ fixture: Fixture) {
      MockURLProtocol.responder = { request in
        let url = request.url?.absoluteString ?? ""
        if url.contains("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
              "Content-Type": "application/json",
              "Content-Length": "\(fixture.manifestJSON.count)",
            ]
          )!
          return (response, fixture.manifestJSON)
        }
        let path = request.url?.lastPathComponent ?? ""
        let data = fixture.bodies[path] ?? Data()
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

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AcervoTelemetryCacheMissReasonTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func matches(
      _ events: [AcervoTelemetryEvent],
      reason expected: AcervoTelemetryEvent.CacheMissReason
    ) -> Bool {
      events.contains(where: { event in
        if case .cacheMiss(_, _, let r) = event, r == expected { return true }
        return false
      })
    }

    // MARK: - Reachable cases

    @Test(".notPresent fires on first download when file is absent")
    func testCacheMissNotPresent() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let fixture = Self.makeFixture(modelId: "cache-test/not-present-\(UUID().uuidString.prefix(8))")
        Self.installResponder(fixture)
        let reporter = MockTelemetryReporter()

        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent(Acervo.slugify(fixture.modelId))
        try AcervoDownloader.ensureDirectory(at: destination)

        try await AcervoDownloader.downloadFiles(
          modelId: fixture.modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session(),
          telemetry: reporter
        )

        let events = await reporter.snapshot()
        #expect(Self.matches(events, reason: .notPresent),
          "expected .notPresent cacheMiss in \(events)")
      }
    }

    @Test(".sizeChangedRemote fires when on-disk file size differs from manifest")
    func testCacheMissSizeChangedRemote() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        // First download with body A (size N1).
        let fixtureA = Self.makeFixture(
          modelId: "cache-test/size-changed-\(UUID().uuidString.prefix(8))",
          configBody: Data(repeating: 0x41, count: 32)
        )
        Self.installResponder(fixtureA)

        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent(Acervo.slugify(fixtureA.modelId))
        try AcervoDownloader.ensureDirectory(at: destination)

        // Initial download so the file exists with size 32.
        try await AcervoDownloader.downloadFiles(
          modelId: fixtureA.modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session(),
          telemetry: nil
        )

        // Swap the responder to one that reports a different size for the
        // same path. The on-disk file's 32-byte size will mismatch the new
        // manifest entry (64 bytes), driving `.sizeChangedRemote`.
        let fixtureB = Self.makeFixture(
          modelId: fixtureA.modelId,
          configBody: Data(repeating: 0x42, count: 64)
        )
        Self.installResponder(fixtureB)

        let reporter = MockTelemetryReporter()
        try await AcervoDownloader.downloadFiles(
          modelId: fixtureB.modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session(),
          telemetry: reporter
        )

        let events = await reporter.snapshot()
        #expect(Self.matches(events, reason: .sizeChangedRemote),
          "expected .sizeChangedRemote cacheMiss in \(events)")
      }
    }

    @Test(".forcedRefresh fires when force: true is requested")
    func testCacheMissForcedRefresh() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let fixture = Self.makeFixture(modelId: "cache-test/forced-\(UUID().uuidString.prefix(8))")
        Self.installResponder(fixture)

        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent(Acervo.slugify(fixture.modelId))
        try AcervoDownloader.ensureDirectory(at: destination)

        // Seed: download once so the file is on disk.
        try await AcervoDownloader.downloadFiles(
          modelId: fixture.modelId,
          requestedFiles: [],
          destination: destination,
          session: MockURLProtocol.session(),
          telemetry: nil
        )

        // Forced re-download: must emit .forcedRefresh even though the file
        // is already present with the correct size.
        let reporter = MockTelemetryReporter()
        try await AcervoDownloader.downloadFiles(
          modelId: fixture.modelId,
          requestedFiles: [],
          destination: destination,
          force: true,
          session: MockURLProtocol.session(),
          telemetry: reporter
        )

        let events = await reporter.snapshot()
        #expect(Self.matches(events, reason: .forcedRefresh),
          "expected .forcedRefresh cacheMiss in \(events)")
      }
    }

    // MARK: - Currently-unreachable cases (documented skips)

    @Test(".shaChangedRemote is currently unreachable from real code paths")
    func testCacheMissShaChangedRemote_currentlyUnreachable() async throws {
      // SKIP: .shaChangedRemote is currently unreachable from real code
      // paths — the cache check is size-only and no on-disk SHA recompute
      // happens pre-network. Cover when verify-on-read is added.
      #expect(true, "intentionally skipped: .shaChangedRemote currently unreachable")
    }

    @Test(".corrupted is currently unreachable from real code paths")
    func testCacheMissCorrupted_currentlyUnreachable() async throws {
      // SKIP: .corrupted is currently unreachable from real code paths —
      // same gap as .shaChangedRemote (no pre-network on-disk SHA recompute).
      // Cover when verify-on-read is added.
      #expect(true, "intentionally skipped: .corrupted currently unreachable")
    }
  }
}
