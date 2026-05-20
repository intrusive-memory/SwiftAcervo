// SecureDownloadSession.swift
// SwiftAcervo
//
// A URLSession configured to reject redirects to non-CDN domains and to
// deliver HTTP responses to the streaming downloader as chunks rather
// than byte-by-byte.
//
// All model downloads MUST use this session (or another session that uses
// `SecureDownloadDelegate`) instead of `URLSession.shared`. This prevents
// a compromised DNS or CDN from silently redirecting downloads to a
// malicious server.

import Foundation

/// A single chunk-stream consumer attached to one in-flight `URLSessionDataTask`.
///
/// Owns the AsyncThrowingStream continuation that the streaming downloader
/// reads from. The delegate forwards every `didReceive data:` into `yield(...)`
/// and forwards `didCompleteWithError(error:)` into `finish(throwing:)`.
///
/// `ChunkConsumer` is a final class so the delegate can store stable
/// references in its per-task registry.
final class ChunkConsumer: @unchecked Sendable {

  /// Stream that the caller reads chunks from. Created at init time and
  /// passed straight through to the streaming download loop.
  let stream: AsyncThrowingStream<Data, Error>

  private let continuation: AsyncThrowingStream<Data, Error>.Continuation

  /// HTTP status of the response delivered by the matching data task. Set
  /// once the response arrives, before any chunks are yielded. `nil` until
  /// the first `didReceive response:` callback fires.
  ///
  /// Guarded by `lock`.
  private(set) var responseStatus: Int?
  private let lock = NSLock()

  init() {
    var c: AsyncThrowingStream<Data, Error>.Continuation!
    self.stream = AsyncThrowingStream<Data, Error> { continuation in
      c = continuation
    }
    self.continuation = c
  }

  func setResponseStatus(_ status: Int) {
    lock.lock()
    defer { lock.unlock() }
    responseStatus = status
  }

  func yield(_ data: Data) {
    continuation.yield(data)
  }

  func finish(throwing error: Error?) {
    continuation.finish(throwing: error)
  }
}

