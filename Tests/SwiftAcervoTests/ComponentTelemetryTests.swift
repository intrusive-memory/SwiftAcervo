// ComponentTelemetryTests.swift
// SwiftAcervo tests
//
// Covers telemetry emission from the component-keyed APIs introduced in
// the manifest-destiny migration:
//
//   - Acervo.hydrateComponent(_:telemetry:) emits manifestFetchStart /
//     manifestFetchComplete events.
//   - Acervo.ensureComponentReady(_:in:telemetry:) emits
//     componentResolveStart + componentResolveComplete and short-circuits
//     to `.alreadyReady` when files are already on disk.
//   - AcervoManager.withComponentAccess(_:in:perform:) emits
//     componentFileAccessOpened when a downloaded component is opened.
//   - AcervoManager.setTelemetry(reporter) routes events from the
//     manager-keyed component APIs through the attached reporter.
//
// Lives under SharedStaticStateSuite.MockURLProtocolSuite so we can stub
// the CDN via MockURLProtocol without racing other suites.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Component Telemetry — manifest-destiny APIs")
  struct ComponentTelemetryTests {

    // MARK: - Helpers

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ComponentTelemetryTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    /// Builds a deterministic two-file manifest plus the matching bodies.
    private static func makeFixture(
      modelId: String
    ) -> (manifestJSON: Data, bodies: [String: Data]) {
      let configBody = Data("{\"_name_or_path\":\"telemetry\"}".utf8)
      let weightsBody = Data(repeating: 0x33, count: 128)

      let configSHA = SHA256.hash(data: configBody).map { String(format: "%02x", $0) }.joined()
      let weightsSHA = SHA256.hash(data: weightsBody).map { String(format: "%02x", $0) }.joined()

      let files = [
        CDNManifestFile(path: "config.json", sha256: configSHA, sizeBytes: Int64(configBody.count)),
        CDNManifestFile(
          path: "model.safetensors",
          sha256: weightsSHA,
          sizeBytes: Int64(weightsBody.count)),
      ]
      let manifest = CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: Acervo.slugify(modelId),
        updatedAt: "2026-05-16T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
      let encoded = try! JSONEncoder().encode(manifest)
      return (
        encoded,
        [
          "config.json": configBody,
          "model.safetensors": weightsBody,
        ]
      )
    }

    /// Installs a responder that returns the manifest on `/manifest.json`
    /// and serves per-file bodies for every other URL by last-path-component.
    private static func installResponder(manifestJSON: Data, bodies: [String: Data]) {
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

    private static func bareDescriptor(
      id: String,
      repo: String
    ) -> ComponentDescriptor {
      ComponentDescriptor(
        id: id,
        type: .backbone,
        displayName: "Telemetry Test",
        repoId: repo,
        minimumMemoryBytes: 0
      )
    }

    private static func uniqueIds() -> (modelId: String, componentId: String) {
      let uid = UUID().uuidString.prefix(8)
      return (
        modelId: "telem-test/repo-\(uid)",
        componentId: "telem-comp-\(uid)"
      )
    }

    // MARK: - Test A: hydrateComponent routes telemetry to manifestFetch events

    @Test("hydrateComponent(telemetry:) emits manifestFetchStart and manifestFetchComplete")
    func hydrateRoutesManifestEvents() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedComponentRegistry {
        let (modelId, componentId) = Self.uniqueIds()
        Acervo.register(Self.bareDescriptor(id: componentId, repo: modelId))

        let (manifestJSON, bodies) = Self.makeFixture(modelId: modelId)
        Self.installResponder(manifestJSON: manifestJSON, bodies: bodies)

        let reporter = MockTelemetryReporter()
        try await Acervo.hydrateComponent(
          componentId,
          session: MockURLProtocol.session(),
          telemetry: reporter
        )

        let events = await reporter.snapshot()
        let hasStart = events.contains {
          if case .manifestFetchStart(let id, _) = $0 { return id == modelId }
          return false
        }
        let hasComplete = events.contains {
          if case .manifestFetchComplete(let id, _, let count, _) = $0 {
            return id == modelId && count == 2
          }
          return false
        }
        #expect(hasStart, "expected manifestFetchStart for \(modelId)")
        #expect(hasComplete, "expected manifestFetchComplete with 2 files")
      }
    }

    // MARK: - Test B: ensureComponentReady cache-hit short-circuit emits componentResolve pair

    @Test(
      "ensureComponentReady emits componentResolveStart + Complete(.alreadyReady) on cache hit"
    )
    func ensureComponentReadyCacheHit() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedComponentRegistry {
        let (modelId, componentId) = Self.uniqueIds()
        let (manifestJSON, bodies) = Self.makeFixture(modelId: modelId)

        // Pre-register a HYDRATED descriptor so ensureComponentReady does
        // not call out to the CDN at all — it should short-circuit on the
        // isComponentReady check.
        let files = bodies.map { (name, data) in
          ComponentFile(
            relativePath: name,
            expectedSizeBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          )
        }.sorted { $0.relativePath < $1.relativePath }

        let descriptor = ComponentDescriptor(
          id: componentId,
          type: .backbone,
          displayName: "Cache Hit Test",
          repoId: modelId,
          files: files,
          estimatedSizeBytes: files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) },
          minimumMemoryBytes: 0
        )
        Acervo.register(descriptor)

        // Plant the files on disk so isComponentReady returns true.
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let componentDir = tempDir.appendingPathComponent(Acervo.slugify(modelId))
        try FileManager.default.createDirectory(
          at: componentDir, withIntermediateDirectories: true)
        for (name, data) in bodies {
          try data.write(to: componentDir.appendingPathComponent(name))
        }

        // Install a responder that records request count; we must NOT see a
        // single network call when the cache hit short-circuit fires.
        Self.installResponder(manifestJSON: manifestJSON, bodies: bodies)
        let baselineRequests = MockURLProtocol.requestCount

        let reporter = MockTelemetryReporter()
        try await Acervo.ensureComponentReady(
          componentId,
          in: tempDir,
          telemetry: reporter
        )

        let events = await reporter.snapshot()
        let hasStart = events.contains {
          if case .componentResolveStart(let id, let repo) = $0 {
            return id == componentId && repo == modelId
          }
          return false
        }
        var sawAlreadyReady = false
        for event in events {
          if case .componentResolveComplete(let id, _, _, _, let state, _) = event,
            id == componentId, state == .alreadyReady
          {
            sawAlreadyReady = true
          }
        }
        #expect(hasStart)
        #expect(sawAlreadyReady, "expected componentResolveComplete(.alreadyReady)")
        #expect(
          MockURLProtocol.requestCount == baselineRequests,
          "cache hit path must not touch the network"
        )
      }
    }

    // MARK: - Test C: AcervoManager.withComponentAccess emits fileAccessOpened

    @Test("AcervoManager.withComponentAccess emits componentFileAccessOpened")
    func managerWithComponentAccessEmitsFileAccessOpened() async throws {
      let tempDir = try Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: tempDir) }

      try await withIsolatedComponentRegistry {
        let (modelId, componentId) = Self.uniqueIds()
        let (_, bodies) = Self.makeFixture(modelId: modelId)

        let files = bodies.map { (name, data) in
          ComponentFile(
            relativePath: name,
            expectedSizeBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
          )
        }.sorted { $0.relativePath < $1.relativePath }

        let descriptor = ComponentDescriptor(
          id: componentId,
          type: .backbone,
          displayName: "Access Telemetry",
          repoId: modelId,
          files: files,
          estimatedSizeBytes: files.reduce(Int64(0)) { $0 + ($1.expectedSizeBytes ?? 0) },
          minimumMemoryBytes: 0
        )
        Acervo.register(descriptor)

        // Plant files on disk so integrity passes.
        let componentDir = tempDir.appendingPathComponent(Acervo.slugify(modelId))
        try FileManager.default.createDirectory(
          at: componentDir, withIntermediateDirectories: true)
        for (name, data) in bodies {
          try data.write(to: componentDir.appendingPathComponent(name))
        }

        let reporter = MockTelemetryReporter()
        let manager = AcervoManager.shared
        let previousTelemetry = await manager.currentTelemetry
        await manager.setTelemetry(reporter)

        let result: String
        do {
          result = try await manager.withComponentAccess(
            componentId,
            in: tempDir
          ) { handle in
            return handle.descriptor.id
          }
        } catch {
          await manager.setTelemetry(previousTelemetry)
          throw error
        }
        await manager.setTelemetry(previousTelemetry)
        #expect(result == componentId)

        let events = await reporter.snapshot()
        let hasFileAccess = events.contains {
          if case .componentFileAccessOpened(let id, let repo, let base, let count) = $0 {
            return id == componentId && repo == modelId && base == componentDir.path
              && count == files.count
          }
          return false
        }
        #expect(hasFileAccess, "expected componentFileAccessOpened for \(componentId)")
      }
    }

    // MARK: - Test D: AcervoManager.ensureComponentReady routes through attached reporter

    /// Verifies that `AcervoManager.ensureComponentReady(_:)` actually
    /// forwards `self.telemetry` down into `Acervo.ensureComponentReady`
    /// rather than silently dropping it. We probe the wiring with an
    /// unregistered component ID: the static implementation emits an
    /// `errorThrown` event before throwing `componentNotRegistered`, so
    /// observing that event at the manager-attached reporter is a clean
    /// signal that the parameter made it through (a regression that
    /// dropped the telemetry argument would leave the reporter empty).
    @Test(
      "AcervoManager.ensureComponentReady forwards telemetry to the static surface"
    )
    func managerEnsureComponentReadyRoutesTelemetry() async throws {
      let reporter = MockTelemetryReporter()
      let manager = AcervoManager.shared
      let previousTelemetry = await manager.currentTelemetry
      await manager.setTelemetry(reporter)

      let unknownId = "manager-route-test-\(UUID().uuidString.prefix(8))"
      await #expect(throws: AcervoError.self) {
        try await manager.ensureComponentReady(unknownId)
      }

      // Restore singleton state synchronously before the test exits so we
      // do not leak the reporter into adjacent serialized tests.
      await manager.setTelemetry(previousTelemetry)

      let events = await reporter.snapshot()
      let routedThroughManager = events.contains {
        if case .errorThrown(_, let desc, _, _) = $0 {
          return desc.contains(unknownId)
        }
        return false
      }
      #expect(
        routedThroughManager,
        "expected errorThrown event from Acervo.ensureComponentReady to reach manager reporter"
      )
    }

    // MARK: - Test E: passing telemetry: nil yields zero captures

    @Test("hydrateComponent(telemetry: nil) yields zero captures")
    func hydrateWithNilTelemetryStaysSilent() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedComponentRegistry {
        let (modelId, componentId) = Self.uniqueIds()
        Acervo.register(Self.bareDescriptor(id: componentId, repo: modelId))

        let (manifestJSON, bodies) = Self.makeFixture(modelId: modelId)
        Self.installResponder(manifestJSON: manifestJSON, bodies: bodies)

        let reporter = MockTelemetryReporter()
        try await Acervo.hydrateComponent(
          componentId,
          session: MockURLProtocol.session(),
          telemetry: nil
        )
        let count = await reporter.count()
        #expect(count == 0, "telemetry:nil must not feed an unattached reporter")

        // Sanity: with the reporter attached, events DO fire.
        try await Acervo.hydrateComponent(
          componentId,
          session: MockURLProtocol.session(),
          telemetry: reporter
        )
        let count2 = await reporter.count()
        #expect(count2 > 0)
      }
    }
  }
}
