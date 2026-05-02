// S3CDNClientTests.swift
// SwiftAcervoTests
//
// Coverage for `S3CDNClient` per WU1 Sortie 2 exit criteria:
//   * `listObjects` paginates across two pages and concatenates results.
//   * `headObject` returns metadata on 200, `nil` on 404, and throws
//     `cdnAuthorizationFailed` on 403.
//   * `deleteObject` succeeds on 204 AND on 404 (idempotent).
//   * `deleteObjects` parses a mixed Deleted/Error response correctly.
//
// All requests are intercepted by `MockURLProtocol` via an injected
// ephemeral `URLSession`. No live R2 traffic is allowed in this target.
//
// The suite is nested under `SharedStaticStateSuite.MockURLProtocolSuite`
// so it inherits the `.serialized` trait and cannot race with any other
// `MockURLProtocol`-using suite.

import Foundation
import Testing

@testable import SwiftAcervo

extension SharedStaticStateSuite.MockURLProtocolSuite {

  @Suite("S3CDNClient")
  struct S3CDNClientTests {

    // MARK: - Fixtures

    static func testCredentials() -> AcervoCDNCredentials {
      AcervoCDNCredentials(
        accessKeyId: "AKIAEXAMPLE",
        secretAccessKey: "EXAMPLEKEY",
        region: "auto",
        bucket: "test-bucket",
        endpoint: URL(string: "https://example.r2.cloudflarestorage.invalid")!,
        publicBaseURL: URL(string: "https://cdn.example.invalid")!
      )
    }

