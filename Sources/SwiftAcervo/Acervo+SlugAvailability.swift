// Acervo+SlugAvailability.swift
// SwiftAcervo
//
// Slug-keyed availability API — distinct from the repo-keyed availability in
// Acervo+Availability.swift. Three helpers below are intentionally module-visible
// (internal static) — used by Acervo+EnsureAvailable.swift (slug-keyed variant).
// Do not narrow to private.

import Foundation

// MARK: - Availability (slug-keyed, multi-component aggregation)

extension Acervo {

  /// Returns the three-state availability for a slug, fetching the CDN
  /// manifest and aggregating across every component the slug declares.
  ///
  /// This is the slug-registry-mission entry point introduced in
  /// `slug-registry/S2`. Unlike the legacy ``availability(_:)``, which is
  /// strictly offline and reflects only what is cached on disk, this method
  /// fetches the manifest (via the manifest cache or the network if needed)
  /// to discover the component list, then fans out across every component to
  /// build the aggregate.
  ///
  /// ## Slug + URL resolution rule
  ///
  /// * If `url` is supplied, it is used verbatim as the manifest fetch URL.
  ///   The `slug` is treated purely as the on-disk directory key.
  /// * If `url` is `nil` and `slug` parses as `"org/repo"` (single forward
  ///   slash, non-empty halves), the canonical CDN manifest URL is derived
  ///   from the slug.
  /// * If `url` is `nil` and `slug` does NOT parse as `"org/repo"`, the
  ///   method throws ``AcervoError/urlRequiredForSlug(_:)``.
  /// * If manifest fetch returns a non-2xx status, the method throws
  ///   ``AcervoError/manifestFetchFailed(slug:status:)``.
  ///
  /// ## Aggregation
  ///
  /// Per-component states are collapsed via the same
  /// ``AvailabilityAggregator/aggregate(_:)`` helper that
  /// ``ensureAvailable(slug:url:files:progress:)`` (S3) consumes:
  ///
  /// * Every component `.available` → `.available`
  /// * Any component `.downloading` → `.downloading(weightedAverage)` where
  ///   the weight is the component's manifest-declared total bytes
  /// * Otherwise → `.notAvailable`
  ///
  /// ## Telemetry
  ///
  /// Exactly one ``AcervoTelemetryEvent/modelAvailabilityResolved(slug:manifestURL:componentCount:result:)``
  /// is emitted per call, regardless of call shape (derived URL, explicit
  /// URL, single-component, multi-component). Error paths emit
  /// ``AcervoTelemetryEvent/errorThrown(phase:errorDescription:modelID:fileName:)``
  /// instead and skip the availability-resolved event.
  ///
  /// - Parameters:
  ///   - slug: The slug-level identifier. May or may not look like
  ///     `"org/repo"`.
  ///   - url: An explicit manifest URL. `nil` triggers slug-based URL
  ///     derivation (which requires the slug to parse as `"org/repo"`).
  ///   - telemetry: Optional reporter. Exactly one event is captured per
  ///     successful call.
  /// - Returns: `.available`, `.downloading(progress:)`, or `.notAvailable`.
  /// - Throws: ``AcervoError/urlRequiredForSlug(_:)`` when the slug needs an
  ///   explicit URL and none was supplied;
  ///   ``AcervoError/manifestFetchFailed(slug:status:)`` when the manifest
  ///   fetch returns a non-2xx HTTP status;
  ///   ``AcervoError/networkError(_:)`` on transport failures;
  ///   ``AcervoError/manifestDecodingFailed(_:)`` on malformed JSON.
  public static func availability(
    slug: String,
    url: URL? = nil,
    telemetry: (any AcervoTelemetryReporter)? = nil
  ) async throws -> ModelAvailability {
    try await availability(
      slug: slug,
      url: url,
      in: sharedModelsDirectory,
      telemetry: telemetry
    )
  }

