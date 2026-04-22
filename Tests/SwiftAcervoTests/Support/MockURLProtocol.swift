import Foundation

/// Test-only `URLProtocol` that intercepts every request on sessions it is
/// registered with and dispatches to a caller-supplied responder closure.
///
/// Responder state is guarded by an internal `NSLock` so the class is safe
/// to use from concurrent tests under Swift 6 strict concurrency. The
/// `nonisolated(unsafe)` storage is mediated exclusively through the
/// lock-protected accessors below.
final class MockURLProtocol: URLProtocol {

  /// Signature of the responder closure. Given a request, returns the
  /// `HTTPURLResponse` and body `Data` that the mock should deliver.
  typealias Responder = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _responder: Responder?
  nonisolated(unsafe) private static var _requestCount: Int = 0

  /// The currently registered responder, if any. Setting `nil` disables
  /// interception (the mock will fail the request with `URLError(.resourceUnavailable)`).
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

  /// Total number of requests the mock has received since the last `reset()`.
  static var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _requestCount
  }

  /// Clears any registered responder and zeroes the request counter.
  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    _responder = nil
    _requestCount = 0
  }

  /// Returns an ephemeral `URLSession` whose configuration registers
  /// `MockURLProtocol` as the sole protocol class. Use this to drive code
  /// paths that take a `URLSession` parameter.
  static func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
  }

  private static func incrementRequestCount() {
    lock.lock()
    defer { lock.unlock() }
    _requestCount += 1
  }

  // MARK: - URLProtocol

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    MockURLProtocol.incrementRequestCount()

    guard let responder = MockURLProtocol.responder else {
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