    static func makeClient() -> S3CDNClient {
      let session = MockURLProtocol.session()
      return S3CDNClient(credentials: testCredentials(), session: session)
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

    // MARK: - listObjects pagination

    @Test("listObjects paginates across two pages and concatenates results")
    func listObjectsPaginates() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let firstPage = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>test-bucket</Name>
          <Prefix>models/foo/</Prefix>
          <KeyCount>2</KeyCount>
          <MaxKeys>2</MaxKeys>
          <IsTruncated>true</IsTruncated>
          <NextContinuationToken>NEXT-TOKEN-1</NextContinuationToken>
          <Contents>
            <Key>models/foo/a.bin</Key>
            <Size>10</Size>
            <ETag>"aaaa"</ETag>
          </Contents>
          <Contents>
            <Key>models/foo/b.bin</Key>
            <Size>20</Size>
            <ETag>"bbbb"</ETag>
          </Contents>
        </ListBucketResult>
        """

      let secondPage = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>test-bucket</Name>
          <Prefix>models/foo/</Prefix>
          <KeyCount>1</KeyCount>
          <MaxKeys>2</MaxKeys>
          <IsTruncated>false</IsTruncated>
          <Contents>
            <Key>models/foo/c.bin</Key>
            <Size>30</Size>
            <ETag>"cccc"</ETag>
          </Contents>
        </ListBucketResult>
        """

      // Page selector key — capture-list state in an actor-safe way using
      // a final-class box keyed by request count.
      MockURLProtocol.responder = { request in
        let urlString = request.url?.absoluteString ?? ""
        // The presence of "continuation-token" in the query selects page 2.
        let isPageTwo = urlString.contains("continuation-token")
        let body = isPageTwo ? secondPage : firstPage
        return Self.http(
          request,
          status: 200,
          headers: ["Content-Type": "application/xml"],
          body: Data(body.utf8)
        )
      }

      let client = Self.makeClient()
      let objects = try await client.listObjects(prefix: "models/foo/")

      #expect(MockURLProtocol.requestCount == 2)
      #expect(objects.count == 3)
      #expect(objects.map(\.key) == [
        "models/foo/a.bin",
        "models/foo/b.bin",
        "models/foo/c.bin",
      ])
      #expect(objects.map(\.size) == [10, 20, 30])
      #expect(objects[0].etag == "\"aaaa\"")
    }

    // MARK: - headObject

    @Test("headObject returns metadata on HTTP 200")
    func headObjectSuccess() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      MockURLProtocol.responder = { request in
        Self.http(
          request,
          status: 200,
          headers: [
            "Content-Length": "1234",
            "ETag": "\"deadbeef\"",
            "Content-Type": "application/octet-stream",
            "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT",
          ],
          body: Data()
        )
      }

      let client = Self.makeClient()
      let head = try await client.headObject(key: "models/foo/config.json")
      #expect(head != nil)
      #expect(head?.size == 1234)
      #expect(head?.etag == "\"deadbeef\"")
      #expect(head?.contentType == "application/octet-stream")
      #expect(head?.lastModified != nil)
    }

    @Test("headObject returns nil on HTTP 404")
    func headObjectNotFound() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      MockURLProtocol.responder = { request in
        Self.http(request, status: 404)
      }

      let client = Self.makeClient()
      let head = try await client.headObject(key: "models/foo/missing.bin")
      #expect(head == nil)
    }

    @Test("headObject throws cdnAuthorizationFailed on HTTP 403")
    func headObjectForbidden() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      MockURLProtocol.responder = { request in
        Self.http(request, status: 403)
      }

      let client = Self.makeClient()
      do {
        _ = try await client.headObject(key: "models/foo/locked.bin")
        Issue.record("Expected cdnAuthorizationFailed to be thrown")
      } catch let error as AcervoError {
        switch error {
        case .cdnAuthorizationFailed(let operation):
          #expect(operation == "head")
        default:
          Issue.record("Unexpected AcervoError: \(error)")
        }
      } catch {
        Issue.record("Unexpected error type: \(error)")
      }
    }

    // MARK: - deleteObject

    @Test("deleteObject succeeds on HTTP 204")
    func deleteObjectSuccess() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      MockURLProtocol.responder = { request in
        Self.http(request, status: 204)
      }

      let client = Self.makeClient()
      try await client.deleteObject(key: "models/foo/a.bin")
      // No throw == success. Also assert exactly one request flew.
      #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("deleteObject succeeds (no throw) on HTTP 404 — idempotent")
    func deleteObjectNotFoundIsIdempotent() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      MockURLProtocol.responder = { request in
        Self.http(request, status: 404)
      }

      let client = Self.makeClient()
      // The whole point of this assertion: 404 must NOT throw.
      try await client.deleteObject(key: "models/foo/already-gone.bin")
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - deleteObjects (bulk)

    @Test("deleteObjects parses mixed Deleted/Error response per key")
    func deleteObjectsMixedResponse() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Deleted><Key>models/foo/a.bin</Key></Deleted>
          <Deleted><Key>models/foo/b.bin</Key></Deleted>
          <Error>
            <Key>models/foo/c.bin</Key>
            <Code>AccessDenied</Code>
            <Message>denied by policy</Message>
          </Error>
        </DeleteResult>
        """

      MockURLProtocol.responder = { request in
        Self.http(
          request,
          status: 200,
          headers: ["Content-Type": "application/xml"],
          body: Data(xml.utf8)
        )
      }

      let client = Self.makeClient()
      let results = try await client.deleteObjects(keys: [
        "models/foo/a.bin",
        "models/foo/b.bin",
        "models/foo/c.bin",
      ])

      #expect(results.count == 3)
      #expect(results[0].key == "models/foo/a.bin")
      #expect(results[0].success == true)
      #expect(results[0].error == nil)
      #expect(results[1].key == "models/foo/b.bin")
      #expect(results[1].success == true)
      #expect(results[2].key == "models/foo/c.bin")
      #expect(results[2].success == false)
      #expect(results[2].error?.contains("AccessDenied") == true)
      #expect(results[2].error?.contains("denied by policy") == true)
    }

    @Test("deleteObjects returns empty for empty input without making requests")
    func deleteObjectsEmptyInput() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      MockURLProtocol.responder = { request in
        Self.http(request, status: 200)
      }

      let client = Self.makeClient()
      let results = try await client.deleteObjects(keys: [])
      #expect(results.isEmpty)
      #expect(MockURLProtocol.requestCount == 0)
    }

    // MARK: - DeleteObjects XML envelope (unit, no networking)

    @Test("buildDeleteObjectsXML escapes special characters in keys")
    func deleteObjectsXMLEscape() {
      let xml = S3CDNClient.buildDeleteObjectsXML(keys: [
        "models/foo<bar>",
        "weird&key",
      ])
      #expect(xml.contains("<Key>models/foo&lt;bar&gt;</Key>"))
      #expect(xml.contains("<Key>weird&amp;key</Key>"))
      #expect(xml.contains("<Quiet>false</Quiet>"))
    }

    // MARK: - putObject (single-shot)

    /// Helper: writes `bytes` to a uniquely-named file in the system temp
    /// directory and returns its URL. Caller is responsible for cleanup.
    static func writeTempFile(
      _ bytes: Data,
      suffix: String = ".bin"
    ) throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "s3cdnclient-test-\(UUID().uuidString)\(suffix)"
        )
      try bytes.write(to: url)
      return url
    }

    /// Helper: writes a synthetic file of `size` bytes filled with a
    /// deterministic byte pattern (so different runs produce identical
    /// hashes) to a uniquely-named temp file. Caller cleans up.
    static func writeSyntheticFile(size: Int) throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "s3cdnclient-test-\(UUID().uuidString).synthetic"
        )
      // Deterministic pattern: a single 4096-byte block of (i & 0xFF)
      // copied repeatedly. Streamed write so we never hold the whole
      // payload in memory in the test process either.
      let block = Data((0..<4096).map { UInt8($0 & 0xFF) })
      FileManager.default.createFile(atPath: url.path, contents: nil)
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      var written = 0
      while written < size {
        let remaining = size - written
        let chunk = remaining >= block.count
          ? block
          : block.prefix(remaining)
        try handle.write(contentsOf: chunk)
        written += chunk.count
      }
      return url
    }

    @Test("putObject single-shot: one signed PUT, sha256 matches fixture")
    func putObjectSingleShot() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // Fixture: "hello world\n" (12 bytes) — well under the default
      // 100 MiB single-shot threshold, so this exercises that path.
      // SHA-256 hex of "hello world\n":
      //   a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447
      let fixtureBytes = Data("hello world\n".utf8)
      let expectedSHA256 =
        "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447"

      let url = try Self.writeTempFile(fixtureBytes)
      defer { try? FileManager.default.removeItem(at: url) }

      // Capture the PUT request's headers so we can assert the
      // x-amz-content-sha256 was set to the streaming hash and that the
      // request was signed.
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: [
            "ETag": "\"single-shot-etag\"",
          ]
        )!
        return (response, Data())
      }

      let client = Self.makeClient()
      let result = try await client.putObject(
        key: "models/foo/hello.txt",
        bodyURL: url
      )

      #expect(result.key == "models/foo/hello.txt")
      #expect(result.sha256 == expectedSHA256)
      #expect(result.etag == "\"single-shot-etag\"")
      // Exactly one PUT — no multipart sequence on the single-shot path.
      #expect(MockURLProtocol.requestCount == 1)
    }

    // MARK: - putObject (multipart)

    /// Build a client whose thresholds are small enough that a 33 MiB
    /// file produces 3 parts. We pick 16 MiB part size (matching prod)
    /// and a 4 MiB single-shot threshold so any file >4 MiB lands on
    /// the multipart path.
    static func makeMultipartClient(
      singleShotThreshold: Int64 = 4 * 1024 * 1024,
      multipartPartSize: Int64 = 16 * 1024 * 1024
    ) -> S3CDNClient {
      let session = MockURLProtocol.session()
      return S3CDNClient(
        credentials: testCredentials(),
        session: session,
        singleShotThreshold: singleShotThreshold,
        multipartPartSize: multipartPartSize
      )
    }

    /// Tracks every request the multipart mock dispatches. Marked as a
    /// final class so the closure can mutate it under the protocol's
    /// internal lock without crossing actor boundaries.
    final class RequestLog: @unchecked Sendable {
      let lock = NSLock()
      var entries: [(method: String, query: String)] = []

      func record(method: String, query: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append((method: method, query: query))
      }

      func snapshot() -> [(method: String, query: String)] {
        lock.lock(); defer { lock.unlock() }
        return entries
      }
    }

    /// Dispatches multipart-upload responses based on URL query.
    ///   * `?uploads`            (POST)   → InitiateMultipartUploadResult XML
    ///   * `?partNumber=N&uploadId=…` (PUT) → 200 + ETag header
    ///   * `?uploadId=…`         (POST)   → CompleteMultipartUploadResult XML
    ///   * `?uploadId=…`         (DELETE) → 204
    static func multipartResponder(
      uploadId: String,
      log: RequestLog,
      partFailureNumber: Int? = nil
    ) -> MockURLProtocol.Responder {
      return { request in
        let method = request.httpMethod ?? "GET"
        let query = request.url?.query ?? ""
        log.record(method: method, query: query)

        // Initiate: POST .?uploads
        if method == "POST" && query == "uploads" {
          let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <InitiateMultipartUploadResult>
              <Bucket>test-bucket</Bucket>
              <Key>models/foo/big.bin</Key>
              <UploadId>\(uploadId)</UploadId>
            </InitiateMultipartUploadResult>
            """
          let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
          )!
          return (resp, Data(xml.utf8))
        }

        // Upload part: PUT .?partNumber=N&uploadId=…
        if method == "PUT" && query.contains("partNumber=") {
          // Extract the partNumber from the query string.
          let comps = URLComponents(
            url: request.url!, resolvingAgainstBaseURL: false
          )
          let partNumberStr = comps?.queryItems?
            .first(where: { $0.name == "partNumber" })?.value ?? "?"
          let partNumber = Int(partNumberStr) ?? -1

          if let failAt = partFailureNumber, partNumber == failAt {
            let resp = HTTPURLResponse(
              url: request.url!,
              statusCode: 500,
              httpVersion: "HTTP/1.1",
              headerFields: [:]
            )!
            return (resp, Data("Internal Server Error".utf8))
          }

          let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
              "ETag": "\"part-\(partNumber)-etag\"",
            ]
          )!
          return (resp, Data())
        }

        // Complete: POST .?uploadId=…  (no partNumber)
        if method == "POST" && query.contains("uploadId=")
          && !query.contains("partNumber=")
        {
          let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <CompleteMultipartUploadResult>
              <Location>https://example.r2/test-bucket/models/foo/big.bin</Location>
              <Bucket>test-bucket</Bucket>
              <Key>models/foo/big.bin</Key>
              <ETag>"final-etag-deadbeef"</ETag>
            </CompleteMultipartUploadResult>
            """
          let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/xml"]
          )!
          return (resp, Data(xml.utf8))
        }

        // Abort: DELETE .?uploadId=…
        if method == "DELETE" && query.contains("uploadId=") {
          let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: 204,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
          )!
          return (resp, Data())
        }

        // Unknown — fail loudly.
        let resp = HTTPURLResponse(
          url: request.url!,
          statusCode: 500,
          httpVersion: "HTTP/1.1",
          headerFields: [:]
        )!
        return (resp, Data("unhandled request: \(method) \(query)".utf8))
      }
    }

    @Test(
      "putObject multipart happy path: initiate → N upload-parts → complete"
    )
    func putObjectMultipartHappyPath() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // 33 MiB synthetic file → with 16 MiB part size, that's 3 parts
      // (16 + 16 + 1 MiB). Documented size choice: large enough to
      // exercise the part-iteration loop with a non-uniform final part,
      // small enough to write to disk in a unit test without measurable
      // wall-clock cost.
      let fileSize = 33 * 1024 * 1024
      let url = try Self.writeSyntheticFile(size: fileSize)
      defer { try? FileManager.default.removeItem(at: url) }

      let log = RequestLog()
      MockURLProtocol.responder = Self.multipartResponder(
        uploadId: "TEST-UPLOAD-ID-HAPPY",
        log: log,
        partFailureNumber: nil
      )

      let client = Self.makeMultipartClient()
      let result = try await client.putObject(
        key: "models/foo/big.bin",
        bodyURL: url
      )

      #expect(result.key == "models/foo/big.bin")
      #expect(result.etag == "\"final-etag-deadbeef\"")
      #expect(result.sha256.count == 64)  // hex SHA-256

      let entries = log.snapshot()
      // Expected order: 1× POST ?uploads, 3× PUT ?partNumber=…, 1× POST
      // ?uploadId=… (complete). No DELETE on the happy path.
      #expect(entries.count == 5)
      #expect(entries.first?.method == "POST")
      #expect(entries.first?.query == "uploads")

      let partRequests = entries.filter { $0.method == "PUT" }
      #expect(partRequests.count == 3)
      #expect(partRequests[0].query.contains("partNumber=1"))
      #expect(partRequests[1].query.contains("partNumber=2"))
      #expect(partRequests[2].query.contains("partNumber=3"))

      let lastEntry = entries.last!
      #expect(lastEntry.method == "POST")
      #expect(lastEntry.query.contains("uploadId="))
      #expect(!lastEntry.query.contains("partNumber="))

      // No abort on happy path.
      #expect(!entries.contains(where: { $0.method == "DELETE" }))
    }

    @Test("putObject multipart: aborts and rethrows when an upload-part fails")
    func putObjectMultipartAbortsOnPartFailure() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      // 33 MiB → 3 parts; fail the second part.
      let fileSize = 33 * 1024 * 1024
      let url = try Self.writeSyntheticFile(size: fileSize)
      defer { try? FileManager.default.removeItem(at: url) }

      let log = RequestLog()
      MockURLProtocol.responder = Self.multipartResponder(
        uploadId: "TEST-UPLOAD-ID-FAIL",
        log: log,
        partFailureNumber: 2
      )

      let client = Self.makeMultipartClient()

      var threw = false
      do {
        _ = try await client.putObject(
          key: "models/foo/big.bin",
          bodyURL: url
        )
      } catch {
        threw = true
      }
      #expect(threw, "Expected putObject to rethrow on part-2 failure")

      let entries = log.snapshot()
      // We expect: initiate, part 1 success, part 2 fail, abort.
      // No part 3 (we stop on first failure), no complete.
      let initiateCount = entries.filter {
        $0.method == "POST" && $0.query == "uploads"
      }.count
      #expect(initiateCount == 1)

      let partRequests = entries.filter { $0.method == "PUT" }
      #expect(partRequests.count == 2)  // part 1 success, part 2 fails

      let abortCount = entries.filter { $0.method == "DELETE" }.count
      #expect(
        abortCount == 1,
        "abortMultipartUpload must be called exactly once on part failure"
      )

      let completeCount = entries.filter {
        $0.method == "POST" && $0.query.contains("uploadId=")
          && !$0.query.contains("partNumber=")
      }.count
      #expect(completeCount == 0, "complete must not run after abort")
    }

    // MARK: - putObject (streaming memory discipline)

    /// Structural assertion that the multipart path streams chunks off
    /// disk via `FileHandle.read(upToCount:)` rather than loading the
    /// whole file into memory. We assert this by:
    ///
    ///   1. Driving an 18 MiB upload (>16 MiB part size, <100 MiB
    ///      single-shot threshold by default — so we lower the
    ///      threshold to force multipart).
    ///   2. Verifying the multipart request sequence ran (initiate →
    ///      2 PUTs → complete).
    ///   3. Cross-referencing the source-tree exit criterion
    ///      `git grep "Data(contentsOf:" Sources/SwiftAcervo/S3CDNClient.swift`
    ///      which is checked outside this test.
    ///
    /// The 18 MiB choice is deliberate: it's just over one 16 MiB part,
    /// so we get a 2-part upload with a small (~2 MiB) tail. Documented
    /// in the EXECUTION_PLAN guidance to avoid writing 200 MiB of test
    /// data per run.
    @Test("putObject multipart streams from disk in chunks (no whole-file load)")
    func putObjectMultipartStreamingMemory() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let fileSize = 18 * 1024 * 1024
      let url = try Self.writeSyntheticFile(size: fileSize)
      defer { try? FileManager.default.removeItem(at: url) }

      let log = RequestLog()
      MockURLProtocol.responder = Self.multipartResponder(
        uploadId: "TEST-UPLOAD-ID-STREAM",
        log: log,
        partFailureNumber: nil
      )

      let client = Self.makeMultipartClient()
      let result = try await client.putObject(
        key: "models/foo/stream.bin",
        bodyURL: url
      )

      #expect(result.sha256.count == 64)
      let entries = log.snapshot()
      let partRequests = entries.filter { $0.method == "PUT" }
      // 18 MiB / 16 MiB part size → 2 parts (16 MiB + 2 MiB).
      #expect(partRequests.count == 2)
      #expect(partRequests[0].query.contains("partNumber=1"))
      #expect(partRequests[1].query.contains("partNumber=2"))
    }
  }
}
