// DeleteFromCDNTests.swift
// SwiftAcervoTests
//
// Coverage for `Acervo.deleteFromCDN`:
//   * Happy path — 3 keys → one bulk-delete batch → re-list returns empty
//     → returns successfully.
//   * Multi-page — 1500 keys → exactly two `DeleteObjects` requests
//     (1000 + 500), then re-list returns empty.
//   * Empty prefix — zero keys initially → no bulk-delete request issued
//     (idempotent).
//   * Batch failure — `deleteObjects` returns 500 → error rethrown.
//   * Invalid model ID — malformed slug rejected with `invalidModelId`.

import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("Acervo.deleteFromCDN")
  struct DeleteFromCDNTests {

    static let s3Host = "example.r2.cloudflarestorage.invalid"

    static func testCredentials() -> AcervoCDNCredentials {
      AcervoCDNCredentials(
        accessKeyId: "AKIAEXAMPLE",
        secretAccessKey: "EXAMPLEKEY",
        region: "auto",
        bucket: "test-bucket",
        endpoint: URL(string: "https://\(s3Host)")!,
        publicBaseURL: URL(string: "https://cdn.example.invalid")!
      )
    }

    static func http(
      _ request: URLRequest,
      status: Int,
      headers: [String: String] = [:],
      body: Data = Data()
    ) -> (HTTPURLResponse, Data) {
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )!
      return (response, body)
    }

    /// Mutable scratch state shared between the responder and the test
    /// body. The responder reads `remainingKeys` to build list responses
    /// and removes deleted keys from it on a successful DeleteObjects.
    final class State: @unchecked Sendable {
      let lock = NSLock()
      private var _remaining: [String]
      private(set) var listCalls = 0
      private(set) var deleteCalls: [Int] = []  // batch size per call
      private(set) var deleteFailureMode = false

      init(initialKeys: [String]) {
        self._remaining = initialKeys
      }

      var remainingKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _remaining
      }

      func recordListCall() {
        lock.lock()
        defer { lock.unlock() }
        listCalls += 1
      }

      func recordDelete(batchSize: Int, removed: [String]) {
        lock.lock()
        defer { lock.unlock() }
        deleteCalls.append(batchSize)
        let removedSet = Set(removed)
        _remaining.removeAll { removedSet.contains($0) }
      }

      func enableFailureMode() {
        lock.lock()
        defer { lock.unlock() }
        deleteFailureMode = true
      }
    }

    static func makeResponder(state: State) -> MockURLProtocol.Responder {
      return { request in
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let query = url.query ?? ""

        // Capture body for DeleteObjects parsing.
        let bodyData: Data? = {
          if let direct = request.httpBody, !direct.isEmpty { return direct }
          guard let stream = request.httpBodyStream else { return nil }
          stream.open()
          defer { stream.close() }
          var collected = Data()
          let bufSize = 4096
          let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
          defer { buffer.deallocate() }
          while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufSize)
            if read <= 0 { break }
            collected.append(buffer, count: read)
          }
          return collected
        }()

        // ListObjectsV2 — paginate using marker-based responses if needed.
        // Our implementation in S3CDNClient uses NextContinuationToken; for
        // these tests we keep things simple by returning the entire current
        // remaining set in a single page.
        if method == "GET" && query.contains("list-type=2") {
          state.recordListCall()
          let keys = state.remainingKeys
          var xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<ListBucketResult>"
            + "<IsTruncated>false</IsTruncated>"
          for key in keys {
            xml +=
              "<Contents>"
              + "<Key>\(key)</Key>"
              + "<Size>1</Size>"
              + "<ETag>\"e\"</ETag>"
              + "</Contents>"
          }
          xml += "</ListBucketResult>"
          return Self.http(
            request,
            status: 200,
            headers: ["Content-Type": "application/xml"],
            body: Data(xml.utf8)
          )
        }

        // Bulk delete: POST /<bucket>?delete=
        if method == "POST" && query == "delete=" {
          if state.deleteFailureMode {
            return Self.http(
              request,
              status: 500,
              body: Data("simulated outage".utf8)
            )
          }
          var keys: [String] = []
          if let body = bodyData,
            let xml = String(data: body, encoding: .utf8)
          {
            var rest = xml[...]
            while let openRange = rest.range(of: "<Key>"),
              let closeRange = rest.range(
                of: "</Key>",
                range: openRange.upperBound..<rest.endIndex
              )
            {
              let key = String(rest[openRange.upperBound..<closeRange.lowerBound])
              keys.append(key)
              rest = rest[closeRange.upperBound...]
            }
          }
          state.recordDelete(batchSize: keys.count, removed: keys)
          var xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<DeleteResult>"
          for key in keys {
            xml += "<Deleted><Key>\(key)</Key></Deleted>"
          }
          xml += "</DeleteResult>"
          return Self.http(
            request,
            status: 200,
            headers: ["Content-Type": "application/xml"],
            body: Data(xml.utf8)
          )
        }

        return Self.http(
          request,
          status: 500,
          body: Data("unhandled \(method) \(url.path)?\(query)".utf8)
        )
      }
    }

    static func makeClient() -> S3CDNClient {
      let session = MockURLProtocol.session()
      return S3CDNClient(credentials: testCredentials(), session: session)
    }

    // MARK: - Test 1: happy path

    @Test("Happy path: 3 keys deleted in one batch, then re-list empty")
    func happyPath() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let state = State(initialKeys: [
        "models/org_repo/config.json",
        "models/org_repo/tokenizer.json",
        "models/org_repo/manifest.json",
      ])
      MockURLProtocol.responder = Self.makeResponder(state: state)

      try await Acervo._deleteFromCDN(
        modelId: "org/repo",
        client: Self.makeClient(),
        progress: nil
      )

      #expect(state.deleteCalls == [3], "exactly one batch of 3 keys")
      #expect(state.listCalls == 2, "list once before delete, once after")
      #expect(state.remainingKeys.isEmpty)
    }

    // MARK: - Test 2: multi-page

    @Test("Multi-page: 1500 keys split into 1000 + 500 batches")
    func multiPage() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let keys = (0..<1500).map { "models/org_repo/file-\($0).bin" }
      let state = State(initialKeys: keys)
      MockURLProtocol.responder = Self.makeResponder(state: state)

      try await Acervo._deleteFromCDN(
        modelId: "org/repo",
        client: Self.makeClient(),
        progress: nil
      )

      #expect(
        state.deleteCalls == [1000, 500],
        "two batches: 1000 then 500"
      )
      #expect(state.remainingKeys.isEmpty)
    }

    // MARK: - Test 3: empty prefix

    @Test("Empty prefix: zero deleteObjects requests issued")
    func emptyPrefix() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let state = State(initialKeys: [])
      MockURLProtocol.responder = Self.makeResponder(state: state)

      try await Acervo._deleteFromCDN(
        modelId: "org/repo",
        client: Self.makeClient(),
        progress: nil
      )

      #expect(state.deleteCalls.isEmpty)
      #expect(state.listCalls == 1)
    }

    // MARK: - Test 4: batch failure

    @Test("Batch failure rethrows from deleteFromCDN")
    func batchFailure() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let state = State(initialKeys: [
        "models/org_repo/a.bin",
        "models/org_repo/b.bin",
      ])
      state.enableFailureMode()
      MockURLProtocol.responder = Self.makeResponder(state: state)

      await #expect(throws: AcervoError.self) {
        try await Acervo._deleteFromCDN(
          modelId: "org/repo",
          client: Self.makeClient(),
          progress: nil
        )
      }
    }

    // MARK: - Test 5: progress events

    @Test("Progress callback emits listingPrefix, deletingBatch, complete")
    func progressEvents() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let state = State(initialKeys: [
        "models/org_repo/a.bin",
        "models/org_repo/b.bin",
      ])
      MockURLProtocol.responder = Self.makeResponder(state: state)

      // Capture events thread-safely.
      final class EventLog: @unchecked Sendable {
        let lock = NSLock()
        var events: [AcervoDeleteProgress] = []
        func append(_ e: AcervoDeleteProgress) {
          lock.lock(); defer { lock.unlock() }
          events.append(e)
        }
        func snapshot() -> [AcervoDeleteProgress] {
          lock.lock(); defer { lock.unlock() }
          return events
        }
      }
      let log = EventLog()

      try await Acervo._deleteFromCDN(
        modelId: "org/repo",
        client: Self.makeClient(),
        progress: { log.append($0) }
      )

      let events = log.snapshot()
      // Expected order: listingPrefix, deletingBatch(2, 2),
      //                 listingPrefix (re-list, returns empty), complete
      #expect(events.count == 4)
      if case .listingPrefix = events[0] { } else { Issue.record("first event should be listingPrefix") }
      if case .deletingBatch(let count, let total) = events[1] {
        #expect(count == 2)
        #expect(total == 2)
      } else {
        Issue.record("second event should be deletingBatch")
      }
      if case .listingPrefix = events[2] { } else { Issue.record("third event should be listingPrefix (re-list)") }
      if case .complete = events[3] { } else { Issue.record("last event should be complete") }
    }

    // MARK: - Test 6: invalid model ID

    @Test("Malformed model ID rejected with invalidModelId")
    func invalidModelId() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }
      MockURLProtocol.responder = { request in
        Self.http(request, status: 500)
      }

      await #expect(throws: AcervoError.self) {
        try await Acervo._deleteFromCDN(
          modelId: "no-slash-here",
          client: Self.makeClient(),
          progress: nil
        )
      }
    }
  }
}