  /// Custom-base-directory and session-injecting overload of
  /// ``availability(slug:url:telemetry:)``.
  ///
  /// Internal test seam. `session` defaults to `nil` which delegates to
  /// ``SecureDownloadSession/shared``; tests inject a `MockURLProtocol`-backed
  /// session.
  static func availability(
    slug: String,
    url: URL? = nil,
    in baseDirectory: URL,
    telemetry: (any AcervoTelemetryReporter)? = nil,
    session: URLSession? = nil
  ) async throws -> ModelAvailability {
    // ---- Resolve the manifest URL per the (slug, url?) contract. ----
    let manifestURL: URL
    if let explicit = url {
      manifestURL = explicit
    } else if isOrgRepoSlug(slug) {
      manifestURL = ManifestCache.derivedURL(forSlug: slug)
    } else {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: "Slug '\(slug)' is not 'org/repo' and no URL was supplied.",
            modelID: slug,
            fileName: nil
          ))
      }
      throw AcervoError.urlRequiredForSlug(slug)
    }

    // ---- Fetch the manifest (cache-aware). ----
    let manifest: CDNManifest
    do {
      manifest = try await fetchSlugManifest(
        slug: slug,
        manifestURL: manifestURL,
        session: session
      )
    } catch let error as AcervoError {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: error.errorDescription ?? "\(error)",
            modelID: slug,
            fileName: nil
          ))
      }
      throw error
    } catch {
      if let telemetry {
        await telemetry.capture(
          .errorThrown(
            phase: .manifestDownload,
            errorDescription: error.localizedDescription,
            modelID: slug,
            fileName: nil
          ))
      }
      throw AcervoError.networkError(error)
    }

    // ---- Fan out across components and aggregate. ----
    // Single-component case: `components == [primaryRepo]` and the
    // per-component state is just the legacy repo-keyed availability for
    // that one repo. Multi-component case: each component is resolved
    // independently via the same legacy probe (offline; cached manifest +
    // InFlightDownloads). The aggregator collapses them.
    var inputs: [ComponentAvailabilityInput] = []
    inputs.reserveCapacity(manifest.components.count)
    for component in manifest.components {
      let state = await availability(component, in: baseDirectory)
      let bytes = await componentTotalBytes(component, in: baseDirectory)
      inputs.append(
        ComponentAvailabilityInput(availability: state, bytesTotal: bytes))
    }
    let aggregate = AvailabilityAggregator.aggregate(inputs)

    // Exactly one availability-resolved event per call. Branches all funnel
    // through this single emission point.
    if let telemetry {
      let resultLabel: String
      switch aggregate {
      case .available: resultLabel = "available"
      case .notAvailable: resultLabel = "notAvailable"
      case .downloading(let p): resultLabel = "downloading(\(p))"
      case .partial(let missing): resultLabel = "partial(missing: \(missing.count))"
      }
      await telemetry.capture(
        .modelAvailabilityResolved(
          slug: slug,
          manifestURL: manifestURL.absoluteString,
          componentCount: manifest.components.count,
          result: resultLabel
        ))
    }
    return aggregate
  }

  /// Returns `true` when `slug` parses as `"org/repo"` with a single
  /// non-empty forward-slash separator. Matches the resolution rule in
  /// ``availability(slug:url:telemetry:)``.
  internal static func isOrgRepoSlug(_ slug: String) -> Bool {
    let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return !parts[0].isEmpty && !parts[1].isEmpty
  }

  /// Best-effort total-bytes lookup for a component, used as the
  /// aggregator's per-component weight. Returns `nil` when the local
  /// cached manifest is absent for this component (in which case the
  /// aggregator falls back to equal-weight averaging across all
  /// components).
  internal static func componentTotalBytes(_ modelId: String, in baseDirectory: URL) async -> Int64? {
    guard let cached = AcervoDownloader.loadCachedManifest(for: modelId, in: baseDirectory)
    else {
      return nil
    }
    return cached.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
  }

  /// Cache-aware manifest fetch for the slug-keyed APIs. Hits
  /// ``ManifestCache/shared`` first; on miss, downloads from
  /// `manifestURL` and stores under both `(slug, nil)` and
  /// `(slug, manifestURL)` lookup shapes (which collapse to the same key
  /// when `manifestURL == derivedURL(forSlug: slug)`).
  ///
  /// Non-2xx responses throw ``AcervoError/manifestFetchFailed(slug:status:)``
  /// (NOT ``manifestDownloadFailed(statusCode:)``) so UI code can branch on
  /// slug-resolution failure specifically.
  internal static func fetchSlugManifest(
    slug: String,
    manifestURL: URL,
    session injectedSession: URLSession?
  ) async throws -> CDNManifest {
    // 1) Cache hit?
    if let cached = await ManifestCache.shared.manifest(slug: slug, url: manifestURL) {
      return cached
    }
    // 2) Network fetch.
    let session = injectedSession ?? SecureDownloadSession.shared
    let request = URLRequest(url: manifestURL)
    let data: Data
    let response: URLResponse
    (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw AcervoError.manifestFetchFailed(slug: slug, status: http.statusCode)
    }
    let manifest: CDNManifest
    do {
      manifest = try JSONDecoder().decode(CDNManifest.self, from: data)
    } catch {
      throw AcervoError.manifestDecodingFailed(error)
    }
    // 3) Store under the explicit URL (preserves the (slug, explicitURL)
    // key) — when `manifestURL == derivedURL(forSlug: slug)`, this is
    // also the canonical (slug, nil) entry per ManifestCache's contract.
    await ManifestCache.shared.store(manifest, slug: slug, url: manifestURL)
    return manifest
  }
}
