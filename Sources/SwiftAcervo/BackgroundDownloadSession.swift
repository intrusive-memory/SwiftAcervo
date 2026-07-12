// BackgroundDownloadSession.swift
// SwiftAcervo
//
// The iOS-only background transport for model downloads (#81, Phase 2b + 4).
//
// Owns a `URLSessionConfiguration.background` session whose `downloadTask`s the
// OS drives out-of-process, so transfers continue while the app is suspended and
// complete even if the app is relaunched. All delegate callbacks are forwarded
// to the platform-agnostic `BackgroundDownloadCoordinator`, which does the
// verify/install/ledger work.
//
// This whole file is `#if os(iOS)`: macOS/CLI keep the existing foreground
// `dataTask` path unchanged (REQUIREMENTS R9). It compiles on iOS only, so it is
// exercised by an iOS build + a device checklist rather than macOS unit tests.

#if os(iOS)

  import Foundation

  /// Owns the background `URLSession` and bridges its delegate callbacks to a
  /// `BackgroundDownloadCoordinator`.
  ///
  /// Thread-safety: URLSession delivers delegate callbacks on its own serial
  /// delegate queue; each callback hops onto the coordinator actor via `Task`.
  /// The only mutable state here is `backgroundCompletionHandler`, guarded by a
  /// lock, so the type is `@unchecked Sendable`.
  public final class BackgroundDownloadSession: NSObject, @unchecked Sendable {

    /// The stable background-session identifier. Stable across launches so the OS
    /// can reconnect a relaunched process to the same daemon-side session.
    public static let defaultIdentifier = "productions.intrusive-memory.acervo.download"

    private let coordinator: BackgroundDownloadCoordinator
    private let identifier: String

    private let lock = NSLock()
    private var backgroundCompletionHandler: (@Sendable () -> Void)?

    private lazy var session: URLSession = {
      let config = URLSessionConfiguration.background(withIdentifier: identifier)
      // Let the OS daemon write directly into the App Group container.
      config.sharedContainerIdentifier = Acervo.resolvedAppGroupIdentifier
      // User-initiated model downloads should not be deferred by the scheduler.
      config.isDiscretionary = false
      // Wake the app in the background to finish handling completed transfers.
      config.sessionSendsLaunchEvents = true
      config.requestCachePolicy = .reloadIgnoringLocalCacheData
      return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Creates a background session bound to `coordinator`.
    /// - Parameter identifier: Override only in tests; production uses
    ///   ``defaultIdentifier`` so relaunch reconnects to the same session.
    public init(
      coordinator: BackgroundDownloadCoordinator,
      identifier: String = BackgroundDownloadSession.defaultIdentifier
    ) {
      self.coordinator = coordinator
      self.identifier = identifier
      super.init()
    }

    // MARK: - Enqueue

    /// Enqueues a single file for background download: records it in the ledger,
    /// creates a background `downloadTask`, and marks it in-flight under the OS
    /// task identifier so a relaunched delegate can route its completion.
    public func enqueue(repoId: String, file: String, remoteURL: URL, expectedSHA256: String?) async
    {
      await coordinator.enqueue(
        repoId: repoId, file: file, remoteURL: remoteURL, expectedSHA256: expectedSHA256)
      let task = session.downloadTask(with: remoteURL)
      await coordinator.markInflight(
        repoId: repoId, file: file, taskIdentifier: task.taskIdentifier)
      task.resume()
    }

    // MARK: - Relaunch re-attach (Phase 4)

    /// Called from the app's
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Storing the handler (and touching `session` so it re-attaches to the daemon)
    /// lets `urlSessionDidFinishEvents` invoke it once queued events drain.
    public func handleEvents(completionHandler: @escaping @Sendable () -> Void) {
      lock.withLock { backgroundCompletionHandler = completionHandler }
      _ = session  // force lazy creation so the delegate re-attaches
    }

    private func drainBackgroundCompletionHandler() {
      let handler = lock.withLock { () -> (@Sendable () -> Void)? in
        let h = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        return h
      }
      handler?()
    }
  }

  // MARK: - URLSessionDownloadDelegate

  extension BackgroundDownloadSession: URLSessionDownloadDelegate {

    public func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {
      // The OS deletes `location` as soon as this method returns, so move it to a
      // stable temp URL synchronously before handing off to the actor.
      let staged = FileManager.default.temporaryDirectory
        .appendingPathComponent("acervo-bg-\(UUID().uuidString)", isDirectory: false)
      do {
        try FileManager.default.moveItem(at: location, to: staged)
      } catch {
        // If we could not stage it, treat as a failure for this task.
        let taskId = downloadTask.taskIdentifier
        Task {
          await coordinator.recordFailure(taskIdentifier: taskId, reason: "stage failed: \(error)")
        }
        return
      }
      let taskId = downloadTask.taskIdentifier
      Task { await coordinator.resolveCompletedTask(taskIdentifier: taskId, deliveredFile: staged) }
    }

    public func urlSession(
      _ session: URLSession,
      downloadTask: URLSessionDownloadTask,
      didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64,
      totalBytesExpectedToWrite: Int64
    ) {
      let taskId = downloadTask.taskIdentifier
      Task {
        await coordinator.recordProgress(
          taskIdentifier: taskId,
          totalWritten: totalBytesWritten,
          totalExpected: totalBytesExpectedToWrite)
      }
    }

    public func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      didCompleteWithError error: Error?
    ) {
      // Success is handled in didFinishDownloadingTo; only surface real errors.
      guard let error else { return }
      let taskId = task.taskIdentifier
      Task {
        await coordinator.recordFailure(taskIdentifier: taskId, reason: String(describing: error))
      }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
      drainBackgroundCompletionHandler()
    }

    // Redirect pinning: never follow a redirect off the configured CDN host, even
    // out-of-process. Mirrors `SecureDownloadDelegate`.
    public func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      if let host = request.url?.host, host == Acervo.cdnAllowedHost {
        completionHandler(request)
      } else {
        completionHandler(nil)
      }
    }
  }

#endif
