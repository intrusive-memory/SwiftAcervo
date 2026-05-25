// ComponentInFlightTests.swift
// SwiftAcervo tests
//
// Covers the InFlightDownloads wiring inside
// `Acervo.ensureComponentReady(_:in:telemetry:)` — specifically that the
// component-keyed download path registers with `InFlightDownloads.shared`
// for the duration of the underlying Task, so that
// `Acervo.availability(repoId)` returns `.downloading(progress:)` while a
// download is in flight (the contract UI consumers rely on for progress
// display) and the registry is cleared on both success and failure.
//
// Also verifies the two new telemetry events:
//   - inFlightDownloadRegistered(modelID:componentID:role:)
//   - inFlightDownloadCleared(modelID:componentID:outcome:)
//
// Lives under SharedStaticStateSuite.MockURLProtocolSuite so MockURLProtocol
// state is properly serialized with adjacent suites.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Component In-Flight Registration — ensureComponentReady")
  struct ComponentInFlightTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ComponentInFlightTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    private static func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a hydrated descriptor + matching CDN manifest + body bytes for a
    /// single-component repo. The hydrated descriptor short-circuits any auto-
    /// hydration inside `ensureComponentReady`, so the manifest is fetched
    /// once by the underlying download (not twice).
    private static func makeFixture(
      modelId: String,
      componentId: String
    ) -> (descriptor: ComponentDescriptor, manifestJSON: Data, bodies: [String: Data]) {
      let configBody = Data("{\"_marker\":\"inflight-test\"}".utf8)
      let weightsBody = Data(repeating: 0x55, count: 256)

      let configFile = CDNManifestFile(
        path: "config.json",
        sha256: sha256Hex(configBody),
        sizeBytes: Int64(configBody.count)
      )
      let weightsFile = CDNManifestFile(
        path: "model.safetensors",
        sha256: sha256Hex(weightsBody),
        sizeBytes: Int64(weightsBody.count)
      )

      let manifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: Acervo.slugify(modelId),
        updatedAt: "2026-05-25T00:00:00Z",
        files: [configFile, weightsFile],
        manifestChecksum: CDNManifest.computeChecksum(
          from: [configFile.sha256, weightsFile.sha256])
      )
      let manifestJSON = try! JSONEncoder().encode(manifest)

      let files = [
        ComponentFile(
          relativePath: "config.json",
          expectedSizeBytes: Int64(configBody.count),
          sha256: configFile.sha256
        ),
        ComponentFile(
          relativePath: "model.safetensors",
          expectedSizeBytes: Int64(weightsBody.count),
          sha256: weightsFile.sha256
        ),
      ]
      let descriptor = ComponentDescriptor(
        id: componentId,
        type: .backbone,
        displayName: "InFlight Test",
        repoId: modelId,
        files: files,
        estimatedSizeBytes: files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) },
        minimumMemoryBytes: 0
      )

      return (descriptor, manifestJSON, [
        "config.json": configBody,
        "model.safetensors": weightsBody,
      ])
    }

    /// Installs a responder that serves the manifest immediately and sleeps
    /// inside each FILE response so callers polling `availability(_:)` can
    /// observe `.downloading` before the originator's Task finishes.
    private static func installSlowResponder(
      manifestJSON: Data,
      bodies: [String: Data],
      fileDelaySeconds: TimeInterval = 0.4
    ) {
      MockURLProtocol.responder = { request in
        let url = request.url?.absoluteString ?? ""
        if url.hasSuffix("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, manifestJSON)
        }
        // Keep the download in-flight long enough for the polling task below.
        Thread.sleep(forTimeInterval: fileDelaySeconds)
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

    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "inflight-test/repo-\(uid)",
        componentId: "inflight-comp-\(uid)"
      )
    }

    // MARK: - Test 1: `.downloading` surfaces via availability while in flight

    @Test(
      "availability(repoId) returns .downloading while ensureComponentReady is running"
    )
    func availabilityReportsDownloadingWhileInFlight() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      try await withIsolatedComponentRegistry {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (modelId, componentId) = Self.uniqueIds()
        let (descriptor, manifestJSON, bodies) = Self.makeFixture(
          modelId: modelId, componentId: componentId)
        Acervo.register(descriptor)

        Self.installSlowResponder(
          manifestJSON: manifestJSON, bodies: bodies, fileDelaySeconds: 0.5)

        // Launch the download as a child task.
        let session = MockURLProtocol.session()
        let downloadTask = Task {
          try await Acervo.ensureComponentReady(
            componentId,
            in: tempDir,
            telemetry: nil,
            session: session
          )
        }

        // Poll availability until we observe `.downloading` (or time out).
        // The slow responder sleeps 0.5s per file, so we have ample headroom.
        var sawDownloading = false
        var observedFraction: Double = -1
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
          let state = await Acervo.availability(modelId, in: tempDir)
          if case .downloading(let p) = state {
            sawDownloading = true
            observedFraction = p
            break
          }
          try await Task.sleep(for: .milliseconds(25))
        }

        try await downloadTask.value

        #expect(
          sawDownloading,
          "expected Acervo.availability(\(modelId)) to return .downloading while ensureComponentReady is running")
        #expect(
          observedFraction >= 0.0 && observedFraction <= 1.0,
          "observed progress \(observedFraction) must lie in [0.0, 1.0]")

        // Once the Task finishes, the registry must be cleared.
        let stillRegistered = await InFlightDownloads.shared.contains(modelId)
        #expect(stillRegistered == false, "registry must be cleared after success")
      }
    }

    // MARK: - Test 2: success telemetry events fire

    @Test(
      "ensureComponentReady emits inFlightDownloadRegistered(.originator) and inFlightDownloadCleared(.success) on the happy path"
    )
    func telemetryFires_originatorAndSuccess() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      try await withIsolatedComponentRegistry {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (modelId, componentId) = Self.uniqueIds()
        let (descriptor, manifestJSON, bodies) = Self.makeFixture(
          modelId: modelId, componentId: componentId)
        Acervo.register(descriptor)

        Self.installSlowResponder(
          manifestJSON: manifestJSON, bodies: bodies, fileDelaySeconds: 0.0)

        let reporter = MockTelemetryReporter()
        try await Acervo.ensureComponentReady(
          componentId,
          in: tempDir,
          telemetry: reporter,
          session: MockURLProtocol.session()
        )

        // The deferred `inFlightDownloadCleared` fires from a detached Task
        // launched inside the originator's defer block. Give it a brief
        // window to land in the reporter before snapshotting.
        try await Task.sleep(for: .milliseconds(100))

        let events = await reporter.snapshot()

        let sawRegistered = events.contains {
          if case .inFlightDownloadRegistered(let m, let c, let role) = $0 {
            return m == modelId && c == componentId && role == .originator
          }
          return false
        }
        let sawCleared = events.contains {
          if case .inFlightDownloadCleared(let m, let c, let outcome) = $0 {
            return m == modelId && c == componentId && outcome == .success
          }
          return false
        }
        #expect(
          sawRegistered,
          "expected inFlightDownloadRegistered(.originator) for modelID=\(modelId), componentID=\(componentId)")
        #expect(
          sawCleared,
          "expected inFlightDownloadCleared(.success) for modelID=\(modelId)")
      }
    }

    // MARK: - Test 3: failure clears the registry and fires .failure telemetry

    @Test(
      "ensureComponentReady clears the registry and emits inFlightDownloadCleared(.failure) when the underlying download throws"
    )
    func failureClearsRegistry_andEmitsFailureOutcome() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      try await withIsolatedComponentRegistry {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (modelId, componentId) = Self.uniqueIds()
        let (descriptor, _, _) = Self.makeFixture(
          modelId: modelId, componentId: componentId)
        Acervo.register(descriptor)

        // Responder returns 500 for every request so the download throws.
        MockURLProtocol.responder = { request in
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 500,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "0"]
          )!
          return (response, Data())
        }

        let reporter = MockTelemetryReporter()
        await #expect(throws: Error.self) {
          try await Acervo.ensureComponentReady(
            componentId,
            in: tempDir,
            telemetry: reporter,
            session: MockURLProtocol.session()
          )
        }

        // Allow the deferred cleanup Task to land.
        try await Task.sleep(for: .milliseconds(100))

        let stillRegistered = await InFlightDownloads.shared.contains(modelId)
        #expect(
          stillRegistered == false,
          "registry must be cleared on failure (defer-launched finish must run)")

        let events = await reporter.snapshot()
        let sawFailureCleared = events.contains {
          if case .inFlightDownloadCleared(let m, _, let outcome) = $0 {
            return m == modelId && outcome == .failure
          }
          return false
        }
        #expect(
          sawFailureCleared,
          "expected inFlightDownloadCleared(.failure) after download throw")
      }
    }

    // MARK: - Test 4: cache-hit short-circuit does NOT register in-flight

    @Test(
      "ensureComponentReady cache-hit path does not interact with InFlightDownloads"
    )
    func cacheHitDoesNotRegisterInFlight() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await InFlightDownloads.shared.reset()

      try await withIsolatedComponentRegistry {
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (modelId, componentId) = Self.uniqueIds()
        let (descriptor, _, bodies) = Self.makeFixture(
          modelId: modelId, componentId: componentId)
        Acervo.register(descriptor)

        // Plant the files on disk so isComponentReady returns true.
        let componentDir = tempDir.appendingPathComponent(Acervo.slugify(modelId))
        try FileManager.default.createDirectory(
          at: componentDir, withIntermediateDirectories: true)
        for (name, data) in bodies {
          try data.write(to: componentDir.appendingPathComponent(name))
        }

        let reporter = MockTelemetryReporter()
        try await Acervo.ensureComponentReady(
          componentId,
          in: tempDir,
          telemetry: reporter
        )

        let stillRegistered = await InFlightDownloads.shared.contains(modelId)
        #expect(
          stillRegistered == false,
          "cache-hit short-circuit must never touch InFlightDownloads")

        let events = await reporter.snapshot()
        let hadAnyInFlightEvent = events.contains {
          switch $0 {
          case .inFlightDownloadRegistered, .inFlightDownloadCleared:
            return true
          default:
            return false
          }
        }
        #expect(
          hadAnyInFlightEvent == false,
          "cache-hit path must not emit inFlightDownload* events")
      }
    }
  }
}
