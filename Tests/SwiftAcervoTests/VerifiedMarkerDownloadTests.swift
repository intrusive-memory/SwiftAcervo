// VerifiedMarkerDownloadTests.swift
// SwiftAcervo
//
// Sortie A3 of OPERATION INTEGRITY CHECKPOINT (C4 · R2.1).
//
// Covers, per the A3 exit criteria:
//
//   1. After a simulated full download (`requestedFiles: []`),
//      `.acervo-verified.json` is present in the model directory with a
//      `manifestChecksum` matching the downloaded manifest.
//   2. A subsequent `availability` call on the freshly-downloaded model
//      takes the marker fast-path — the oracle evaluator is NOT invoked
//      (asserted via the `HashInvocationSpy` pattern from A2's
//      `VerifiedMarkerTests.swift`).
//   3. A partial download (`requestedFiles` non-empty) does NOT write the
//      verified marker — stamping an incomplete directory would cause the
//      availability fast-path to trust a missing-file model as ready.
//
// All tests are tempdir-backed — no live disk dependency, no live CDN.
// Network calls are intercepted via `MockURLProtocol`.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("A3: Verified marker on download completion")
  struct VerifiedMarkerDownloadTests {

    // MARK: - Shared helpers

    private func sha256Hex(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeManifest(modelId: String, files: [CDNManifestFile]) -> CDNManifest {
      CDNManifest(
        manifestVersion: CDNManifest.supportedVersion,
        modelId: modelId,
        slug: Acervo.slugify(modelId),
        updatedAt: "2026-06-28T00:00:00Z",
        files: files,
        manifestChecksum: CDNManifest.computeChecksum(from: files.map(\.sha256))
      )
    }

    /// Configures `MockURLProtocol` to serve the given manifest bytes and per-file
    /// bodies.  The responder identifies the manifest request by a trailing
    /// `/manifest.json` path component and file requests by matching a declared
    /// `filePath` suffix against the request URL path.
    private func installMockResponder(
      manifestBytes: Data,
      fileBodies: [String: Data]
    ) {
      MockURLProtocol.responder = { request in
        let urlPath = request.url?.path ?? ""
        if urlPath.hasSuffix("/manifest.json") {
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
          )!
          return (response, manifestBytes)
        }
        for (filePath, body) in fileBodies {
          if urlPath.hasSuffix("/\(filePath)") {
            let response = HTTPURLResponse(
              url: request.url!,
              statusCode: 200,
              httpVersion: "HTTP/1.1",
              headerFields: ["Content-Type": "application/octet-stream"]
            )!
            return (response, body)
          }
        }
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 404,
          httpVersion: "HTTP/1.1",
          headerFields: [:]
        )!
        return (response, Data())
      }
    }

    // MARK: - EXIT CRITERION 1: marker written with correct checksum

    /// EXIT CRITERION: after a simulated successful full download
    /// (`requestedFiles: []`), `.acervo-verified.json` is present with a
    /// `manifestChecksum` matching the downloaded manifest.
    @Test("full download writes .acervo-verified.json with correct manifestChecksum")
    func fullDownload_writesMarker() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = "a3-test/full-download-\(UUID().uuidString.prefix(8))"
      let slug = Acervo.slugify(modelId)
      let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("A3FullDownload-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempBase) }

      let destination = tempBase.appendingPathComponent(slug)
      try AcervoDownloader.ensureDirectory(at: destination)

      let configBody = Data("{\"model\":\"a3-full\"}".utf8)
      let weightsBody = Data(repeating: 0xAB, count: 512)
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: sha256Hex(configBody),
          sizeBytes: Int64(configBody.count)
        ),
        CDNManifestFile(
          path: "weights.bin",
          sha256: sha256Hex(weightsBody),
          sizeBytes: Int64(weightsBody.count)
        ),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      let manifestBytes = try encoder.encode(manifest)

      installMockResponder(
        manifestBytes: manifestBytes,
        fileBodies: ["config.json": configBody, "weights.bin": weightsBody]
      )

      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: [],
        destination: destination,
        session: MockURLProtocol.session()
      )

      // EXIT CRITERION: marker file must be present.
      let markerURL = VerifiedMarker.url(in: destination)
      #expect(
        FileManager.default.fileExists(atPath: markerURL.path),
        ".acervo-verified.json must be written after a successful full download"
      )

      // EXIT CRITERION: checksum must match the manifest.
      let marker = VerifiedMarker.read(in: destination)
      #expect(
        marker?.manifestChecksum == manifest.manifestChecksum,
        "marker must be stamped with the downloaded manifest's manifestChecksum"
      )
    }

    // MARK: - EXIT CRITERION 2: subsequent availability takes the fast-path

    /// EXIT CRITERION: a subsequent `availability` call on the freshly-downloaded
    /// model returns `.available` via the marker fast-path — the oracle evaluator
    /// seam is never invoked.
    ///
    /// The injected `availabilityEvaluatorOverride` returns `.partial` as a
    /// sentinel: if the fast-path fires as expected the seam is bypassed and
    /// availability returns `.available`; if it does NOT fire the seam's
    /// `.partial` response would surface, failing the test.
    @Test("freshly downloaded model: subsequent availability takes the marker fast-path")
    func fullDownload_subsequentAvailabilitySkipsOracle() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = "a3-test/fast-path-\(UUID().uuidString.prefix(8))"
      let slug = Acervo.slugify(modelId)
      let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("A3FastPath-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempBase) }

      let destination = tempBase.appendingPathComponent(slug)
      try AcervoDownloader.ensureDirectory(at: destination)

      let configBody = Data("{\"model\":\"a3-fast-path\"}".utf8)
      let weightsBody = Data(repeating: 0xCD, count: 256)
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: sha256Hex(configBody),
          sizeBytes: Int64(configBody.count)
        ),
        CDNManifestFile(
          path: "weights.bin",
          sha256: sha256Hex(weightsBody),
          sizeBytes: Int64(weightsBody.count)
        ),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      let manifestBytes = try encoder.encode(manifest)

      installMockResponder(
        manifestBytes: manifestBytes,
        fileBodies: ["config.json": configBody, "weights.bin": weightsBody]
      )

      // Perform the full download so the marker is written.
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: [],
        destination: destination,
        session: MockURLProtocol.session()
      )

      // Precondition: marker must exist before testing the fast-path.
      #expect(
        VerifiedMarker.read(in: destination) != nil,
        "precondition: marker must be present before testing the fast-path"
      )

      // EXIT CRITERION 2: inject the evaluator seam and assert it is never
      // reached when the marker fast-path fires.
      let spy = A3HashInvocationSpy()
      let result = await Acervo.$availabilityEvaluatorOverride.withValue(
        { _, _, verifyHashes in
          await spy.record(verifyHashes: verifyHashes)
          return .partial(missing: ["oracle-reached-unexpectedly"])
        }
      ) {
        await Acervo.availability(modelId, verifyHashes: true, in: tempBase)
      }

      #expect(result == .available, "fast-path must return .available via the marker")
      #expect(
        await spy.totalCalls == 0,
        "oracle evaluator must NOT be invoked when the marker fast-path fires"
      )
      #expect(
        await spy.fullHashCalls == 0,
        "full-hash code path must NOT be entered via the marker fast-path"
      )
    }

    // MARK: - Guard: partial download does NOT write the marker

    /// Guard: `downloadFiles` with a non-empty `requestedFiles` array covers
    /// only a subset of the manifest files. Stamping the marker for such a
    /// partial download would cause the availability fast-path to trust an
    /// incomplete model directory as fully ready — that is a defect. Verify
    /// the marker is NOT written.
    @Test("partial download (requestedFiles non-empty) does NOT write the marker")
    func partialDownload_doesNotWriteMarker() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let modelId = "a3-test/partial-\(UUID().uuidString.prefix(8))"
      let slug = Acervo.slugify(modelId)
      let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("A3Partial-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tempBase) }

      let destination = tempBase.appendingPathComponent(slug)
      try AcervoDownloader.ensureDirectory(at: destination)

      let configBody = Data("{\"model\":\"a3-partial\"}".utf8)
      let weightsBody = Data(repeating: 0xEF, count: 256)
      let files = [
        CDNManifestFile(
          path: "config.json",
          sha256: sha256Hex(configBody),
          sizeBytes: Int64(configBody.count)
        ),
        CDNManifestFile(
          path: "weights.bin",
          sha256: sha256Hex(weightsBody),
          sizeBytes: Int64(weightsBody.count)
        ),
      ]
      let manifest = makeManifest(modelId: modelId, files: files)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      let manifestBytes = try encoder.encode(manifest)

      installMockResponder(
        manifestBytes: manifestBytes,
        fileBodies: ["config.json": configBody, "weights.bin": weightsBody]
      )

      // Download only `config.json` — a partial subset of the manifest.
      try await AcervoDownloader.downloadFiles(
        modelId: modelId,
        requestedFiles: ["config.json"],
        destination: destination,
        session: MockURLProtocol.session()
      )

      // The verified marker must NOT be present.
      let markerURL = VerifiedMarker.url(in: destination)
      #expect(
        !FileManager.default.fileExists(atPath: markerURL.path),
        ".acervo-verified.json must NOT be written for a partial (subset) download"
      )
    }
  }
}

// MARK: - HashInvocationSpy (local; mirrors the pattern in VerifiedMarkerTests.swift)

/// Records whether — and with which `verifyHashes` flag — the injected
/// `availabilityEvaluatorOverride` seam was invoked. Using an actor makes
/// it safe to mutate from the `@Sendable` seam closure.
private actor A3HashInvocationSpy {
  private(set) var totalCalls = 0
  private(set) var fullHashCalls = 0
  func record(verifyHashes: Bool) {
    totalCalls += 1
    if verifyHashes { fullHashCalls += 1 }
  }
}
