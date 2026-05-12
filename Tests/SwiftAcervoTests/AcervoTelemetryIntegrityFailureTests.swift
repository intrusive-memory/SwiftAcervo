// AcervoTelemetryIntegrityFailureTests.swift
// SwiftAcervo tests — Sortie 6a of OPERATION WHISPERING WIRETAPS
//
// Drives integrity failures through two paths:
//
//   1. `IntegrityVerification.verifyAgainstManifest` directly — exercises the
//      Sortie 5a wiring that emits `integrityVerifyStart` then
//      `integrityVerifyComplete(passed: false)` IMMEDIATELY before the throw.
//      Asserts both events land in the reporter's array before the catch
//      executes (i.e. the captures preceded the throw).
//
//   2. The streaming download path (`AcervoDownloader.downloadFiles` →
//      `streamDownloadFile`) where the manifest declares one SHA and the
//      mocked body bytes hash to another. The streaming path computes SHA
//      inline and emits `errorThrown(phase: .fileDownloadIntegrity)`
//      IMMEDIATELY before the throw, but does NOT call
//      `verifyAgainstManifest`, so no `integrityVerify*` events fire on
//      this path. Asserting the errorThrown event proves the wiring on
//      the realistic production path.

import CryptoKit
import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Acervo Telemetry — Integrity Failure")
  struct AcervoTelemetryIntegrityFailureTests {

    private static func makeTempDir() throws -> URL {
      let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AcervoTelemetryIntegrityFailureTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    // MARK: - Path 1: direct IntegrityVerification.verifyAgainstManifest

    @Test("integrityVerifyComplete(passed:false) precedes the throw via verifyAgainstManifest")
    func testVerifyAgainstManifestFailureOrdering() async throws {
      try await withIsolatedAcervoState {
        let reporter = MockTelemetryReporter()
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Plant a file whose bytes hash to one SHA but whose manifest entry
        // declares a different SHA. The size matches, so the SHA-mismatch
        // failure path (not the size-mismatch path) fires.
        let body = Data("the-real-body-bytes-deterministic".utf8)
        let fileURL = tempDir.appendingPathComponent("mismatch.bin")
        try body.write(to: fileURL)

        let wrongSHA = String(repeating: "de", count: 32)  // 64 hex chars

        var eventCountAtCatch = -1
        var caughtError: Error?
        do {
          try await IntegrityVerification.verifyAgainstManifest(
            fileURL: fileURL,
            manifestFile: CDNManifestFile(
              path: "mismatch.bin",
              sha256: wrongSHA,
              sizeBytes: Int64(body.count)
            ),
            telemetry: reporter
          )
          Issue.record("expected integrity verification to throw")
          return
        } catch {
          // Sample the event count BEFORE doing anything else in catch.
          eventCountAtCatch = await reporter.count()
          caughtError = error
        }

        let events = await reporter.snapshot()

        // (a) integrityVerifyComplete(passed: false) was recorded.
        let failComplete = events.contains(where: { event in
          if case .integrityVerifyComplete(_, _, _, _, let passed, _) = event {
            return passed == false
          }
          return false
        })
        #expect(failComplete, "missing integrityVerifyComplete(passed:false) in \(events)")

        // (b) integrityVerifyStart preceded integrityVerifyComplete.
        let startIdx = events.firstIndex(where: {
          if case .integrityVerifyStart = $0 { return true }
          return false
        })
        let completeIdx = events.firstIndex(where: {
          if case .integrityVerifyComplete = $0 { return true }
          return false
        })
        #expect(startIdx != nil && completeIdx != nil)
        if let s = startIdx, let c = completeIdx {
          #expect(s < c, "integrityVerifyStart must precede integrityVerifyComplete")
        }

        // (c) Both events were recorded BEFORE the throw propagated.
        //     The count captured immediately on catch must be ≥ 2
        //     (start + fail-complete).
        #expect(
          eventCountAtCatch >= 2,
          "reporter saw only \(eventCountAtCatch) events at catch; expected ≥ 2")

        // (d) The thrown error is an AcervoError.integrityCheckFailed.
        if let acervoError = caughtError as? AcervoError,
          case .integrityCheckFailed(let file, _, _) = acervoError
        {
          #expect(file == "mismatch.bin")
        } else {
          Issue.record(
            "expected AcervoError.integrityCheckFailed, got \(String(describing: caughtError))")
        }
      }
    }

    // MARK: - Path 2: streaming download path

    @Test("Streaming download path emits errorThrown(.fileDownloadIntegrity) before propagating")
    func testStreamingDownloadIntegrityFailureOrdering() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      try await withIsolatedAcervoState {
        let modelId = "integrity-test/stream-\(UUID().uuidString.prefix(8))"

        // Manifest declares one SHA; we will serve bytes that hash to a
        // different SHA. Size MUST match so the size check passes and the
        // SHA mismatch is the failure trigger.
        let declaredBody = Data(repeating: 0xaa, count: 64)  // size baseline
        let declaredSHA = SHA256.hash(data: declaredBody)
          .map { String(format: "%02x", $0) }.joined()
        let manifestFiles = [
          CDNManifestFile(
            path: "tampered.bin",
            sha256: declaredSHA,
            sizeBytes: Int64(declaredBody.count)
          )
        ]
        let manifest = CDNManifest(
          manifestVersion: CDNManifest.supportedVersion,
          modelId: modelId,
          slug: Acervo.slugify(modelId),
          updatedAt: "2026-05-12T00:00:00Z",
          files: manifestFiles,
          manifestChecksum: CDNManifest.computeChecksum(from: manifestFiles.map(\.sha256))
        )
        let manifestJSON = try JSONEncoder().encode(manifest)

        // Body we will serve: same size, DIFFERENT bytes → different SHA.
        let tamperedBody = Data(repeating: 0xbb, count: 64)

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
          let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
              "Content-Type": "application/octet-stream",
              "Content-Length": "\(tamperedBody.count)",
            ]
          )!
          return (response, tamperedBody)
        }

        let reporter = MockTelemetryReporter()
        let tempDir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let destination = tempDir.appendingPathComponent(Acervo.slugify(modelId))
        try AcervoDownloader.ensureDirectory(at: destination)

        var eventCountAtCatch = -1
        var caughtError: Error?
        do {
          try await AcervoDownloader.downloadFiles(
            modelId: modelId,
            requestedFiles: [],
            destination: destination,
            session: MockURLProtocol.session(),
            telemetry: reporter
          )
          Issue.record("expected SHA mismatch to throw")
          return
        } catch {
          eventCountAtCatch = await reporter.count()
          caughtError = error
        }

        let events = await reporter.snapshot()

        // (a) errorThrown(phase: .fileDownloadIntegrity) was recorded.
        let integrityErrorFound = events.contains(where: { event in
          if case .errorThrown(let phase, _, _, let fileName) = event,
            phase == .fileDownloadIntegrity
          {
            #expect(fileName == "tampered.bin")
            return true
          }
          return false
        })
        #expect(
          integrityErrorFound,
          "expected errorThrown(.fileDownloadIntegrity) in \(events)")

        // (b) The errorThrown event was recorded BEFORE the throw propagated.
        //     Counted at catch site; one of those events MUST be the
        //     errorThrown we just asserted on.
        #expect(eventCountAtCatch >= 1)

        // (c) The thrown error surface is AcervoError.integrityCheckFailed
        //     wrapped or direct.
        if let acervoError = caughtError as? AcervoError {
          // Streaming path throws AcervoError.integrityCheckFailed directly.
          if case .integrityCheckFailed(let file, _, _) = acervoError {
            #expect(file == "tampered.bin")
          } else {
            // Some failure path wraps as something else; we already verified
            // the event, so don't fail on the exact AcervoError shape.
            Issue.record("note: caught \(acervoError) — primary assertion on event passed")
          }
        }
      }
    }
  }
}
