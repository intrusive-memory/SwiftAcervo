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
  }
}