/// URLSession delegate that (a) rejects redirects to non-CDN hosts and
/// (b) forwards data-task chunks to per-task `ChunkConsumer` instances.
///
/// Only redirects within the configured CDN domain are followed; everything
/// else is rejected, causing the download to fail with the redirect-rejection
/// error path (the original 3xx response is delivered, which fails the
/// downstream HTTP 200/206 status check).
///
/// One delegate instance per `URLSession`. Per-task chunk delivery is
/// dispatched through a registry of `ObjectIdentifier(URLSessionTask) →
/// ChunkConsumer`. This shape was chosen so the host-pinning redirect
/// contract stays at the session level (not duplicated per task) while
/// chunked data delivery is still per-task.
final class SecureDownloadDelegate: NSObject,
  URLSessionTaskDelegate,
  URLSessionDataDelegate,
  @unchecked Sendable
{

  /// The allowed CDN host for all model downloads.
  static let allowedHost = "pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"

  // MARK: - Per-task consumer registry

  private let registryLock = NSLock()
  private var consumers: [ObjectIdentifier: ChunkConsumer] = [:]

  /// Registers `consumer` to receive chunks for `task`. The caller is
  /// responsible for ensuring the task has not yet been resumed when this
  /// is called (otherwise the first `didReceive` callback could race
  /// against registration).
  func register(_ consumer: ChunkConsumer, for task: URLSessionTask) {
    registryLock.lock()
    defer { registryLock.unlock() }
    consumers[ObjectIdentifier(task)] = consumer
  }

  /// Detaches the consumer for `task`. Safe to call even if no consumer was
  /// registered (returns `nil`).
  @discardableResult
  func unregister(_ task: URLSessionTask) -> ChunkConsumer? {
    registryLock.lock()
    defer { registryLock.unlock() }
    return consumers.removeValue(forKey: ObjectIdentifier(task))
  }

  private func consumer(for task: URLSessionTask) -> ChunkConsumer? {
    registryLock.lock()
    defer { registryLock.unlock() }
    return consumers[ObjectIdentifier(task)]
  }

  // MARK: - URLSessionTaskDelegate

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    if let host = request.url?.host, host == Self.allowedHost {
      completionHandler(request)
    } else {
      // Reject redirect to non-CDN domain. URLSession will deliver the
      // original 3xx response; the downstream HTTP-status check fails it.
      completionHandler(nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    // Stream-end sentinel. Notify the consumer (success or transport
    // failure), then drop the registry entry.
    let consumer = unregister(task)
    consumer?.finish(throwing: error)
  }

  // MARK: - URLSessionDataDelegate

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    if let consumer = consumer(for: dataTask),
      let http = response as? HTTPURLResponse
    {
      consumer.setResponseStatus(http.statusCode)
      // 2xx and 206 are allowed (200 full body, 206 partial content). All
      // other statuses (3xx not converted into a redirect by the redirect
      // delegate, 4xx, 5xx) are cancelled at the data layer so the
      // downloader sees a deterministic error path.
      let allow = (http.statusCode >= 200 && http.statusCode < 300) || http.statusCode == 206
      completionHandler(allow ? .allow : .cancel)
    } else {
      // Unknown response type or no registered consumer — let the bytes
      // through; the caller's downstream HTTP-status check will catch any
      // misroute. This matches the legacy behavior where the response was
      // inspected post-hoc.
      completionHandler(.allow)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    consumer(for: dataTask)?.yield(data)
  }
}

/// Provides a singleton URLSession locked to the CDN domain and tuned for
/// R2 bulk transfer.
///
/// All model file downloads and manifest fetches go through this session.
/// The delegate intercepts redirects; only those staying within the CDN
/// host are permitted. Data-task chunks are dispatched to per-task
/// `ChunkConsumer` instances via the delegate's registry — so the streaming
/// downloader never sees a byte-at-a-time AsyncBytes loop.
enum SecureDownloadSession {

  /// Single delegate instance, shared by every task on `shared`. This is
  /// the load-bearing piece of the redirect-rejection contract: one
  /// host-pinned delegate per session, not one per task.
  static let delegate = SecureDownloadDelegate()

  /// When true (set by `ACERVO_PARALLEL_RANGES=1` in the environment),
  /// the downloader forces the single-request path even for files that
  /// would normally take the parallel-range path. Diagnostics override
  /// for narrowing down regressions.
  static let parallelRangesDisabled: Bool = {
    ProcessInfo.processInfo.environment["ACERVO_PARALLEL_RANGES"] == "1"
  }()

  /// The configured URLSession. Thread-safe, reusable.
  ///
  /// Note: `assumesHTTP3Capable` is a per-`URLRequest` property in Foundation,
  /// not a session-level one. Every download request constructed by
  /// `AcervoDownloader.buildRequest(from:)` opts into HTTP/3 individually
  /// (see comment there) — the cold-start saving on QUIC still lands; the
  /// "set it on the session config" formulation in the design plan was a
  /// transcription error.
  static let shared: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 8                   // supports parallel-range fanout
    config.requestCachePolicy = .reloadIgnoringLocalCacheData  // client-side only — edge cache still warms
    // `waitsForConnectivity = true` is the production-intent setting (ride
    // out transient Wi-Fi blips instead of failing the download). Setting
    // this on the test runner's shared session, combined with the
    // production CDN URL appearing in some tests that intentionally use
    // unreachable hosts, would make those tests wait 60s+ per task.
    // Consumers that need the "ride out" behavior should set it on a
    // bespoke session config; the shared session opts out of the wait so
    // the in-CI failure path remains fast.
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = 60                      // single-chunk RTT ceiling
    config.timeoutIntervalForResource = 7 * 24 * 3600          // whole-file ceiling for multi-GB downloads
    return URLSession(
      configuration: config,
      delegate: delegate,
      delegateQueue: nil
    )
  }()
}

// MARK: - Chunked Download Helper

extension URLSession {

  /// Starts a `URLSessionDataTask` for `request` and returns an async stream
  /// of `Data` chunks plus a handle for the underlying task (so the caller
  /// can cancel it on its own initiative).
  ///
  /// Requires the session to have a `SecureDownloadDelegate` as its session
  /// delegate (so chunk delivery reaches the per-task registry). Both
  /// `SecureDownloadSession.shared` and the test harness's
  /// `MockURLProtocol.session()` satisfy this contract.
  ///
  /// - Parameter request: The configured URL request.
  /// - Returns: A tuple of (stream of chunks, task, consumer). The stream
  ///   finishes when the task completes (success or error). The task starts
  ///   running before this method returns. The consumer carries the HTTP
  ///   status code once the response arrives (callers inspect it after the
  ///   first chunk yields, or after the stream finishes for empty-body
  ///   responses).
  ///
  /// - Important: The caller MUST consume the stream to completion (or
  ///   cancel the task) — otherwise the per-task registry entry leaks
  ///   until session deinitialization.
  func chunkedDownload(
    for request: URLRequest
  ) throws -> (stream: AsyncThrowingStream<Data, Error>, task: URLSessionDataTask, consumer: ChunkConsumer)
  {
    guard let secureDelegate = self.delegate as? SecureDownloadDelegate else {
      throw AcervoError.networkError(
        NSError(
          domain: "SwiftAcervo",
          code: -1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "chunkedDownload requires a session whose delegate is a SecureDownloadDelegate"
          ]
        )
      )
    }
    let consumer = ChunkConsumer()
    let task = self.dataTask(with: request)
    secureDelegate.register(consumer, for: task)
    task.resume()
    return (consumer.stream, task, consumer)
  }
}
