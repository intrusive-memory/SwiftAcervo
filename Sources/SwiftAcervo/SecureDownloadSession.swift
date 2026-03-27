// SecureDownloadSession.swift
// SwiftAcervo
//
// A URLSession configured to reject redirects to non-CDN domains.
//
// All model downloads MUST use this session instead of URLSession.shared.
// This prevents a compromised DNS or CDN from silently redirecting
// downloads to a malicious server.

import Foundation

/// URLSessionTaskDelegate that rejects redirects to non-CDN hosts.
///
/// Only redirects within the configured CDN domain are followed.
/// All others are rejected, causing the download to receive the
/// original 3xx response (which then fails our HTTP 200 check).
final class SecureDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

  /// The allowed CDN host for all model downloads.
  static let allowedHost = "pub-8e049ed02be340cbb18f921765fd24f3.r2.dev"

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
      // Reject redirect to non-CDN domain
      completionHandler(nil)
    }
  }
}

/// Provides a singleton URLSession locked to the CDN domain.
///
/// All model file downloads and manifest fetches go through this session.
/// The delegate intercepts redirects; only those staying within the CDN
/// host are permitted.
enum SecureDownloadSession {

  private static let delegate = SecureDownloadDelegate()

  /// The configured URLSession. Thread-safe, reusable.
  static let shared: URLSession = {
    let config = URLSessionConfiguration.default
    // No local caching for model files; we verify integrity ourselves
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpMaximumConnectionsPerHost = 6
    return URLSession(
      configuration: config,
      delegate: delegate,
      delegateQueue: nil
    )
  }()
}
