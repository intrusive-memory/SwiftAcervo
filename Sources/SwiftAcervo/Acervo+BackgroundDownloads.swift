// Acervo+BackgroundDownloads.swift
// SwiftAcervo
//
// Public entry points for iOS background model downloads (#81, Phase 3 + 4).
//
// Design note (refines REQUIREMENTS R10a): rather than change the semantics of
// the hot `ensureComponentReady` / `ensureAvailable` functions (which existing
// macOS/foreground callers depend on), background downloading is exposed as a
// dedicated, additive API. SwiftVinetas's new iOS enqueue path calls
// `enqueueBackgroundDownload(modelId:)` and observes `backgroundDownloadEvents`;
// nothing about the existing foreground path changes. This is iOS-only.

#if os(iOS)

  import Foundation

  extension Acervo {

    /// The process-wide background download service, wired to the shared ledger
    /// and the App Group models directory.
    private static let backgroundService = BackgroundDownloadService()

    /// Enqueues every file of `modelId` for background download.
    ///
    /// Fetches the CDN manifest, then hands each file to the background
    /// `URLSession`. Returns as soon as the tasks are enqueued — the transfers
    /// continue while the app is suspended. Observe ``backgroundDownloadEvents``
    /// (and re-derive state via ``backgroundDownloadAvailability(modelId:)`` on
    /// relaunch) for progress and completion; there is no `async` completion here
    /// because completion may arrive in a later process launch.
    ///
    /// - Throws: manifest-fetch errors from ``fetchManifest(for:)``.
    public static func enqueueBackgroundDownload(modelId: String) async throws {
      try await backgroundService.enqueue(modelId: modelId)
    }

    /// Enqueues every file of a **registered component** for background
    /// download, resolving the component's `repoId` + file list from the
    /// registry (hydrating on the CDN first if needed).
    ///
    /// Use this for component-addressed models (e.g. PixArt), whose short
    /// `componentId`s are not repo ids. Observe ``backgroundDownloadEvents`` and
    /// re-derive state via ``backgroundDownloadAvailability(modelId:)`` keyed by
    /// the resolved `repoId`.
    ///
    /// - Throws: `AcervoError.componentNotRegistered` / `.componentNotHydrated`,
    ///   or manifest/hydration errors.
    public static func enqueueBackgroundDownloadComponent(_ componentId: String) async throws {
      try await backgroundService.enqueueComponent(componentId)
    }

    /// The authoritative observation stream of background download events
    /// (progress / file verified / file failed / repo completed). Single-consumer.
    public static var backgroundDownloadEvents: AsyncStream<BackgroundDownloadEvent> {
      backgroundService.events
    }

    /// Re-derives a model's background download availability from the durable
    /// ledger — correct after a cold relaunch.
    public static func backgroundDownloadAvailability(
      modelId: String
    ) async -> RepoDownloadAvailability {
      await backgroundService.availability(repoId: modelId)
    }

    /// Forwards an iOS
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// event to the background session. No-op when `identifier` is not ours, so
    /// the app can call this unconditionally.
    public static func handleBackgroundURLSessionEvents(
      identifier: String,
      completionHandler: @escaping @Sendable () -> Void
    ) {
      backgroundService.handleEvents(identifier: identifier, completionHandler: completionHandler)
    }

    /// The background session identifier the app should match in its
    /// `handleEventsForBackgroundURLSession` delegate before forwarding.
    public static var backgroundDownloadSessionIdentifier: String {
      BackgroundDownloadSession.defaultIdentifier
    }
  }

  /// Owns the coordinator + background session for the process. Internal — the
  /// public surface is the `Acervo` static methods above.
  final class BackgroundDownloadService: @unchecked Sendable {

    private let coordinator: BackgroundDownloadCoordinator
    private let session: BackgroundDownloadSession

    init() {
      let ledger = DownloadLedger.shared()
      self.coordinator = BackgroundDownloadCoordinator(
        ledger: ledger, modelsBaseDirectory: Acervo.sharedModelsDirectory)
      self.session = BackgroundDownloadSession(coordinator: coordinator)
    }

    var events: AsyncStream<BackgroundDownloadEvent> { coordinator.events }

    func availability(repoId: String) async -> RepoDownloadAvailability {
      await coordinator.availability(repoId: repoId)
    }

    func handleEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
      guard identifier == BackgroundDownloadSession.defaultIdentifier else { return }
      session.handleEvents(completionHandler: completionHandler)
    }

    func enqueue(modelId: String) async throws {
      let manifest = try await Acervo.fetchManifest(for: modelId)
      await enqueueFiles(
        repoId: modelId,
        files: manifest.files.map { (path: $0.path, sha256: $0.sha256) })
    }

    /// Resolves (hydrating if needed) a registered component to its repo + file
    /// list, then enqueues each file. This is the component-aware entry point
    /// PixArt uses — its short `componentId`s only resolve to a `repoId` + files
    /// after registry hydration, which the repo-based `enqueue(modelId:)` skips.
    func enqueueComponent(_ componentId: String) async throws {
      guard let initial = ComponentRegistry.shared.component(componentId) else {
        throw AcervoError.componentNotRegistered(componentId)
      }
      if initial.needsHydration {
        try await Acervo.hydrateComponent(componentId)
      }
      guard let descriptor = ComponentRegistry.shared.component(componentId),
        descriptor.isHydrated
      else {
        throw AcervoError.componentNotHydrated(id: componentId)
      }
      await enqueueFiles(
        repoId: descriptor.repoId,
        files: descriptor.files.map { (path: $0.relativePath, sha256: $0.sha256) })
    }

    /// Enqueues a resolved set of `(path, sha256)` files under `repoId` as
    /// background download tasks.
    private func enqueueFiles(repoId: String, files: [(path: String, sha256: String?)]) async {
      for file in files {
        let url = AcervoDownloader.buildURL(modelId: repoId, fileName: file.path)
        await session.enqueue(
          repoId: repoId, file: file.path, remoteURL: url, expectedSHA256: file.sha256)
      }
    }
  }

#endif
