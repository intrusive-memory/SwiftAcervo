import Foundation
import Testing
@testable import SwiftAcervo

/// Tests for SecureDownloadSession: redirect rejection and CDN host validation.
@Suite("Secure Download Session Tests")
struct SecureDownloadSessionTests {

    @Test("allowedHost matches the CDN domain")
    func allowedHost() {
        #expect(SecureDownloadDelegate.allowedHost == "pub-8e049ed02be340cbb18f921765fd24f3.r2.dev")
    }

    @Test("SecureDownloadSession shared instance is not nil")
    func sharedInstance() {
        let session = SecureDownloadSession.shared
        // The session should be a valid URLSession
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("Redirect delegate rejects non-CDN host")
    func rejectNonCDNRedirect() async {
        let delegate = SecureDownloadDelegate()
        let redirectURL = URL(string: "https://evil-cdn.example.com/models/org_repo/config.json")!
        let redirectRequest = URLRequest(url: redirectURL)

        let response = HTTPURLResponse(
            url: URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/org_repo/config.json")!,
            statusCode: 301,
            httpVersion: nil,
            headerFields: nil
        )!

        let expectation = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            delegate.urlSession(
                URLSession.shared,
                task: URLSession.shared.dataTask(with: URLRequest(url: URL(string: "https://example.com")!)),
                willPerformHTTPRedirection: response,
                newRequest: redirectRequest,
                completionHandler: { request in
                    continuation.resume(returning: request)
                }
            )
        }

        // Should reject (return nil) for non-CDN domain
        #expect(expectation == nil)
    }

    @Test("Redirect delegate allows CDN host")
    func allowCDNRedirect() async {
        let delegate = SecureDownloadDelegate()
        let redirectURL = URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/org_repo/other-path")!
        let redirectRequest = URLRequest(url: redirectURL)

        let response = HTTPURLResponse(
            url: URL(string: "https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/org_repo/config.json")!,
            statusCode: 301,
            httpVersion: nil,
            headerFields: nil
        )!

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
            delegate.urlSession(
                URLSession.shared,
                task: URLSession.shared.dataTask(with: URLRequest(url: URL(string: "https://example.com")!)),
                willPerformHTTPRedirection: response,
                newRequest: redirectRequest,
                completionHandler: { request in
                    continuation.resume(returning: request)
                }
            )
        }

        // Should allow redirect within CDN domain
        #expect(result != nil)
        #expect(result?.url == redirectURL)
    }
}
