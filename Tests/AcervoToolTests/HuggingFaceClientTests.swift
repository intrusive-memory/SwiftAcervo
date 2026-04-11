import Foundation
import Testing

@testable import SwiftAcervo
@testable import acervo

/// Unit tests for `HuggingFaceClient` using a stubbed `URLProtocol` so no
/// network calls are made.
@Suite("HuggingFaceClient Tests", .serialized)
struct HuggingFaceClientTests {

  // MARK: - Helpers

  /// Builds a `URLSession` whose requests are intercepted by
  /// `StubURLProtocol`. Each caller is responsible for setting the
  /// stub responses before issuing the request.
  private static func makeStubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func makeTempFile(named: String = "staging.bin") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("hf-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent(named)
    try Data("payload".utf8).write(to: file)
    return file
  }

  // MARK: - buildLFSURL

  @Test("buildLFSURL produces the documented endpoint")
  func buildLFSURLHappyPath() async {
    let client = HuggingFaceClient()
    let url = await client.buildLFSURL(modelId: "org/repo", filename: "config.json")
    #expect(url.absoluteString == "https://huggingface.co/api/models/org/repo/lfs/config.json")
  }

  // MARK: - Valid JSON happy path

  @Test("verifyLFS succeeds when oid matches actualSHA256")
  func verifyLFSMatchingOIDSucceeds() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responseBody = Data("{\"oid\":\"abc123\",\"size\":4096}".utf8)
    StubURLProtocol.statusCode = 200

    let session = Self.makeStubbedSession()
    let client = HuggingFaceClient(session: session)
    let staging = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

    try await client.verifyLFS(
      modelId: "org/repo",
      filename: "config.json",
      actualSHA256: "abc123",
      stagingURL: staging
    )

    // Staging file must still exist on success.
    #expect(FileManager.default.fileExists(atPath: staging.path))
  }

  // MARK: - Mismatched SHA

  @Test("verifyLFS throws checksumMismatch when actualSHA256 differs from oid")
  func verifyLFSMismatchThrows() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responseBody = Data("{\"oid\":\"abc123\",\"size\":4096}".utf8)
    StubURLProtocol.statusCode = 200

    let session = Self.makeStubbedSession()
    let client = HuggingFaceClient(session: session)
    let staging = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

    var thrown: Error?
    do {
      try await client.verifyLFS(
        modelId: "org/repo",
        filename: "config.json",
        actualSHA256: "deadbeef",
        stagingURL: staging
      )
    } catch {
      thrown = error
    }

    guard
      case .some(HFIntegrityError.checksumMismatch(let filename, let expected, let actual)) =
        thrown
    else {
      Issue.record("Expected HFIntegrityError.checksumMismatch, got \(String(describing: thrown))")
      return
    }
    #expect(filename == "config.json")
    #expect(expected == "abc123")
    #expect(actual == "deadbeef")

    // Staging file is deleted on checksum mismatch (CHECK 1).
    #expect(!FileManager.default.fileExists(atPath: staging.path))
  }

  // MARK: - Missing oid

  @Test("verifyLFS throws missingOID when response JSON lacks the oid field")
  func verifyLFSMissingOIDThrows() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responseBody = Data("{\"size\":4096}".utf8)
    StubURLProtocol.statusCode = 200

    let session = Self.makeStubbedSession()
    let client = HuggingFaceClient(session: session)
    let staging = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

    var thrown: Error?
    do {
      try await client.verifyLFS(
        modelId: "org/repo",
        filename: "config.json",
        actualSHA256: "whatever",
        stagingURL: staging
      )
    } catch {
      thrown = error
    }

    guard case .some(HFIntegrityError.missingOID(let filename)) = thrown else {
      Issue.record("Expected HFIntegrityError.missingOID, got \(String(describing: thrown))")
      return
    }
    #expect(filename == "config.json")
  }

  // MARK: - Malformed JSON

  @Test("verifyLFS throws missingOID when response is malformed JSON")
  func verifyLFSMalformedJSONThrows() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responseBody = Data("not json at all".utf8)
    StubURLProtocol.statusCode = 200

    let session = Self.makeStubbedSession()
    let client = HuggingFaceClient(session: session)
    let staging = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

    var thrown: Error?
    do {
      try await client.verifyLFS(
        modelId: "org/repo",
        filename: "tokenizer.json",
        actualSHA256: "whatever",
        stagingURL: staging
      )
    } catch {
      thrown = error
    }

    guard case .some(HFIntegrityError.missingOID(let filename)) = thrown else {
      Issue.record("Expected HFIntegrityError.missingOID, got \(String(describing: thrown))")
      return
    }
    #expect(filename == "tokenizer.json")
  }

  // MARK: - HTTP error

  @Test("verifyLFS throws httpError on non-2xx status")
  func verifyLFSHTTPError() async throws {
    StubURLProtocol.reset()
    StubURLProtocol.responseBody = Data("not found".utf8)
    StubURLProtocol.statusCode = 404

    let session = Self.makeStubbedSession()
    let client = HuggingFaceClient(session: session)
    let staging = try makeTempFile()
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

    var thrown: Error?
    do {
      try await client.verifyLFS(
        modelId: "org/repo",
        filename: "missing.bin",
        actualSHA256: "whatever",
        stagingURL: staging
      )
    } catch {
      thrown = error
    }

    guard case .some(HFIntegrityError.httpError(let status, let filename)) = thrown else {
      Issue.record("Expected HFIntegrityError.httpError, got \(String(describing: thrown))")
      return
    }
    #expect(status == 404)
    #expect(filename == "missing.bin")
  }
}

// MARK: - Stub URLProtocol

/// Minimal `URLProtocol` stub that returns a caller-supplied body/status for
/// every request. Mutation happens through static state so the stub can be
/// installed on a `URLSessionConfiguration` without escaping sendability.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

  nonisolated(unsafe) static var responseBody: Data = Data()
  nonisolated(unsafe) static var statusCode: Int = 200

  static func reset() {
    responseBody = Data()
    statusCode = 200
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url ?? URL(string: "https://stub.invalid/")!
    let response = HTTPURLResponse(
      url: url,
      statusCode: Self.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.responseBody)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
