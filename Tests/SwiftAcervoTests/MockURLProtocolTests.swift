import Foundation
import Testing

@testable import SwiftAcervo

/// Shared parent suite for every test that manipulates `MockURLProtocol`'s
/// static state. The `.serialized` trait on this enclosing suite forces all
/// contained tests (including those in nested suites) to run one at a time,
/// which is required because Swift Testing otherwise executes distinct
/// `@Suite` types in parallel and would race on the mock's shared storage.
@Suite("MockURLProtocol", .serialized)
struct MockURLProtocolSuite {

  /// Smoke tests for the `MockURLProtocol` test harness.
  @Suite("Harness")
  struct Harness {

    @Test("Responder returns canned body and request count increments")
    func respondsWithCannedBody() async throws {
      MockURLProtocol.reset()
      defer { MockURLProtocol.reset() }

      let expectedBody = Data("hello-mock".utf8)
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/plain"]
        )!
        return (response, expectedBody)
      }

      let session = MockURLProtocol.session()
      let url = URL(string: "https://example.invalid/anything")!
      let (data, response) = try await session.data(for: URLRequest(url: url))

      #expect(data == expectedBody)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      #expect(MockURLProtocol.requestCount == 1)
    }

    @Test("reset() clears responder and zeroes request count")
    func resetClearsState() async throws {
      MockURLProtocol.responder = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 200,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )!
        return (response, Data())
      }
      let session = MockURLProtocol.session()
      _ = try? await session.data(for: URLRequest(url: URL(string: "https://example.invalid/a")!))

      MockURLProtocol.reset()

      #expect(MockURLProtocol.requestCount == 0)
      #expect(MockURLProtocol.responder == nil)
    }
  }
}
