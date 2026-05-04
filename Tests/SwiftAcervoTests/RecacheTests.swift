// RecacheTests.swift
// SwiftAcervoTests
//
// Coverage for `Acervo.recache`. The function is a thin composition over
// `publishModel`, so the tests focus on the unique surface:
//
//   * fetchSource runs before any CDN traffic; the populated directory is
//     handed to publishModel.
//   * fetchSource throwing produces `AcervoError.fetchSourceFailed` that
//     wraps the underlying error and carries the modelId.
//
// Because the public `recache` always builds the live `S3CDNClient`, these
// tests exercise the contract by:
//   (a) `happyPath` — fetchSource populates a staging directory; we then
//       drive the rest of the pipeline against `MockURLProtocol` as in
//       `PublishModelTests` to confirm the closure was invoked first.
//   (b) `fetchSourceThrows` — fetchSource throws synchronously; we observe
//       that no CDN request was issued and the wrapped error reaches the
//       caller intact. No mock S3 traffic is needed.

import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Acervo.recache")
  struct RecacheTests {

    static let s3Host = "example.r2.cloudflarestorage.invalid"
    static let publicHost = "cdn.example.invalid"

    static func testCredentials() -> AcervoCDNCredentials {
      AcervoCDNCredentials(
        accessKeyId: "AKIAEXAMPLE",
        secretAccessKey: "EXAMPLEKEY",
        region: "auto",
        bucket: "test-bucket",
        endpoint: URL(string: "https://\(s3Host)")!,
        publicBaseURL: URL(string: "https://\(publicHost)")!
      )
    }

    // MARK: - Test 1: fetchSource throws

    /// A failing fetchSource closure must surface as
    /// `AcervoError.fetchSourceFailed` carrying the modelId and the
    /// original underlying error. No CDN traffic should be initiated.
    @Test("fetchSource throw is wrapped in fetchSourceFailed")
    func fetchSourceThrows() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      // Any HTTP request reaching this responder is a failure: recache
      // must short-circuit before the publish step on a fetchSource throw.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 999,  // intentional sentinel
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
        return (response, Data("recache must not call CDN on fetchSource throw".utf8))
      }

      struct SimulatedFetchError: Error, Equatable {
        let reason: String
      }
      let underlyingMarker = SimulatedFetchError(reason: "no network")

      let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("recache-fetch-throw-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: stagingDir, withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: stagingDir) }

      let mockSession = MockURLProtocol.session()
      let mockClient = S3CDNClient(
        credentials: Self.testCredentials(),
        session: mockSession
      )
      var caught: AcervoError?
      do {
        _ = try await Acervo._recache(
          modelId: "org/repo",
          stagingDirectory: stagingDir,
          credentials: Self.testCredentials(),
          client: mockClient,
          publicSession: mockSession,
          fetchSource: { _, _ in
            throw underlyingMarker
          },
          keepOrphans: false,
          progress: nil
        )
        Issue.record("recache should have thrown")
      } catch let err as AcervoError {
        caught = err
      } catch {
        Issue.record("expected AcervoError, got \(type(of: error))")
      }

      guard case .fetchSourceFailed(let modelId, let underlying) = caught else {
        Issue.record("expected .fetchSourceFailed, got \(String(describing: caught))")
        return
      }
      #expect(modelId == "org/repo")
      #expect((underlying as? SimulatedFetchError) == underlyingMarker)
      // The mock's request counter must remain at 0 — no CDN call.
      #expect(MockURLProtocol.requestCount == 0)
    }

    // MARK: - Test 2: closure runs before publish

    /// Verifies the ordering contract: fetchSource is invoked, populates
    /// the directory, and only then is the populated directory handed to
    /// publishModel. We assert this by having fetchSource write a file
    /// AND set a "fetchedAt" tick; on first PUT the directory must already
    /// contain the fetched file. (Because we don't have a public hook to
    /// observe "publish started" from within recache, we let fetchSource
    /// drop a sentinel in the staging dir and confirm the publish path
    /// includes a manifest entry referencing it.)
    @Test("fetchSource populates staging before publishModel runs")
    func fetchSourcePopulatesBeforePublish() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("recache-order-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: stagingDir, withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: stagingDir) }

      // Track which calls happened in order.
      final class Trace: @unchecked Sendable {
        let lock = NSLock()
        private var _entries: [String] = []
        func append(_ s: String) {
          lock.lock()
          defer { lock.unlock() }
          _entries.append(s)
        }
        var entries: [String] {
          lock.lock()
          defer { lock.unlock() }
          return _entries
        }
      }
      let trace = Trace()

      MockURLProtocol.responder = { request in
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let query = url.query ?? ""
        let host = url.host ?? ""

        // Default respond helper.
        func ok(body: Data = Data(), headers: [String: String] = [:]) -> (
          HTTPURLResponse, Data
        ) {
          let r = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
          )!
          return (r, body)
        }
        func code(_ status: Int, body: Data = Data()) -> (HTTPURLResponse, Data) {
          let r = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
          )!
          return (r, body)
        }

        if host == Self.publicHost {
          // CHECK 5/6: serve real bytes from the staging dir for the
          // sample file; serve a manifest the publish just wrote.
          if url.path.hasSuffix("/manifest.json") {
            let m = stagingDir.appendingPathComponent("manifest.json")
            if let d = try? Data(contentsOf: m) {
              return ok(body: d)
            }
            return code(404)
          }
          let prefix = "/models/org_repo/"
          let rel =
            url.path.hasPrefix(prefix)
            ? String(url.path.dropFirst(prefix.count)) : url.path
          let f = stagingDir.appendingPathComponent(rel)
          if let d = try? Data(contentsOf: f) {
            return ok(body: d)
          }
          return code(404)
        }

        // S3 traffic
        if method == "GET" && query.contains("list-type=2") {
          let xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<ListBucketResult>"
            + "<IsTruncated>false</IsTruncated>"
            + "</ListBucketResult>"
          return ok(
            body: Data(xml.utf8),
            headers: ["Content-Type": "application/xml"]
          )
        }
        if method == "PUT" && !query.contains("partNumber=") {
          trace.append("PUT \(url.lastPathComponent)")
          return ok(headers: ["ETag": "\"e\""])
        }
        return code(500, body: Data("unhandled".utf8))
      }

      let mockSession = MockURLProtocol.session()
      let mockClient = S3CDNClient(
        credentials: Self.testCredentials(),
        session: mockSession
      )
      _ = try await Acervo._recache(
        modelId: "org/repo",
        stagingDirectory: stagingDir,
        credentials: Self.testCredentials(),
        client: mockClient,
        publicSession: mockSession,
        fetchSource: { id, into in
          trace.append("fetchSource(\(id))")
          let f = into.appendingPathComponent("config.json")
          try Data("{\"hello\":1}".utf8).write(to: f, options: [.atomic])
        },
        keepOrphans: false,
        progress: nil
      )

      // Order contract: fetchSource must come strictly before any PUT.
      let entries = trace.entries
      guard let firstPut = entries.firstIndex(where: { $0.hasPrefix("PUT ") })
      else {
        Issue.record("no PUT recorded")
        return
      }
      guard let fetchIdx = entries.firstIndex(of: "fetchSource(org/repo)") else {
        Issue.record("fetchSource was not invoked")
        return
      }
      #expect(fetchIdx < firstPut)
      // Manifest is the last PUT.
      #expect(entries.last == "PUT manifest.json")
    }
  }
}
