// SlugAvailabilityTests.swift
// SwiftAcervo
//
// Sortie 2 of OPERATION QUARTERMASTER TORRENT (slug-registry/S2).
//
// Acceptance tests for `Acervo.availability(slug:url:telemetry:)`:
//
//   (a) HF-style slug + no URL → single-component manifest returns the
//       per-repo state (today-equivalent regression case).
//   (b) slug + explicit URL → multi-component all-available returns
//       `.available`.
//   (c) slug + explicit URL → multi-component mixed states returns
//       `.downloading(progress: 0.5)` with the EXACT expected numeric value.
//   (d) non-`org/repo` slug + no URL throws
//       `AcervoError.urlRequiredForSlug`.
//   (e) manifest fetch returning HTTP 404 throws
//       `AcervoError.manifestFetchFailed(slug:status:)`.
//   (f) telemetry emits exactly once per call regardless of call shape.
//
// All tests use a `MockURLProtocol` stub — no live network, no timing,
// no wall-clock assertions.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

/// Counting telemetry stub for assertion (f). Records each event in order;
/// tests assert on the count and on the kind of the captured events.
actor CountingTelemetryReporter: AcervoTelemetryReporter {
  private(set) var events: [AcervoTelemetryEvent] = []

  func capture(_ event: AcervoTelemetryEvent) async {
    events.append(event)
  }

  /// Filter helper: events that count toward the "exactly one availability
  /// emission per call" assertion.
  func availabilityResolvedCount() -> Int {
    events.filter {
      if case .modelAvailabilityResolved = $0 { return true }
      return false
    }.count
  }

  func errorCount() -> Int {
    events.filter {
      if case .errorThrown = $0 { return true }
      return false
    }.count
  }

  func reset() {
    events.removeAll()
  }
}

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Slug-keyed Availability (S2)")
  struct SlugAvailabilityTests {

    // MARK: - Fixture helpers

    private func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifestFile(path: String, data: Data) -> CDNManifestFile {
      CDNManifestFile(path: path, sha256: sha256Hex(data), sizeBytes: Int64(data.count))
    }

    private func makeManifest(
      modelId: String,
      primaryRepo: String? = nil,
      components: [String]? = nil,
      files: [CDNManifestFile]
    ) -> CDNManifest {
      let slug = Acervo.slugify(modelId)
      let checksum = CDNManifest.computeChecksum(from: files.map(\.sha256))
      return CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: slug,
        updatedAt: "2026-05-19T00:00:00Z",
        files: files,
        manifestChecksum: checksum,
        primaryRepo: primaryRepo,
        components: components
      )
    }

    private func makeTempBase() throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SlugAvailabilityTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }

    private func removeTempBase(_ url: URL) {
      try? FileManager.default.removeItem(at: url)
    }

    /// Materializes a component on disk: writes manifest-declared files and
    /// persists `.acervo-manifest.json` so the legacy
    /// `Acervo.availability(_:)` probe sees `.available`.
    private func materializeFully(
      modelId: String,
      manifest: CDNManifest,
      bodies: [String: Data],
      in baseDirectory: URL
    ) throws {
      let modelDir = baseDirectory.appendingPathComponent(Acervo.slugify(modelId))
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      for file in manifest.files {
        guard let body = bodies[file.path] else { continue }
        let target = modelDir.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try body.write(to: target)
      }
      try AcervoDownloader.persistManifest(manifest, in: baseDirectory)
    }

    /// Persists only the manifest cache (no on-disk file bodies) — used to
    /// give the aggregator a per-component byte budget while the component
    /// itself is `.notAvailable`.
    private func materializeManifestOnly(
      manifest: CDNManifest,
      in baseDirectory: URL
    ) throws {
      let modelDir = baseDirectory.appendingPathComponent(manifest.slug)
      try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
      try AcervoDownloader.persistManifest(manifest, in: baseDirectory)
    }

    // MARK: - Test (a) — HF-style slug + no URL → today-equivalent

    @Test(
      "(a) HF-style slug + no URL: single-component manifest returns per-repo .available"
    )
    func a_hfSlugNoURL_returnsPerRepoState() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let modelId = "test-org/single-comp-\(UUID().uuidString.prefix(8))"
      let configData = Data("{}".utf8)
      let weightsData = Data(repeating: 0x42, count: 256)
      let files = [
        manifestFile(path: "config.json", data: configData),
        manifestFile(path: "weights.safetensors", data: weightsData),
      ]
      // Single-component manifest: components == [modelId].
      let manifest = makeManifest(modelId: modelId, files: files)
      try materializeFully(
        modelId: modelId,
        manifest: manifest,
        bodies: ["config.json": configData, "weights.safetensors": weightsData],
        in: tempBase
      )

      // Serve the manifest at the derived CDN URL.
      let encodedManifest = try JSONEncoder().encode(manifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )!
        return (response, encodedManifest)
      }

      let telemetry = CountingTelemetryReporter()
      let result = try await Acervo.availability(
        slug: modelId,
        url: nil,
        in: tempBase,
        telemetry: telemetry,
        session: MockURLProtocol.session()
      )

      #expect(result == .available)

      // Also confirm the equivalence claim: the legacy repo-keyed call
      // returns the same observable state given the same on-disk state.
      let legacy = await Acervo.availability(modelId, in: tempBase)
      #expect(legacy == result)
    }

    // MARK: - Test (b) — slug + explicit URL, multi-component all-available

    @Test("(b) slug + explicit URL: multi-component all-available returns .available")
    func b_explicitURL_multiComponentAllAvailable() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let slugId = "flux2-klein-4b-allavail-\(UUID().uuidString.prefix(8))"
      let primary = "black-forest-labs/FLUX.2-klein-4B"
      let vae = "black-forest-labs/FLUX.2-vae"
      let textEnc = "google/t5-v1_1-xxl"
      let components = [primary, vae, textEnc]

      // Materialize EACH component's local state so the legacy probe sees
      // each one as `.available`.
      for repo in components {
        let data = Data("{}".utf8)
        let files = [manifestFile(path: "config.json", data: data)]
        let m = makeManifest(
          modelId: repo, primaryRepo: primary, components: components, files: files)
        try materializeFully(
          modelId: repo, manifest: m, bodies: ["config.json": data], in: tempBase)
      }

      // The slug-level manifest the URL serves. Components list points at
      // the per-repo manifests we just materialized.
      let slugManifestData = Data("{}".utf8)
      let slugManifest = makeManifest(
        modelId: slugId,
        primaryRepo: primary,
        components: components,
        files: [manifestFile(path: "config.json", data: slugManifestData)]
      )
      let encoded = try JSONEncoder().encode(slugManifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"])!
        return (response, encoded)
      }

      let explicitURL = URL(string: "https://example.invalid/staging/\(slugId)/manifest.json")!
      let telemetry = CountingTelemetryReporter()
      let result = try await Acervo.availability(
        slug: slugId,
        url: explicitURL,
        in: tempBase,
        telemetry: telemetry,
        session: MockURLProtocol.session()
      )
      #expect(result == .available)

      let count = await telemetry.availabilityResolvedCount()
      #expect(count == 1)
    }

    // MARK: - Test (c) — multi-component mixed states with EXACT numeric value

    @Test(
      "(c) slug + explicit URL: mixed multi-component returns .downloading(0.5) exactly"
    )
    func c_explicitURL_multiComponentMixed_exactProgress() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let slugId = "flux2-mixed-\(UUID().uuidString.prefix(8))"
      let xform = "black-forest-labs/FLUX.2-klein-4B-transformer-\(UUID().uuidString.prefix(6))"
      let vae = "black-forest-labs/FLUX.2-vae-\(UUID().uuidString.prefix(6))"
      let textEnc = "google/t5-v1_1-xxl-\(UUID().uuidString.prefix(6))"
      let components = [xform, vae, textEnc]

      // Fixture sizes scaled down (4KB / 1KB / 1KB) so the on-disk size
      // check is feasible. The aggregator math depends only on the
      // ratios, which match the canonical sortie example:
      //   transformer: 4 KB, .downloading(0.5)
      //   VAE:         1 KB, .available
      //   t5:          1 KB, .notAvailable
      // Expected aggregate: 0.5 * (4/6) + 1.0 * (1/6) + 0.0 * (1/6) = 0.5
      let fourKB: Int = 4 * 1024
      let oneKB: Int = 1 * 1024

      // Transformer: declared 4KB, NOT on disk → legacy probe sees
      // .notAvailable EXCEPT when an in-flight entry is registered, in
      // which case it returns .downloading. We register a long-lived Task
      // with progress 0.5.
      let xformBody = Data(repeating: 0xAA, count: fourKB)
      let xformFile = manifestFile(path: "model.safetensors", data: xformBody)
      let xformManifest = makeManifest(
        modelId: xform, primaryRepo: xform, components: [xform], files: [xformFile])
      try materializeManifestOnly(manifest: xformManifest, in: tempBase)

      // Register an in-flight Task at progress 0.5. The Task body never
      // completes (Task.sleep for a year); we cancel + reset the registry
      // at the end of the test to leave a clean state for the next case.
      // Send the captured slug into the closure to avoid Sendable issues.
      let xformID = xform
      let registeredTask = await InFlightDownloads.shared.task(for: xformID) {
        Task {
          try? await Task.sleep(nanoseconds: 365 * 24 * 60 * 60 * 1_000_000_000)
        }
      }
      await InFlightDownloads.shared.publishProgress(0.5, for: xformID)

      // VAE: declared 1KB, fully on disk → .available
      let vaeBody = Data(repeating: 0xBB, count: oneKB)
      let vaeFile = manifestFile(path: "model.safetensors", data: vaeBody)
      let vaeManifest = makeManifest(
        modelId: vae, primaryRepo: vae, components: [vae], files: [vaeFile])
      try materializeFully(
        modelId: vae, manifest: vaeManifest,
        bodies: ["model.safetensors": vaeBody], in: tempBase)

      // Text encoder: declared 1KB, NOT on disk, NOT in-flight → .notAvailable
      let teBody = Data(repeating: 0xCC, count: oneKB)
      let teFile = manifestFile(path: "model.safetensors", data: teBody)
      let teManifest = makeManifest(
        modelId: textEnc, primaryRepo: textEnc, components: [textEnc], files: [teFile])
      try materializeManifestOnly(manifest: teManifest, in: tempBase)

      // Slug-level manifest the URL serves.
      let slugManifest = makeManifest(
        modelId: slugId,
        primaryRepo: xform,
        components: components,
        files: [manifestFile(path: "config.json", data: Data("{}".utf8))]
      )
      let encoded = try JSONEncoder().encode(slugManifest)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"])!
        return (response, encoded)
      }

      let explicitURL = URL(
        string: "https://example.invalid/staging/\(slugId)/manifest.json")!
      let telemetry = CountingTelemetryReporter()
      let result = try await Acervo.availability(
        slug: slugId,
        url: explicitURL,
        in: tempBase,
        telemetry: telemetry,
        session: MockURLProtocol.session()
      )

      // Cancel + reset the in-flight registration before assertions so
      // any failure leaves the registry clean for the next test.
      registeredTask.cancel()
      await InFlightDownloads.shared.reset()

      guard case .downloading(let p) = result else {
        Issue.record("expected .downloading, got \(result)")
        return
      }
      // EXACT value: 0.5 * (4/6) + 1.0 * (1/6) + 0.0 * (1/6) = 0.5
      #expect(p == 0.5, "expected exactly 0.5, got \(p)")
    }

    // MARK: - Test (d) — non-org/repo slug + no URL throws urlRequiredForSlug

    @Test("(d) non-org/repo slug + no URL throws AcervoError.urlRequiredForSlug")
    func d_freeFormSlugNoURL_throws() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      // A slug with NO slash — clearly not org/repo.
      let freeForm = "flux2-klein-4b"
      let telemetry = CountingTelemetryReporter()

      var thrown: Error?
      do {
        _ = try await Acervo.availability(
          slug: freeForm,
          url: nil,
          in: tempBase,
          telemetry: telemetry,
          session: MockURLProtocol.session()
        )
      } catch {
        thrown = error
      }
      #expect(thrown != nil)
      if let acervoError = thrown as? AcervoError {
        if case .urlRequiredForSlug(let s) = acervoError {
          #expect(s == freeForm)
        } else {
          Issue.record(
            "expected .urlRequiredForSlug, got \(acervoError)")
        }
      } else {
        Issue.record("expected AcervoError, got \(String(describing: thrown))")
      }

      // Also confirm: telemetry got the error-thrown side-channel emission,
      // NOT the availability-resolved emission, so the "exactly one
      // availability event per successful call" contract is honored.
      let resolved = await telemetry.availabilityResolvedCount()
      #expect(
        resolved == 0,
        "error path must not emit modelAvailabilityResolved")
    }

    @Test("(d2) slug with leading slash is also rejected")
    func d2_leadingSlashSlugRejected() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()
      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      var thrown: Error?
      do {
        _ = try await Acervo.availability(
          slug: "/no-org",
          url: nil,
          in: tempBase,
          telemetry: nil,
          session: MockURLProtocol.session()
        )
      } catch {
        thrown = error
      }
      if case .urlRequiredForSlug = (thrown as? AcervoError) {
        // OK
      } else {
        Issue.record("expected .urlRequiredForSlug, got \(String(describing: thrown))")
      }
    }

    // MARK: - Test (e) — HTTP 404 throws manifestFetchFailed

    @Test("(e) manifest fetch returning HTTP 404 throws manifestFetchFailed(slug:status:)")
    func e_http404_throwsManifestFetchFailed() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      let slug = "test-org/missing-\(UUID().uuidString.prefix(8))"

      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 404,
          httpVersion: "HTTP/1.1",
          headerFields: [:]
        )!
        return (response, Data("not found".utf8))
      }

      let telemetry = CountingTelemetryReporter()
      var thrown: Error?
      do {
        _ = try await Acervo.availability(
          slug: slug,
          url: nil,
          in: tempBase,
          telemetry: telemetry,
          session: MockURLProtocol.session()
        )
      } catch {
        thrown = error
      }
      guard let acervoError = thrown as? AcervoError else {
        Issue.record("expected AcervoError, got \(String(describing: thrown))")
        return
      }
      if case .manifestFetchFailed(let s, let status) = acervoError {
        #expect(s == slug)
        #expect(status == 404)
      } else {
        Issue.record("expected .manifestFetchFailed, got \(acervoError)")
      }

      let resolved = await telemetry.availabilityResolvedCount()
      #expect(resolved == 0)
    }

    // MARK: - Test (f) — telemetry emits exactly once per successful call

    @Test(
      "(f) telemetry emits exactly one modelAvailabilityResolved per successful call across shapes"
    )
    func f_telemetryEmitsExactlyOncePerCall() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      await ManifestCache.shared.clear()
      await InFlightDownloads.shared.reset()

      let tempBase = try makeTempBase()
      defer { removeTempBase(tempBase) }

      // ---- Call shape #1: derived URL, single-component, on-disk available
      let single = "test-org/single-\(UUID().uuidString.prefix(8))"
      let body = Data("{}".utf8)
      let singleManifest = makeManifest(
        modelId: single, files: [manifestFile(path: "config.json", data: body)])
      try materializeFully(
        modelId: single, manifest: singleManifest, bodies: ["config.json": body],
        in: tempBase)

      let encodedSingle = try JSONEncoder().encode(singleManifest)
      MockURLProtocol.responder = { _ in
        let response = HTTPURLResponse(
          url: URL(string: "https://example.invalid/x")!,
          statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (response, encodedSingle)
      }

      let telemetry = CountingTelemetryReporter()
      _ = try await Acervo.availability(
        slug: single, url: nil, in: tempBase, telemetry: telemetry,
        session: MockURLProtocol.session())
      let after1 = await telemetry.availabilityResolvedCount()
      #expect(after1 == 1, "after 1st call: expected 1 resolved event, got \(after1)")

      // ---- Call shape #2: explicit URL, same single-component slug
      await ManifestCache.shared.clear()  // force re-fetch via session
      _ = try await Acervo.availability(
        slug: single,
        url: URL(string: "https://example.invalid/explicit/\(single)/manifest.json")!,
        in: tempBase, telemetry: telemetry,
        session: MockURLProtocol.session())
      let after2 = await telemetry.availabilityResolvedCount()
      #expect(after2 == 2, "after 2nd call: expected 2 resolved events, got \(after2)")

      // ---- Call shape #3: cached manifest (no network), derived URL
      // Repeat the first call with the cache primed — still exactly one
      // additional emission.
      _ = try await Acervo.availability(
        slug: single, url: nil, in: tempBase, telemetry: telemetry,
        session: MockURLProtocol.session())
      let after3 = await telemetry.availabilityResolvedCount()
      #expect(after3 == 3, "after 3rd call: expected 3 resolved events, got \(after3)")

      // ---- Call shape #4: multi-component slug, explicit URL
      let multi = "multi-\(UUID().uuidString.prefix(8))"
      let primary = "test-org/primary"
      let secondary = "test-org/secondary"
      for repo in [primary, secondary] {
        let m = makeManifest(
          modelId: repo, primaryRepo: primary, components: [primary, secondary],
          files: [manifestFile(path: "config.json", data: body)])
        try materializeFully(
          modelId: repo, manifest: m, bodies: ["config.json": body], in: tempBase)
      }
      let multiManifest = makeManifest(
        modelId: multi, primaryRepo: primary, components: [primary, secondary],
        files: [manifestFile(path: "config.json", data: body)])
      let encodedMulti = try JSONEncoder().encode(multiManifest)
      MockURLProtocol.responder = { _ in
        let response = HTTPURLResponse(
          url: URL(string: "https://example.invalid/m")!,
          statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (response, encodedMulti)
      }
      _ = try await Acervo.availability(
        slug: multi,
        url: URL(string: "https://example.invalid/multi/manifest.json")!,
        in: tempBase, telemetry: telemetry,
        session: MockURLProtocol.session())
      let after4 = await telemetry.availabilityResolvedCount()
      #expect(after4 == 4, "after 4th call: expected 4 resolved events, got \(after4)")

      // ---- Call shape #5: error path (404) — must NOT emit resolved
      let missing = "test-org/missing-\(UUID().uuidString.prefix(8))"
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (response, Data())
      }
      do {
        _ = try await Acervo.availability(
          slug: missing, url: nil, in: tempBase, telemetry: telemetry,
          session: MockURLProtocol.session())
        Issue.record("expected throw on 404")
      } catch {
        // expected
      }
      let after5 = await telemetry.availabilityResolvedCount()
      #expect(
        after5 == 4,
        "after error: resolved-event count must NOT increase; got \(after5)")
      let errors = await telemetry.errorCount()
      #expect(errors >= 1, "error path must emit errorThrown side-channel")
    }
  }
}
