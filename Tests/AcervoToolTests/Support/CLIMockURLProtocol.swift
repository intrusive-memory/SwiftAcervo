#if os(macOS)
  import Foundation

  /// Test-only `URLProtocol` for `AcervoToolTests`. Mirrors the
  /// `MockURLProtocol` shipped under `Tests/SwiftAcervoTests/Support/`, but
  /// scoped to this test target so the two cannot race or share static
  /// state with sibling suites.
  ///
  /// CLI tests use this to drive `VerifyCommand.fetchCDNManifest(...)` and
  /// the spot-check helper against canned responses without touching the
  /// real CDN.
  final class CLIMockURLProtocol: URLProtocol {

    typealias Responder = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responder: Responder?
    nonisolated(unsafe) private static var _requestCount: Int = 0
    nonisolated(unsafe) private static var _methodCounts: [String: Int] = [:]

    static var responder: Responder? {
      get {
        lock.lock()
        defer { lock.unlock() }
        return _responder
      }
      set {
        lock.lock()
        defer { lock.unlock() }
        _responder = newValue
      }
    }

    static var requestCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return _requestCount
    }

    /// Number of requests observed for a given HTTP method since the last
    /// `reset()`. Tests use this to assert "zero PUTs" semantics for the
    /// `--dry-run` short-circuit.
    static func requestCount(forMethod method: String) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return _methodCounts[method, default: 0]
    }

    static func reset() {
      lock.lock()
      defer { lock.unlock() }
      _responder = nil
      _requestCount = 0
      _methodCounts = [:]
    }

    /// Returns an ephemeral `URLSession` whose configuration registers
    /// `CLIMockURLProtocol` as the sole protocol class.
    static func session() -> URLSession {
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [CLIMockURLProtocol.self]
      return URLSession(configuration: config)
    }

    private static func record(method: String) {
      lock.lock()
      defer { lock.unlock() }
      _requestCount += 1
      _methodCounts[method, default: 0] += 1
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      let method = request.httpMethod ?? "GET"
      CLIMockURLProtocol.record(method: method)

      guard let responder = CLIMockURLProtocol.responder else {
        client?.urlProtocol(
          self,
          didFailWithError: URLError(.resourceUnavailable)
        )
        return
      }

      let (response, data) = responder(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }
#endif
