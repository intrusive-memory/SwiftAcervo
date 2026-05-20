import Foundation

@testable import SwiftAcervo

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
  ///
  /// The session is constructed with a `SecureDownloadDelegate` so that
  /// streaming downloads (which flow through a delegate-driven chunked
  /// path rather than `URLSession.AsyncBytes`) receive their chunks. A
  /// fresh delegate instance is used per test session so tests do not
  /// share state.
  static func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let delegate = SecureDownloadDelegate()
    return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
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

    // If the responder returned a 3xx response with a `Location` header,
    // simulate a genuine HTTP redirect by routing it through URLSession's
    // redirect plumbing. URLSession will consult the session delegate's
    // `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
    // before deciding to follow. To prevent hangs in the rejected-redirect
    // path, we also explicitly fail the underlying task — URLSession
    // delivers the failure to the data task regardless of which branch
    // `willPerformHTTPRedirection` takes for this synthetic test.
    if (300..<400).contains(response.statusCode),
      let locationString = response.value(forHTTPHeaderField: "Location"),
      let locationURL = URL(string: locationString)
    {
      var newRequest = URLRequest(url: locationURL)
      newRequest.httpMethod = self.request.httpMethod
      client?.urlProtocol(
        self,
        wasRedirectedTo: newRequest,
        redirectResponse: response
      )
      // Ensure the protocol does not hang waiting for URLSession's
      // redirect decision: surface an explicit cancellation so the task's
      // delegate receives `didCompleteWithError`. In production the
      // SecureDownloadDelegate would reject the non-CDN redirect; in the
      // test, URLSession arrives at the same end-state (task fails)
      // either via the delegate or via this explicit cancel.
      client?.urlProtocol(
        self,
        didFailWithError: URLError(.cancelled)
      )
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
