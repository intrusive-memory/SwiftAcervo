#if os(macOS)
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
        Issue.record(
          "Expected HFIntegrityError.checksumMismatch, got \(String(describing: thrown))")
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

    // MARK: - Tree URL construction

    @Test("buildTreeURL produces the documented endpoint with recursive=true")
    func buildTreeURLHappyPath() async {
      let client = HuggingFaceClient()
      let url = await client.buildTreeURL(modelId: "org/repo", revision: "main")
      #expect(
        url.absoluteString
          == "https://huggingface.co/api/models/org/repo/tree/main?recursive=true"
      )
    }

    // MARK: - Tree fetch

    @Test("fetchRepoFiles decodes file entries and skips directories")
    func fetchRepoFilesDecodes() async throws {
      StubURLProtocol.reset()
      let body = """
        [
          {"type": "file", "path": "config.json", "size": 1024, "oid": "abc"},
          {"type": "directory", "path": "subfolder", "oid": "def"},
          {"type": "file", "path": "model.safetensors", "size": 2400000000,
           "oid": "ghi", "xetHash": "xet-1234"}
        ]
        """
      StubURLProtocol.register(match: "/tree/main", body: Data(body.utf8))

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)
      let files = try await client.fetchRepoFiles(modelId: "org/repo")

      #expect(files.count == 2)
      #expect(files[0].path == "config.json")
      #expect(files[0].size == 1024)
      #expect(files[0].isXet == false)
      #expect(files[1].path == "model.safetensors")
      #expect(files[1].size == 2400000000)
      #expect(files[1].isXet == true)
    }

    @Test("fetchRepoFiles falls back from main to master on 404")
    func fetchRepoFilesFallsBackToMaster() async throws {
      StubURLProtocol.reset()
      StubURLProtocol.register(match: "/tree/main", statusCode: 404, body: Data("{}".utf8))
      let body = #"[{"type":"file","path":"README.md","size":42,"oid":"xyz"}]"#
      StubURLProtocol.register(match: "/tree/master", body: Data(body.utf8))

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)
      let files = try await client.fetchRepoFiles(modelId: "legacy/repo")

      #expect(files.count == 1)
      #expect(files[0].path == "README.md")
    }

    @Test("fetchRepoFiles surfaces non-404 errors immediately")
    func fetchRepoFilesNon404Surfaces() async throws {
      StubURLProtocol.reset()
      StubURLProtocol.register(match: "/tree/", statusCode: 401, body: Data("{}".utf8))

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)

      var thrown: Error?
      do {
        _ = try await client.fetchRepoFiles(modelId: "org/repo")
      } catch {
        thrown = error
      }

      guard case .some(HFTreeError.httpError(let status, _)) = thrown else {
        Issue.record("Expected HFTreeError.httpError, got \(String(describing: thrown))")
        return
      }
      #expect(status == 401)
    }

    // MARK: - Completeness verification

    @Test("verifyDownloadCompleteness returns empty when sizes match")
    func verifyCompletenessSuccess() async throws {
      StubURLProtocol.reset()
      let body = """
        [
          {"type":"file","path":"config.json","size":7,"oid":"a"},
          {"type":"file","path":"weights.bin","size":13,"oid":"b","xetHash":"x"}
        ]
        """
      StubURLProtocol.register(match: "/tree/", body: Data(body.utf8))

      let staging = try makeStagingDir()
      defer { try? FileManager.default.removeItem(at: staging) }
      try Data("payload".utf8).write(to: staging.appendingPathComponent("config.json"))
      try Data("hello world!!".utf8)
        .write(to: staging.appendingPathComponent("weights.bin"))

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)
      let failures = try await client.verifyDownloadCompleteness(
        modelId: "org/repo",
        stagingURL: staging,
        requestedFiles: []
      )
      #expect(failures.isEmpty)
    }

    @Test("verifyDownloadCompleteness flags missing files")
    func verifyCompletenessMissing() async throws {
      StubURLProtocol.reset()
      let body = """
        [
          {"type":"file","path":"config.json","size":7,"oid":"a"},
          {"type":"file","path":"weights.bin","size":13,"oid":"b","xetHash":"x"}
        ]
        """
      StubURLProtocol.register(match: "/tree/", body: Data(body.utf8))

      let staging = try makeStagingDir()
      defer { try? FileManager.default.removeItem(at: staging) }
      try Data("payload".utf8).write(to: staging.appendingPathComponent("config.json"))
      // weights.bin intentionally absent.

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)
      let failures = try await client.verifyDownloadCompleteness(
        modelId: "org/repo",
        stagingURL: staging,
        requestedFiles: []
      )
      #expect(failures.count == 1)
      #expect(failures[0].path == "weights.bin")
      #expect(failures[0].isXet == true)
      guard case .missing = failures[0].reason else {
        Issue.record("Expected .missing, got \(failures[0].reason)")
        return
      }
    }

    @Test("verifyDownloadCompleteness flags size mismatches (silent Xet failure)")
    func verifyCompletenessSizeMismatch() async throws {
      StubURLProtocol.reset()
      let body = """
        [
          {"type":"file","path":"model.safetensors","size":2400000000,
           "oid":"a","xetHash":"x"}
        ]
        """
      StubURLProtocol.register(match: "/tree/", body: Data(body.utf8))

      let staging = try makeStagingDir()
      defer { try? FileManager.default.removeItem(at: staging) }
      // Simulate the bug: hf wrote a tiny metadata sidecar instead of
      // the 2.4 GB blob. The size mismatch should be detected.
      try Data("stub".utf8)
        .write(to: staging.appendingPathComponent("model.safetensors"))

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)
      let failures = try await client.verifyDownloadCompleteness(
        modelId: "org/repo",
        stagingURL: staging,
        requestedFiles: []
      )
      #expect(failures.count == 1)
      #expect(failures[0].isXet == true)
      guard case .sizeMismatch(let expected, let actual) = failures[0].reason else {
        Issue.record("Expected .sizeMismatch, got \(failures[0].reason)")
        return
      }
      #expect(expected == 2400000000)
      #expect(actual == 4)
    }

    @Test("verifyDownloadCompleteness honors requestedFiles filter")
    func verifyCompletenessFilter() async throws {
      StubURLProtocol.reset()
      let body = """
        [
          {"type":"file","path":"config.json","size":7,"oid":"a"},
          {"type":"file","path":"weights.bin","size":13,"oid":"b"}
        ]
        """
      StubURLProtocol.register(match: "/tree/", body: Data(body.utf8))

      let staging = try makeStagingDir()
      defer { try? FileManager.default.removeItem(at: staging) }
      try Data("payload".utf8).write(to: staging.appendingPathComponent("config.json"))
      // weights.bin intentionally absent — but we don't request it.

      let session = Self.makeStubbedSession()
      let client = HuggingFaceClient(session: session)
      let failures = try await client.verifyDownloadCompleteness(
        modelId: "org/repo",
        stagingURL: staging,
        requestedFiles: ["config.json"]
      )
      #expect(failures.isEmpty)
    }

    // MARK: - Helpers (shared)

    private func makeStagingDir() throws -> URL {
      let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("hf-completeness-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
  }

  // MARK: - Stub URLProtocol

  /// Minimal `URLProtocol` stub that returns a caller-supplied body/status for
  /// every request. Mutation happens through static state so the stub can be
  /// installed on a `URLSessionConfiguration` without escaping sendability.
  ///
  /// Two response modes:
  ///   - **Default mode** — set `responseBody` and `statusCode`; every
  ///     request gets the same canned response (used by the LFS tests).
  ///   - **Per-URL mode** — populate `routedResponses` with substring →
  ///     response mappings; the first substring that appears in the
  ///     incoming `request.url.absoluteString` wins. Useful when a test
  ///     issues multiple requests to different endpoints (e.g. the tree
  ///     endpoint with cursor-based pagination).
  final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Response: Sendable {
      let statusCode: Int
      let body: Data
      let headers: [String: String]
    }

    nonisolated(unsafe) static var responseBody: Data = Data()
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var routedResponses: [(match: String, response: Response)] = []

    static func reset() {
      responseBody = Data()
      statusCode = 200
      routedResponses = []
    }

    /// Registers a per-URL response. The earliest registration whose
    /// `match` substring appears in the request URL wins, so call this
    /// in priority order.
    static func register(
      match: String,
      statusCode: Int = 200,
      body: Data,
      headers: [String: String] = ["Content-Type": "application/json"]
    ) {
      routedResponses.append(
        (match: match, response: Response(statusCode: statusCode, body: body, headers: headers))
      )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let url = request.url ?? URL(string: "https://stub.invalid/")!
      let absolute = url.absoluteString

      let resolved: Response =
        Self.routedResponses.first(where: { absolute.contains($0.match) })?.response
        ?? Response(
          statusCode: Self.statusCode,
          body: Self.responseBody,
          headers: ["Content-Type": "application/json"]
        )

      let response = HTTPURLResponse(
        url: url,
        statusCode: resolved.statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: resolved.headers
      )!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: resolved.body)
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }
#endif
